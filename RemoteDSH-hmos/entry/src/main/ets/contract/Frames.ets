// 帧编解码 ArkTS port（契约 §3.1–§3.3，对齐 remotedsh-contract/js/frames.mjs 逐字节一致）
// 11B 大端帧头：ver u8 / type u8 / flags u8 / stream_id u32 / len u32；len ≤ 16373（总帧 ≤ 16384）
export const FRAME_HEADER_SIZE: number = 11
export const MAX_PAYLOAD: number = 16373
export const MAX_FRAME_SIZE: number = 16384
export const FRAME_VER: number = 1

export class FrameType {
  static readonly OPEN: number = 0x01
  static readonly DATA: number = 0x02
  static readonly FIN: number = 0x03
  static readonly RST: number = 0x04
  static readonly WINDOW: number = 0x05
  static readonly PING: number = 0x06
  static readonly PONG: number = 0x07
}

export class FrameError extends Error {
  public readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

export class DecodedFrame {
  public ver: number = 0
  public type: number = 0
  public flags: number = 0
  public streamId: number = 0
  public payload: Uint8Array = new Uint8Array(0)
}

function readU32be(b: Uint8Array, off: number): number {
  return (b[off] * 0x1000000) + (b[off + 1] << 16) + (b[off + 2] << 8) + b[off + 3]
}

function writeU32be(b: Uint8Array, off: number, v: number): void {
  b[off] = Math.floor(v / 0x1000000) & 255
  b[off + 1] = (v >> 16) & 255
  b[off + 2] = (v >> 8) & 255
  b[off + 3] = v & 255
}

/**
 * 编码一帧。flags 恒 0（契约 §3.1：发送方 MUST 置 0）。
 * len > 16373 → FrameError('LEN_OVERFLOW')；PING/PONG 调用方 MUST 传 streamId=0。
 */
export function encodeFrame(type: number, streamId: number, payload: Uint8Array): Uint8Array {
  if (payload.length > MAX_PAYLOAD) {
    throw new FrameError('LEN_OVERFLOW', `len=${payload.length} > ${MAX_PAYLOAD}`)
  }
  const out = new Uint8Array(FRAME_HEADER_SIZE + payload.length)
  out[0] = FRAME_VER
  out[1] = type
  out[2] = 0
  writeU32be(out, 3, streamId)
  writeU32be(out, 7, payload.length)
  out.set(payload, FRAME_HEADER_SIZE)
  return out
}

/** 帧头不完整 → FrameError('HEADER_INCOMPLETE')（调用方应继续缓冲）；非 1 ver → BAD_VER；len 超限 → LEN_OVERFLOW */
export function decodeFrame(bytes: Uint8Array): DecodedFrame {
  if (bytes.length < FRAME_HEADER_SIZE) {
    throw new FrameError('HEADER_INCOMPLETE', `only ${bytes.length}B`)
  }
  const ver = bytes[0]
  if (ver !== FRAME_VER) {
    throw new FrameError('BAD_VER', `ver=${ver}`) // §3.1 非 1 → 立即断开
  }
  const type = bytes[1]
  const flags = bytes[2] // 接收方 MUST 忽略非 0，不得据此拒帧
  const streamId = readU32be(bytes, 3)
  const len = readU32be(bytes, 7)
  if (len > MAX_PAYLOAD) {
    throw new FrameError('LEN_OVERFLOW', `len=${len}`) // §3.1 → 对流 RST
  }
  if (bytes.length < FRAME_HEADER_SIZE + len) {
    throw new FrameError('HEADER_INCOMPLETE', `have ${bytes.length}, need ${FRAME_HEADER_SIZE + len}`)
  }
  const f = new DecodedFrame()
  f.ver = ver
  f.type = type
  f.flags = flags
  f.streamId = streamId
  f.payload = bytes.slice(FRAME_HEADER_SIZE, FRAME_HEADER_SIZE + len)
  return f
}

/** 逐字节流式拆帧器：跨 DataChannel 消息天然按消息分帧，但也容忍字节流（TCP 化） */
export class FrameSplitter {
  private buf: Uint8Array = new Uint8Array(0)

  public push(bytes: Uint8Array): DecodedFrame[] {
    const merged = new Uint8Array(this.buf.length + bytes.length)
    merged.set(this.buf)
    merged.set(bytes, this.buf.length)
    this.buf = merged
    const out: DecodedFrame[] = []
    for (;;) {
      if (this.buf.length < FRAME_HEADER_SIZE) {
        break
      }
      const len = readU32be(this.buf, 7)
      if (len > MAX_PAYLOAD) {
        // 与参考实现不同：拆帧器层面超限帧抛给上层（由隧道层对流出 RST 并复位缓冲）
        throw new FrameError('LEN_OVERFLOW', `len=${len}`)
      }
      if (this.buf.length < FRAME_HEADER_SIZE + len) {
        break
      }
      out.push(decodeFrame(this.buf.slice(0, FRAME_HEADER_SIZE + len)))
      this.buf = this.buf.slice(FRAME_HEADER_SIZE + len)
    }
    return out
  }
}
