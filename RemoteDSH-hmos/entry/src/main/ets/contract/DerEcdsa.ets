// ECDSA 签名 DER(ASN.1 SEQUENCE{INTEGER r, INTEGER s}) ↔ 裸 r‖s 互转（纯逻辑，可本地向量验证）
// 契约 §4.2：签名 MUST 为 DER，禁 P1363。⚠ 官方文档：cryptoFramework sign/verify 仅支持 DER 格式
// （华为开发者文章「ECDSA签名 r||s 和 DER 格式互转」），真机实测 sign 输出 71~72B DER——本模块
// 的「cryptoFramework 输出裸 r‖s」旧注释是错误假设，曾致 runHelloVectors 报 BAD_RAW raw len=71。
// Hello.ets 已改为直接透传 native DER；本模块保留为跨平台联调/向量排查的纯逻辑参考实现。
// 编码符合 DER 规范：INTEGER 剥前导零（保留 ≥1 字节）、高位置 1 时前补 0x00；长度用短形/长形编码
// ArkTS 适配：禁索引访问出参 → 用私有结果类替代（out-param 数组模式编译不过）
export class DerError extends Error {
  public readonly code: string

  constructor(code: string, message: string) {
    super(message)
    this.code = code
  }
}

class LenInfo {
  public value: number = 0
  public lenLen: number = 0
}

class IntInfo {
  public next: number = 0
  public value: Uint8Array = new Uint8Array(0)
}

function trimLeadingZeros(b: Uint8Array): Uint8Array {
  let start = 0
  while (start < b.length - 1 && b[start] === 0) {
    start++
  }
  return b.slice(start)
}

function derEncodeInteger(v: Uint8Array): Uint8Array {
  const t = trimLeadingZeros(v)
  let content: Uint8Array
  if (t[0] & 0x80) {
    content = new Uint8Array(t.length + 1)
    content[0] = 0
    content.set(t, 1)
  } else {
    content = t
  }
  if (content.length > 127) {
    // 签名场景 r/s ≤ 33B 不会走到；防御性支持长形编码
    const n = content.length
    const lenBytes = new Uint8Array(4)
    let nb = 0
    let x = n
    while (x > 0) {
      lenBytes[3 - nb] = x & 255
      nb++
      x = Math.floor(x / 256)
    }
    const out = new Uint8Array(2 + nb + content.length)
    out[0] = 0x02
    out[1] = 0x80 | nb
    out.set(lenBytes.subarray(4 - nb), 2)
    out.set(content, 2 + nb)
    return out
  }
  const out = new Uint8Array(2 + content.length)
  out[0] = 0x02
  out[1] = content.length
  out.set(content, 2)
  return out
}

/** 裸 r‖s（P-256 为 64B）→ DER SEQUENCE（契约签名格式） */
export function rawToDer(raw: Uint8Array): Uint8Array {
  if (raw.length === 0 || raw.length % 2 !== 0) {
    throw new DerError('BAD_RAW', `raw len=${raw.length}`)
  }
  const half = raw.length / 2
  const rInt = derEncodeInteger(raw.slice(0, half))
  const sInt = derEncodeInteger(raw.slice(half))
  const body = new Uint8Array(rInt.length + sInt.length)
  body.set(rInt)
  body.set(sInt, rInt.length)
  const out = new Uint8Array(2 + body.length)
  out[0] = 0x30
  out[1] = body.length
  out.set(body, 2)
  return out
}

function derReadLen(b: Uint8Array, pos: number): LenInfo {
  const info = new LenInfo()
  const first = b[pos]
  if (first < 0x80) {
    info.lenLen = 1
    info.value = first
    return info
  }
  const n = first & 0x7f
  if (n === 0 || n > 4) {
    throw new DerError('BAD_LEN', `len octets=${n}`)
  }
  info.lenLen = 1 + n
  let v = 0
  for (let i = 0; i < n; i++) {
    v = v * 256 + b[pos + 1 + i]
  }
  info.value = v
  return info
}

function derExpectInteger(b: Uint8Array, pos: number): IntInfo {
  if (b[pos] !== 0x02) {
    throw new DerError('BAD_ASN1', `expect INTEGER at ${pos}, got 0x${b[pos].toString(16)}`)
  }
  const len = derReadLen(b, pos + 1)
  const start = pos + 1 + len.lenLen
  const info = new IntInfo()
  info.value = b.slice(start, start + len.value)
  info.next = start + len.value
  return info
}

/** DER SEQUENCE → 裸 r‖s（右对齐补零到 halfLen；P-256 halfLen=32） */
export function derToRaw(der: Uint8Array, halfLen: number): Uint8Array {
  if (der.length < 6 || der[0] !== 0x30) {
    throw new DerError('BAD_ASN1', 'not a SEQUENCE')
  }
  const seqLen = derReadLen(der, 1)
  // 布局：tag(1) + 长度(lenLen) + 内容(seqLen)
  if (1 + seqLen.lenLen + seqLen.value > der.length) {
    throw new DerError('BAD_ASN1', 'truncated SEQUENCE')
  }
  const r = derExpectInteger(der, 1 + seqLen.lenLen)
  const s = derExpectInteger(der, r.next)
  const rT = trimLeadingZeros(r.value)
  const sT = trimLeadingZeros(s.value)
  if (rT.length > halfLen || sT.length > halfLen) {
    throw new DerError('BAD_ASN1', 'integer longer than half')
  }
  const out = new Uint8Array(halfLen * 2)
  out.set(rT, halfLen - rT.length)
  out.set(sT, halfLen * 2 - sT.length)
  return out
}
