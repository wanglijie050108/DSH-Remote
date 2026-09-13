// 隧道核心（01 §4.2，契约 §3 逐条实现）——本插件工作量主体
// 帧格式：11B 大端 ver|type|flags|stream_id|len；len ≤ 16373；flags 恒 0（接收方忽略非 0）；
// 状态机红线（skill §6 / 契约 §3.3）：
//   FIN 半关闭继续读（HTTP 响应体随后返回，全关会静默截断响应体）；
//   终态/未知流迟到帧静默忽略（不回 RST——RST 走 ctl 无序，会形成 RST 风暴）；
//   收到 RST 一律不回；重复/无效 OPEN 静默忽略并计错；回 RST 白名单仅三类（超限新 OPEN / 帧头非法 / 本地写错误）；
//   WINDOW.credit = 自上次 WINDOW 以来实际写入 socket 的增量（固定值会泄漏信用，约 43 轮死锁）；
//   未发送队列 单流 ≤256KiB 全局 ≤512KiB（保活帧与 mux PONG 的排队延迟约束，契约 §3.4.7）；
//   信用 0 停读 socket；FIN 走 data（顺序语义）；PING/PONG 走 ctl 且 stream_id=0；
//   保活 5s PING / 15s 无帧判死（兜底触发器；主触发是 ICE/connectionState，由 rtc.js 上报）。
import net from 'node:net'
import { randomBytes } from 'node:crypto'

export const FRAME_HEADER_SIZE = 11
export const MAX_PAYLOAD = 16373
export const FRAME_VER = 1
export const TYPE = { OPEN: 0x01, DATA: 0x02, FIN: 0x03, RST: 0x04, WINDOW: 0x05, PING: 0x06, PONG: 0x07 }
export const AUTHORITY = '127.0.0.1:13080' // OPEN 一致性断言（契约 §1）

const CREDIT_INITIAL = 256 * 1024 // 每流每方向（§3.4.5）
const WINDOW_THRESHOLD = 64 * 1024 // 累计 ≥64KiB 必发 WINDOW
const PER_STREAM_QUEUE_MAX = 256 * 1024
const GLOBAL_QUEUE_MAX = 512 * 1024
const MAX_STREAMS = 128 // §3.4.2
const KEEPALIVE_MS = 5000
const DEAD_MS = 15000

export function encodeFrame(type, streamId, payload = Buffer.alloc(0)) {
  if (payload.length > MAX_PAYLOAD) throw new Error(`frame len ${payload.length} > ${MAX_PAYLOAD}`)
  const out = Buffer.allocUnsafe(FRAME_HEADER_SIZE + payload.length)
  out.writeUInt8(FRAME_VER, 0)
  out.writeUInt8(type, 1)
  out.writeUInt8(0, 2) // flags 恒 0
  out.writeUInt32BE(streamId >>> 0, 3)
  out.writeUInt32BE(payload.length, 7)
  payload.copy(out, FRAME_HEADER_SIZE)
  return out
}

/** 解码一帧。错误码：BAD_VER（断开）/ LEN_OVERFLOW（对流 RST）/ INCOMPLETE（缓冲）。 */
export function decodeFrame(buf) {
  if (buf.length < FRAME_HEADER_SIZE) return { error: 'INCOMPLETE', need: FRAME_HEADER_SIZE - buf.length }
  const ver = buf.readUInt8(0)
  if (ver !== FRAME_VER) return { error: 'BAD_VER', ver }
  const type = buf.readUInt8(1)
  const flags = buf.readUInt8(2) // 读取但不得据此拒帧
  const streamId = buf.readUInt32BE(3)
  const len = buf.readUInt32BE(7)
  if (len > MAX_PAYLOAD) return { error: 'LEN_OVERFLOW', streamId, len }
  if (buf.length - FRAME_HEADER_SIZE < len) return { error: 'INCOMPLETE', need: FRAME_HEADER_SIZE + len - buf.length }
  return { ver, type, flags, streamId, payload: buf.subarray(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + len) }
}

/**
 * 插件侧隧道（acceptor）：手机发 OPEN → net.connect(转发目标) → 双向泵。
 * 通道由 rtc.js 建立后 attach()；字节透明红线：绝不吞 DSH 的 2s WS Ping、不做任何 UTF-8 转换。
 */
export class Tunnel {
  constructor({ forwardTarget, log = () => {}, onDead, authority = AUTHORITY }) {
    this.forwardTarget = forwardTarget
    this.log = log
    this.onDead = onDead
    this.authority = authority
    this.streams = new Map() // stream_id → session
    this.errors = 0
    this.dataCh = null
    this.ctlCh = null
    this.lastFrameAt = Date.now()
    this.pingTimer = null
    this.deadTimer = null
  }

  /** werift 通道就绪后挂载（label 识别由 rtc.js 保证：'data' 有序 / 'ctl' 无序） */
  attach(dataCh, ctlCh) {
    this.dataCh = dataCh
    this.ctlCh = ctlCh
    // 入站帧接线（werift onmessage 只做解码与入队级处理，绝不阻塞——skill §6）
    dataCh.onmessage = (ev) => this.onFrame(ev?.data ?? ev)
    ctlCh.onmessage = (ev) => this.onFrame(ev?.data ?? ev)
    dataCh.bufferedAmountLowThreshold = 64 * 1024
    if (dataCh.bufferedAmountLow?.subscribe) dataCh.bufferedAmountLow.subscribe(() => this._resumeReads())
    else if ('onbufferedamountlow' in dataCh) dataCh.onbufferedamountlow = () => this._resumeReads()
    this.pingTimer = setInterval(() => {
      try { this.ctlCh?.send(encodeFrame(TYPE.PING, 0, randomBytes(8))) } catch { /* 通道已关 */ }
    }, KEEPALIVE_MS)
    this.pingTimer.unref?.()
    this.deadTimer = setInterval(() => {
      if (Date.now() - this.lastFrameAt > DEAD_MS) {
        this.log('tunnel dead: 15s 无帧（兜底触发器）')
        this.onDead?.()
      }
    }, 1000)
    this.deadTimer.unref?.()
  }

  detach() {
    clearInterval(this.pingTimer)
    clearInterval(this.deadTimer)
    this.pingTimer = this.deadTimer = null
    for (const st of this.streams.values()) { try { st.socket.destroy() } catch {} }
    this.streams.clear()
    this.dataCh = this.ctlCh = null
  }

  _sendData(buf) { try { this.dataCh?.send(buf) } catch {} }
  _sendCtl(buf) { try { this.ctlCh?.send(buf) } catch {} }
  _globalBuffered() {
    let n = 0
    for (const st of this.streams.values()) n += (st.dataCh?.bufferedAmount ?? 0)
    return n
  }

  /** 手机侧 OPEN 到达：校验 authority 一致性 → 连接转发目标 → 建 session */
  _onOpen(frame) {
    const { streamId, payload } = frame
    if (streamId === 0 || this.streams.has(streamId)) { this.errors++; return } // 无效/重复：静默忽略计错（§3.3 v1.0.5），先于白名单①
    let authority = null
    try { authority = JSON.parse(payload.toString('utf8')).authority } catch { /* payload 非 JSON → 断言失败 */ }
    if (authority !== this.authority) { this.errors++; this.log(`OPEN authority mismatch: ${authority}`); return } // 一致性断言（§1）
    if (this.streams.size >= MAX_STREAMS) { // 白名单①：超限新 OPEN → RST
      this._sendCtl(encodeFrame(TYPE.RST, streamId, Buffer.from('stream limit')))
      return
    }
    const [host, port] = this.forwardTarget.split(':')
    const socket = net.connect(Number(port), host)
    const st = {
      socket, credit: CREDIT_INITIAL, writtenSinceWindow: 0,
      finSent: false, finRecv: false, rst: false, readingPaused: false,
      dataCh: this.dataCh,
    }
    this.streams.set(streamId, st)
    socket.on('data', (chunk) => {
      if (st.rst || st.finSent) return
      if (st.credit <= 0) { st.readingPaused = true; socket.pause(); return } // 信用 0 停读（§3.4.5）
      if (this._globalBuffered() >= GLOBAL_QUEUE_MAX || (this.dataCh?.bufferedAmount ?? 0) >= PER_STREAM_QUEUE_MAX) {
        st.readingPaused = true; socket.pause(); return // 未发送队列上限（§3.4.7）
      }
      for (let off = 0; off < chunk.length; off += MAX_PAYLOAD) {
        const slice = chunk.subarray(off, Math.min(off + MAX_PAYLOAD, chunk.length))
        st.credit -= slice.length
        this._sendData(encodeFrame(TYPE.DATA, streamId, slice))
      }
    })
    socket.on('close', () => {
      this._sendWindow(streamId, st) // 关闭前补齐通告（§3.4.5）
      this.streams.delete(streamId)
      if (!st.finSent && !st.rst) { st.finSent = true; this._sendData(encodeFrame(TYPE.FIN, streamId)) } // FIN 走 data
    })
    socket.on('error', (err) => { // 白名单③：本地 socket 写入错误 → RST（走 ctl）
      st.rst = true
      this.streams.delete(streamId)
      this._sendCtl(encodeFrame(TYPE.RST, streamId, Buffer.from(String(err.code || 'ECONNERR'))))
      this.log(`stream ${streamId} socket error: ${err.code || err.message}`)
    })
  }

  _sendWindow(streamId, st) {
    if (st.writtenSinceWindow <= 0) return
    const delta = st.writtenSinceWindow // 增量语义（§3.4.5），不是固定 64KiB
    st.writtenSinceWindow = 0
    const b = Buffer.alloc(4)
    b.writeUInt32BE(Math.min(delta, 0xFFFFFFFF), 0)
    this._sendCtl(encodeFrame(TYPE.WINDOW, streamId, b))
  }

  _resumeReads() {
    for (const st of this.streams.values()) {
      if (st.readingPaused && st.credit > 0 && this._globalBuffered() < GLOBAL_QUEUE_MAX) {
        st.readingPaused = false
        st.socket.resume()
      }
    }
  }

  /** data/ctl 通道来的原始消息（werift onmessage 回调里只做解码与入队级处理，绝不阻塞——skill §6） */
  onFrame(buf) {
    this.lastFrameAt = Date.now()
    const frame = decodeFrame(buf)
    if (frame.error) {
      if (frame.error === 'BAD_VER') { this.log(`FATAL: frame ver=${frame.ver} ≠ 1 → 断开（§3.1）`); this.onDead?.(); return }
      if (frame.error === 'LEN_OVERFLOW') {
        if (frame.streamId !== undefined) this._sendCtl(encodeFrame(TYPE.RST, frame.streamId, Buffer.from('frame too large'))) // 白名单②
        this.errors++
        return
      }
      this.errors++ // INCOMPLETE：werift 按消息分帧，不应出现；丢弃计错
      return
    }
    const { type, streamId } = frame
    switch (type) {
      case TYPE.OPEN: this._onOpen(frame); return
      case TYPE.DATA: {
        const st = this.streams.get(streamId)
        if (!st || st.rst) return // 终态迟到帧：静默忽略，不回 RST（§3.3）
        st.socket.write(frame.payload, () => {
          // 写入完成回调：累计增量，≥64KiB 发 WINDOW（契约 §3.4.5）
          st.writtenSinceWindow += frame.payload.length
          if (st.writtenSinceWindow >= WINDOW_THRESHOLD) this._sendWindow(streamId, st)
        })
        return
      }
      case TYPE.FIN: {
        const st = this.streams.get(streamId)
        if (!st || st.rst) return
        if (st.finRecv) return // 幂等
        st.finRecv = true
        try { st.socket.end() } catch {} // 半关闭：仅本端写方向；继续读继续转发（红线）
        return
      }
      case TYPE.RST: {
        const st = this.streams.get(streamId)
        if (st) { st.rst = true; try { st.socket.destroy() } catch {}; this.streams.delete(streamId) }
        return // 一律不回 RST（防风暴）
      }
      case TYPE.WINDOW: {
        const st = this.streams.get(streamId)
        if (!st || st.rst) return
        if (frame.payload.length >= 4) {
          st.credit += frame.payload.readUInt32BE(0)
          if (st.readingPaused && st.credit > 0) { st.readingPaused = false; st.socket.resume() }
        }
        return
      }
      case TYPE.PING: this._sendCtl(encodeFrame(TYPE.PONG, 0, frame.payload)); return // PONG 回显，stream_id=0
      case TYPE.PONG: return
      default: this.errors++; return // 未知 type：静默忽略计错，不关隧道（§3.3）
    }
  }
}
