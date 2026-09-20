// 隧道泵 initiator 侧 ArkTS port（契约 §3.1–§3.5，对齐 remotedsh-contract/tools/lib/tunnel-pump.mjs）
// 手机=发起方：accept 本地 socket → 分配 stream_id → 发 OPEN(authority) → 双向泵
// 红线（§3.3 v1.0.4/v1.0.5）：终态/未知流迟到帧静默忽略；收到 RST 一律不回；
// WINDOW.credit=实际写入字节数增量；未知 type 静默忽略。
// ohos 适配偏差（已记 NOTICE）：TCPSocketConnection 无 pause/resume（半关闭同样没有）——
// 信用为 0 时改为「帧入内存队列、WINDOW 到达后 flush」，队列超限对本流 RST（等效背压上界）。
import { hilog } from '@kit.PerformanceAnalysisKit';
import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { encodeFrame, decodeFrame, FrameError, FrameType, DecodedFrame, MAX_PAYLOAD } from '../contract/Frames';
import { utf8Encode } from '../contract/Codec';

const TAG: string = '[Tunnel]'
const DOMAIN: number = 0xD001
export const AUTHORITY: string = '127.0.0.1:13080'
const CREDIT_INITIAL: number = 256 * 1024
const WINDOW_THRESHOLD: number = 64 * 1024
const PER_STREAM_QUEUE_MAX: number = 256 * 1024
const GLOBAL_QUEUE_MAX: number = 512 * 1024
const MAX_STREAMS: number = 128
const KEEPALIVE_MS: number = 5000
const DEAD_MS: number = 15000

export type FrameSender = (bytes: Uint8Array) => void

class TunnelStream {
  public conn: socket.TCPSocketConnection
  public queue: Uint8Array[] = []
  public queuedBytes: number = 0
  public credit: number = CREDIT_INITIAL
  public writtenSinceWindow: number = 0
  public finSent: boolean = false
  public finRecv: boolean = false
  public rst: boolean = false
  public pendingWrites: number = 0

  constructor(conn: socket.TCPSocketConnection) {
    this.conn = conn
  }
}

export class TunnelEndpoint {
  public streams: Map<number, TunnelStream> = new Map()
  public lastFrameAt: number = Date.now()
  public onDead: () => void = () => {}
  private nextStreamId: number = 1
  private sendDataFn: FrameSender
  private sendCtlFn: FrameSender
  private pingTimer: number = -1
  private deadTimer: number = -1
  private globalQueued: number = 0

  constructor(sendData: FrameSender, sendCtl: FrameSender) {
    this.sendDataFn = sendData
    this.sendCtlFn = sendCtl
    this.pingTimer = setInterval(() => {
      this.sendCtlFn(encodeFrame(FrameType.PING, 0, TunnelEndpoint.random8()))
    }, KEEPALIVE_MS)
    this.deadTimer = setInterval(() => {
      if (Date.now() - this.lastFrameAt > DEAD_MS) {
        hilog.warn(DOMAIN, TAG, 'tunnel dead: no frame for 15s')
        this.onDead()
      }
    }, 1000)
  }

  public static random8(): Uint8Array {
    const b = new Uint8Array(8)
    for (let i = 0; i < 8; i++) {
      b[i] = Math.floor(Math.random() * 256)
    }
    return b
  }

  public close(): void {
    if (this.pingTimer >= 0) { clearInterval(this.pingTimer); this.pingTimer = -1 }
    if (this.deadTimer >= 0) { clearInterval(this.deadTimer); this.deadTimer = -1 }
    this.teardownAll('endpoint closed')
  }

  public teardownAll(reason: string): void {
    this.streams.forEach((st: TunnelStream, id: number) => {
      st.conn.close().then(() => {}).catch((_e: BusinessError) => {})
      this.streams.delete(id)
    })
    this.globalQueued = 0
    hilog.info(DOMAIN, TAG, 'teardown: %{public}s', reason)
  }

  /** 发起方：为一条已 accept 的本地 socket 开流；超限返回 null（调用方应立即 close socket） */
  public openStream(conn: socket.TCPSocketConnection): number | null {
    if (this.streams.size >= MAX_STREAMS) {
      return null
    }
    const id = this.nextStreamId++
    const st = new TunnelStream(conn)
    this.streams.set(id, st)
    const openPayload = utf8Encode(`{"authority":"${AUTHORITY}"}`)
    this.sendDataFn(encodeFrame(FrameType.OPEN, id, openPayload))
    this.wireLocalSocket(id, st)
    hilog.info(DOMAIN, TAG, 'stream %{public}d open', id)
    return id
  }

  /** 本地 socket → 隧道（发方向：受 credit 与队列上限约束） */
  private wireLocalSocket(id: number, st: TunnelStream): void {
    st.conn.on('message', (value: socket.SocketMessageInfo) => {
      this.onLocalData(id, st, new Uint8Array(value.message))
    })
    st.conn.on('close', () => {
      // 本地 socket 关闭 → 补齐 WINDOW 通告 + FIN（走 data，§3.2/§3.4.8）
      this.finalize(id)
      if (!st.finSent && !st.rst) {
        st.finSent = true
        this.sendDataFn(encodeFrame(FrameType.FIN, id, new Uint8Array(0)))
      }
    })
    st.conn.on('error', (_err: BusinessError) => {
      st.rst = true
      this.sendCtlFn(encodeFrame(FrameType.RST, id, utf8Encode('socket error')))
      this.streams.delete(id)
    })
  }

  private onLocalData(id: number, st: TunnelStream, chunk: Uint8Array): void {
    if (st.rst || st.finSent) {
      return
    }
    let off = 0
    while (off < chunk.length) {
      const end = Math.min(off + MAX_PAYLOAD, chunk.length)
      const slice = chunk.slice(off, end)
      // 无 pause/resume（ohos 适配）：信用由 flushQueue 承担；队列超限 = 背压上界 → RST
      if (st.queuedBytes + slice.length > PER_STREAM_QUEUE_MAX || this.globalQueued + slice.length > GLOBAL_QUEUE_MAX) {
        st.rst = true
        this.sendCtlFn(encodeFrame(FrameType.RST, id, utf8Encode('queue overflow')))
        this.dropStream(id, st)
        return
      }
      st.queue.push(slice)
      st.queuedBytes += slice.length
      this.globalQueued += slice.length
      off = end
    }
    this.flushQueue(id, st)
  }

  private flushQueue(id: number, st: TunnelStream): void {
    while (st.queue.length > 0) {
      const slice = st.queue[0]
      if (slice.length > st.credit) {
        break // §3.4.5：信用不足即停发（队列内等待 WINDOW）
      }
      st.queue.shift()
      st.queuedBytes -= slice.length
      this.globalQueued -= slice.length
      st.credit -= slice.length
      this.sendDataFn(encodeFrame(FrameType.DATA, id, slice))
    }
  }

  private dropStream(id: number, st: TunnelStream): void {
    for (const s of st.queue) {
      this.globalQueued -= s.length
    }
    st.queue = []
    st.queuedBytes = 0
    this.streams.delete(id)
    st.conn.close().then(() => {}).catch((_e: BusinessError) => {})
  }

  /** 隧道 → 本地 socket（收方向；initiator 只会收到 DATA/FIN/RST/WINDOW/PING/PONG） */
  public onChannelFrame(label: string, raw: Uint8Array): void {
    this.lastFrameAt = Date.now()
    let frame: DecodedFrame
    try {
      frame = decodeFrame(raw)
    } catch (e) {
      this.handleFrameError(raw, e as FrameError)
      return
    }
    const id = frame.streamId
    switch (frame.type) {
      case FrameType.DATA: {
        const st = this.streams.get(id)
        if (!st || st.rst) { return } // 迟到帧静默忽略（§3.3 v1.0.4）
        this.writeToLocal(id, st, frame.payload)
        return
      }
      case FrameType.FIN: {
        const st = this.streams.get(id)
        if (!st || st.rst || st.finRecv) { return } // 幂等
        st.finRecv = true
        this.maybeCloseAfterFlush(st)
        return
      }
      case FrameType.RST: {
        const st = this.streams.get(id)
        if (st) {
          st.rst = true
          this.dropStream(id, st)
        }
        return // 收到 RST 一律不回（§3.3 防风暴）
      }
      case FrameType.WINDOW: {
        const st = this.streams.get(id)
        if (!st || st.rst) { return }
        if (frame.payload.length >= 4) {
          const delta = (frame.payload[0] * 0x1000000) + (frame.payload[1] << 16) + (frame.payload[2] << 8) + frame.payload[3]
          st.credit += delta
          this.flushQueue(id, st)
        }
        return
      }
      case FrameType.PING: {
        this.sendCtlFn(encodeFrame(FrameType.PONG, 0, frame.payload)) // 回显随机数，stream_id=0
        return
      }
      case FrameType.PONG: {
        return
      }
      default: {
        return // 未知 type：静默忽略（§3.3）
      }
    }
  }

  private handleFrameError(raw: Uint8Array, e: FrameError): void {
    if (e.code === 'BAD_VER') {
      hilog.error(DOMAIN, TAG, 'FATAL: frame ver != 1 → disconnect')
      this.onDead()
      return
    }
    if (e.code === 'LEN_OVERFLOW') {
      // stream_id 可解析 → 对该流 RST（§3.1 超限）
      if (raw.length >= 11 && raw[0] === 1) {
        const id = (raw[3] * 0x1000000) + (raw[4] << 16) + (raw[5] << 8) + raw[6]
        this.sendCtlFn(encodeFrame(FrameType.RST, id, utf8Encode('frame too large')))
      }
      return
    }
    // HEADER_INCOMPLETE：DataChannel 按消息分帧，正常不发生；丢弃即可
  }

  private writeToLocal(id: number, st: TunnelStream, payload: Uint8Array): void {
    st.pendingWrites++
    st.conn.send({ data: payload.slice().buffer }).then(() => {
      st.pendingWrites--
      // 收方向信用补告：实际写入字节数增量（§3.4.5）
      st.writtenSinceWindow += payload.length
      if (st.writtenSinceWindow >= WINDOW_THRESHOLD) {
        this.sendWindow(id, st)
      }
      this.maybeCloseAfterFlush(st)
    }).catch((_e: BusinessError) => {
      st.pendingWrites--
      st.rst = true
      this.sendCtlFn(encodeFrame(FrameType.RST, id, utf8Encode('write error')))
    })
  }

  private maybeCloseAfterFlush(st: TunnelStream): void {
    // 无半关闭 API 偏差：FIN → 排空写回调后整条 close
    if (st.finRecv && st.pendingWrites === 0) {
      st.conn.close().then(() => {}).catch((_e: BusinessError) => {})
    }
  }

  private sendWindow(id: number, st: TunnelStream): void {
    if (st.writtenSinceWindow <= 0) {
      return
    }
    const delta = st.writtenSinceWindow
    st.writtenSinceWindow = 0
    const b = new Uint8Array(4)
    b[0] = Math.floor(delta / 0x1000000) & 255
    b[1] = (delta >> 16) & 255
    b[2] = (delta >> 8) & 255
    b[3] = delta & 255
    this.sendCtlFn(encodeFrame(FrameType.WINDOW, id, b)) // 增量语义（§3.4.5）
  }

  /** 流关闭前的最终补齐通告（§3.4.5：流关闭前 MUST 补齐通告） */
  public finalize(id: number): void {
    const st = this.streams.get(id)
    if (!st) {
      return
    }
    this.sendWindow(id, st)
    this.streams.delete(id)
  }
}
