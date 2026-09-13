// 隧道泵 —— 契约 §3.1–§3.5 的可执行参考实现（fake-phone / fake-agent 共用；插件与 App 各自有独立等价实现）
// mode 'initiator'（手机）：accept 本地 socket → 分配 stream_id → 发 OPEN(authority) → 双向泵
// mode 'acceptor'（插件）：收到 OPEN → 经 connectFactory 建立到 DSH 的 net.Socket → 双向泵
// 关键红线（skill §6 / 契约 §3.3）：
//   FIN 半关闭（end/shutdownOutput）继续读；终态迟到帧静默忽略（不回 RST，防风暴）；
//   收到 RST 一律不回；重复/无效 OPEN 静默忽略并计错；WINDOW.credit = 自上次 WINDOW 以来实际写入 socket 的增量；
//   未发送队列 单流 ≤256KiB 全局 ≤512KiB（bufferedAmount）；信用 0 停读 socket；
//   PING/PONG 走 ctl（stream_id=0）；保活 5s / 15s 无帧判死。
import { encodeFrame, decodeFrame, FrameError, TYPE, MAX_PAYLOAD } from '../../js/frames.mjs'
import { randomBytes } from 'node:crypto'

const AUTHORITY = '127.0.0.1:13080' // 契约 §1 固定值
const CREDIT_INITIAL = 256 * 1024
const WINDOW_THRESHOLD = 64 * 1024
const PER_STREAM_QUEUE_MAX = 256 * 1024
const GLOBAL_QUEUE_MAX = 512 * 1024
const MAX_STREAMS = 128
const KEEPALIVE_MS = 5000
const DEAD_MS = 15000

export class TunnelEndpoint {
  constructor({ mode, dataCh, ctlCh, log = () => {}, connectFactory, onDead }) {
    this.mode = mode // 'initiator' | 'acceptor'
    this.log = log
    this.connectFactory = connectFactory // acceptor：async (streamId) => net.Socket
    this.onDead = onDead
    this.streams = new Map() // stream_id → {socket, credit, writtenSinceWindow, finSent, finRecv, rst, sendQueuePaused}
    this.nextStreamId = 1
    this.errors = 0
    this.lastFrameAt = Date.now()

    if (dataCh) {
      dataCh.onmessage = (ev) => this._onChannel(dataCh, ev?.data ?? ev)
      dataCh.onclose = () => this._teardownAll('data channel closed')
      dataCh.onerror = () => {}
    }
    if (ctlCh) {
      ctlCh.onmessage = (ev) => this._onChannel(ctlCh, ev?.data ?? ev)
      ctlCh.onclose = () => {}
      ctlCh.onerror = () => {}
    }
    // 保活（PING 走 ctl 引用：通道可能晚于构造绑定，故读 this.ctlChRef）
    this.pingTimer = setInterval(() => {
      try { this.ctlChRef?.send(encodeFrame(TYPE.PING, 0, crypto8())) } catch {}
    }, KEEPALIVE_MS)
    this.pingTimer.unref?.()
    this.deadTimer = setInterval(() => {
      if (Date.now() - this.lastFrameAt > DEAD_MS) {
        this.log('tunnel dead: no frame for 15s (兜底触发器, 契约 §3.5)')
        this.onDead?.()
      }
    }, 1000)
    this.deadTimer.unref?.()
  }

  close() {
    clearInterval(this.pingTimer); clearInterval(this.deadTimer)
    this._teardownAll('endpoint closed')
  }

  _teardownAll(reason) {
    for (const [id, st] of this.streams) { try { st.socket?.destroy() } catch {} }
    this.streams.clear()
    this.log(`tunnel teardown: ${reason}`)
  }

  // ---- 发起方：为一条已 accept 的 socket 开流 ----
  openStream(socket) {
    if (this.streams.size >= MAX_STREAMS) { socket.destroy(); return null } // §3.4 上限（发起方自觉）
    const id = this.nextStreamId++
    const st = this._newStream(socket)
    this.streams.set(id, st)
    const open = encodeFrame(TYPE.OPEN, id, Buffer.from(JSON.stringify({ authority: AUTHORITY }), 'utf8'))
    this._sendData(open, st)
    this._pumpSocketToChannel(id, st)
    return id
  }

  _newStream(socket) {
    return {
      socket, credit: CREDIT_INITIAL, writtenSinceWindow: 0,
      finSent: false, finRecv: false, rst: false, readingPaused: false,
    }
  }

  _pumpSocketToChannel(id, st) {
    st.socket.on('data', (chunk) => {
      if (st.rst || st.finSent) return
      // 信用控制：信用 0 → 停读（§3.4.5 发送方信用为 0 即暂停读）
      if (st.credit <= 0) { st.readingPaused = true; st.socket.pause(); return }
      // 未发送队列约束（§3.4.7）：单流 256KiB / 全局 512KiB
      if (this._globalBuffered() >= GLOBAL_QUEUE_MAX || (st.dataCh?.bufferedAmount ?? 0) >= PER_STREAM_QUEUE_MAX) {
        st.readingPaused = true; st.socket.pause()
        return
      }
      for (let off = 0; off < chunk.length; off += MAX_PAYLOAD) {
        const slice = chunk.subarray(off, Math.min(off + MAX_PAYLOAD, chunk.length))
        st.credit -= slice.length
        const frame = encodeFrame(TYPE.DATA, id, slice)
        this._sendData(frame, st)
      }
    })
    st.socket.on('close', () => { // 本地 socket 正常关闭 → FIN（走 data，§3.2/§3.4.8）+ 信用补齐
      this.finalize(id)
      if (!st.finSent && !st.rst) {
        st.finSent = true
        try { this._sendData(encodeFrame(TYPE.FIN, id)) } catch {}
      }
    })
    st.socket.on('error', (err) => { // 写入错误 → RST（走 ctl，§3.3 白名单③）
      st.rst = true
      try { this._sendCtl(encodeFrame(TYPE.RST, id, Buffer.from(String(err.code || err.message || 'write error'), 'utf8'))) } catch {}
      this.log(`stream ${id} socket error: ${err.code || err.message}`)
    })
  }

  _sendData(frame, st) { try { this.dataChRef?.send(Buffer.from(frame)) } catch {} }
  _sendCtl(frame) { try { this.ctlChRef?.send(Buffer.from(frame)) } catch {} }
  _globalBuffered() {
    let n = 0
    for (const st of this.streams.values()) n += (st.dataCh?.bufferedAmount ?? 0)
    return n
  }

  /** 由 CLI 在通道 open 后回填（werift 通道对象直接 send(Buffer)） */
  bindChannels(dataCh, ctlCh) {
    this.dataChRef = dataCh
    this.ctlChRef = ctlCh
    if (dataCh) dataCh.onmessage = (ev) => this._onChannel(dataCh, ev?.data ?? ev)
    if (ctlCh) ctlCh.onmessage = (ev) => this._onChannel(ctlCh, ev?.data ?? ev)
    // 恢复读：bufferedAmountLowThreshold 驱动（§3.4.7 建议做法）
    if (dataCh) {
      dataCh.bufferedAmountLowThreshold = 64 * 1024
      if (dataCh.bufferedAmountLow?.subscribe) {
        dataCh.bufferedAmountLow.subscribe(() => this._resumeReads())
      } else if (dataCh.onbufferedamountlow !== undefined) {
        dataCh.onbufferedamountlow = () => this._resumeReads()
      }
    }
  }

  _resumeReads() {
    for (const st of this.streams.values()) {
      if (st.readingPaused && this._globalBuffered() < GLOBAL_QUEUE_MAX && st.credit > 0) {
        st.readingPaused = false; st.socket.resume()
      }
    }
  }

  // ---- 通道 → socket（两个角色同一份状态机，契约 §3.3 逐行实现） ----
  _onChannel(ch, raw) {
    this.lastFrameAt = Date.now()
    const buf = Buffer.from(raw)
    let frame
    try { frame = decodeFrame(buf) } catch (e) {
      if (e instanceof FrameError) {
        if (e.code === 'BAD_VER') { this.log('FATAL: frame ver != 1 → disconnect (§3.1)'); this.onDead?.(); return }
        if (e.code === 'LEN_OVERFLOW') {
          // stream_id 可解析（≥11B 且 ver 合法）→ 对该流 RST；否则丢弃整帧计错
          if (buf.length >= 11 && buf[0] === 1) {
            const id = buf.readUInt32BE(3)
            this._sendCtl(encodeFrame(TYPE.RST, id, Buffer.from('frame too large')))
          }
          this.errors++
        } else { this.errors++ } // HEADER_INCOMPLETE / truncated：丢弃计错
      }
      return
    }
    const { type, stream_id: id, payload } = frame

    switch (type) {
      case TYPE.OPEN: {
        if (this.mode !== 'acceptor') { this.errors++; return } // 手机不会收到 OPEN（手机是发起方）
        if (id === 0 || this.streams.has(id)) { this.errors++; return } // 无效/重复 OPEN：静默忽略计错，不回 RST（§3.3 v1.0.5）
        let authority = null
        try { authority = JSON.parse(payload.toString('utf8')).authority } catch {}
        if (authority !== AUTHORITY) { this.errors++; this.log(`OPEN authority mismatch: ${authority}`); return } // 一致性断言（§1）
        if (this.streams.size >= MAX_STREAMS) { // 白名单①：超限新 OPEN → RST
          this._sendCtl(encodeFrame(TYPE.RST, id, Buffer.from('stream limit')))
          return
        }
        const socket = this.connectFactory?.()
        if (!socket) return
        const st = this._newStream(socket)
        this.streams.set(id, st)
        this._pumpSocketToChannel(id, st)
        return
      }
      case TYPE.DATA: {
        const st = this.streams.get(id)
        if (!st || st.rst) return // 终态/未知流迟到帧：静默忽略，不回 RST（§3.3 v1.0.4）
        // 绝不在回调里阻塞：写 socket 由 Node 缓冲（异步），超大也由信用与队列上限约束
        st.socket.write(payload, (err) => {
          if (err) { /* 写回调错误由 error 事件处理 */ return }
          st.writtenSinceWindow += payload.length
          if (st.writtenSinceWindow >= WINDOW_THRESHOLD) this._sendWindow(id, st)
        })
        return
      }
      case TYPE.FIN: {
        const st = this.streams.get(id)
        if (!st || st.rst) return
        if (st.finRecv) return // 幂等（§3.3）
        st.finRecv = true
        try { st.socket.end() } catch {} // 半关闭：只关本端写方向，继续读继续转发（红线）
        return
      }
      case TYPE.RST: {
        const st = this.streams.get(id)
        if (st) { st.rst = true; try { st.socket.destroy() } catch {}; this.streams.delete(id) }
        return // 收到 RST 一律不回 RST（§3.3 防风暴）
      }
      case TYPE.WINDOW: {
        const st = this.streams.get(id)
        if (!st || st.rst) return
        if (payload.length >= 4) {
          st.credit += payload.readUInt32BE(0)
          if (st.readingPaused && st.credit > 0) { st.readingPaused = false; st.socket.resume() }
        }
        return
      }
      case TYPE.PING: this._sendCtl(encodeFrame(TYPE.PONG, 0, payload)); return // 回显随机数，stream_id=0
      case TYPE.PONG: return
      default: this.errors++; return // 未知 type：静默忽略计错，不关隧道（§3.3）
      }
  }

  _sendWindow(id, st) {
    if (st.writtenSinceWindow <= 0) return
    const delta = st.writtenSinceWindow
    st.writtenSinceWindow = 0
    const b = Buffer.alloc(4)
    b.writeUInt32BE(Math.min(delta, 0xFFFFFFFF), 0)
    this._sendCtl(encodeFrame(TYPE.WINDOW, id, b)) // 增量语义（§3.4.5），非固定 64KiB
  }

  /** 流关闭前的最终补齐通告（§3.4.5：流关闭前 MUST 把已写入字节数补齐通告） */
  finalize(id) {
    const st = this.streams.get(id)
    if (!st) return
    this._sendWindow(id, st)
    this.streams.delete(id)
  }
}

const crypto8 = () => randomBytes(8)
