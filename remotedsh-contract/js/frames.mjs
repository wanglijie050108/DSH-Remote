// 帧编解码参考实现（契约 §3.1–§3.3）
// 11B 大端帧头：ver u8 / type u8 / flags u8 / stream_id u32 / len u32；len ≤ 16373（总帧 ≤ 16384）
export const FRAME_HEADER_SIZE = 11
export const MAX_PAYLOAD = 16373
export const MAX_FRAME_SIZE = 16384
export const FRAME_VER = 1

export const TYPE = /** @type {const} */ ({
  OPEN: 0x01, DATA: 0x02, FIN: 0x03, RST: 0x04, WINDOW: 0x05, PING: 0x06, PONG: 0x07,
})
export const TYPE_NAME = Object.fromEntries(Object.entries(TYPE).map(([k, v]) => [v, k]))

export class FrameError extends Error {
  constructor(code, message) {
    super(message)
    this.code = code // 'BAD_VER' | 'LEN_OVERFLOW' | 'HEADER_INCOMPLETE' | 'UNKNOWN_TYPE_SILENT'
  }
}

/**
 * 编码一帧。flags 由本库恒置 0（契约 §3.1：发送方 MUST 置 0）。
 * len > 16373 → 抛 FrameError('LEN_OVERFLOW')（发送侧防线；接收侧超限对流出 RST）。
 * PING/PONG 调用方 MUST 传 stream_id=0。
 */
export function encodeFrame(type, streamId, payload = new Uint8Array(0)) {
  const buf = payload instanceof Uint8Array ? payload : new TextEncoder().encode(String(payload))
  if (buf.length > MAX_PAYLOAD) throw new FrameError('LEN_OVERFLOW', `len=${buf.length} > ${MAX_PAYLOAD}`)
  const out = new Uint8Array(FRAME_HEADER_SIZE + buf.length)
  const dv = new DataView(out.buffer)
  dv.setUint8(0, FRAME_VER)
  dv.setUint8(1, type)
  dv.setUint8(2, 0) // flags 恒 0
  dv.setUint32(3, streamId)
  dv.setUint32(7, buf.length)
  out.set(buf, FRAME_HEADER_SIZE)
  return out
}

/** 帧头不完整 → HEADER_INCOMPLETE（调用方应继续缓冲，等更多字节） */
export function decodeFrame(bytes) {
  if (bytes.length < FRAME_HEADER_SIZE) throw new FrameError('HEADER_INCOMPLETE', `only ${bytes.length}B`)
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const ver = dv.getUint8(0)
  if (ver !== FRAME_VER) throw new FrameError('BAD_VER', `ver=${ver}`) // §3.1 非 1 → 立即断开
  const type = dv.getUint8(1)
  const flags = dv.getUint8(2) // 接收方 MUST 忽略非 0，不得据此拒帧
  const streamId = dv.getUint32(3)
  const len = dv.getUint32(7)
  if (len > MAX_PAYLOAD) throw new FrameError('LEN_OVERFLOW', `len=${len}`) // §3.1 → 对流 RST
  if (bytes.length < FRAME_HEADER_SIZE + len) throw new FrameError('HEADER_INCOMPLETE', `have ${bytes.length}, need ${11 + len}`)
  const payload = bytes.slice(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + len)
  return { ver, type, flags, stream_id: streamId, payload }
}

/** 逐字节流式拆帧器：跨 DataChannel 消息天然按消息分帧，但本拆帧器也容忍字节流（TCP 化测试用） */
export class FrameSplitter {
  constructor() { this.buf = new Uint8Array(0) }
  push(bytes) {
    const merged = new Uint8Array(this.buf.length + bytes.length)
    merged.set(this.buf); merged.set(bytes, this.buf.length)
    this.buf = merged
    const out = []
    for (;;) {
      if (this.buf.length < FRAME_HEADER_SIZE) break
      const dv = new DataView(this.buf.buffer, this.buf.byteOffset, this.buf.byteLength)
      const len = dv.getUint32(7)
      if (this.buf.length < FRAME_HEADER_SIZE + len) break
      try { out.push(decodeFrame(this.buf.subarray(0, FRAME_HEADER_SIZE + len))) } finally {
        this.buf = this.buf.subarray(FRAME_HEADER_SIZE + len)
      }
    }
    return out
  }
}
