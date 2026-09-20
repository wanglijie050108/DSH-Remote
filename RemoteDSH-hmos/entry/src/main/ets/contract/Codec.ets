// 纯 TS 编解码工具：base64 / base64url / hex / utf8
// 不依赖 @ohos.util —— 本地单测（PC 环境）与真机均可运行；
// base64url 按契约习惯为无填充（RFC 4648 §5），解码端容忍标准填充与 URL-safe 两种字母表。
const B64_ALPHABET: string = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

export function bytesToBase64(bytes: Uint8Array): string {
  let out = ''
  const len = bytes.length
  let i = 0
  for (; i + 2 < len; i += 3) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]
    out += B64_ALPHABET[(n >> 18) & 63] + B64_ALPHABET[(n >> 12) & 63]
    out += B64_ALPHABET[(n >> 6) & 63] + B64_ALPHABET[n & 63]
  }
  if (i + 1 === len) {
    const n = bytes[i] << 16
    out += B64_ALPHABET[(n >> 18) & 63] + B64_ALPHABET[(n >> 12) & 63] + '=='
  } else if (i + 2 === len) {
    const n = (bytes[i] << 16) | (bytes[i + 1] << 8)
    out += B64_ALPHABET[(n >> 18) & 63] + B64_ALPHABET[(n >> 12) & 63]
    out += B64_ALPHABET[(n >> 6) & 63] + '='
  }
  return out
}

function b64Val(c: string): number {
  const code = c.charCodeAt(0)
  if (code >= 65 && code <= 90) { return code - 65 } // A-Z
  if (code >= 97 && code <= 122) { return code - 97 + 26 } // a-z
  if (code >= 48 && code <= 57) { return code - 48 + 52 } // 0-9
  if (c === '+' || c === '-') { return 62 }
  if (c === '/' || c === '_') { return 63 }
  return -1
}

export function base64ToBytes(s: string): Uint8Array {
  const clean: number[] = []
  for (let i = 0; i < s.length; i++) {
    const c = s.charAt(i)
    if (c === '=' || c === '\r' || c === '\n' || c === ' ' || c === '\t') { continue }
    const v = b64Val(c)
    if (v >= 0) { clean.push(v) }
  }
  const out = new Uint8Array(Math.floor(clean.length / 4) * 3 + (clean.length % 4 === 0 ? 0 : (clean.length % 4 - 1)))
  let o = 0
  let i = 0
  for (; i + 3 < clean.length; i += 4) {
    const n = (clean[i] << 18) | (clean[i + 1] << 12) | (clean[i + 2] << 6) | clean[i + 3]
    out[o] = (n >> 16) & 255
    out[o + 1] = (n >> 8) & 255
    out[o + 2] = n & 255
    o += 3
  }
  const rem = clean.length - i
  if (rem === 2) {
    const n = (clean[i] << 18) | (clean[i + 1] << 12)
    out[o] = (n >> 16) & 255
  } else if (rem === 3) {
    const n = (clean[i] << 18) | (clean[i + 1] << 12) | (clean[i + 2] << 6)
    out[o] = (n >> 16) & 255
    out[o + 1] = (n >> 8) & 255
  }
  return out
}

/** base64url 无填充（契约 pub/sig/nonce 等编码习惯） */
export function bytesToB64u(bytes: Uint8Array): string {
  return bytesToBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function b64uToBytes(s: string): Uint8Array {
  return base64ToBytes(s.replace(/-/g, '+').replace(/_/g, '/'))
}

const HEX_ALPHABET: string = '0123456789abcdef'

export function bytesToHex(bytes: Uint8Array): string {
  let out = ''
  for (let i = 0; i < bytes.length; i++) {
    out += HEX_ALPHABET[(bytes[i] >> 4) & 15] + HEX_ALPHABET[bytes[i] & 15]
  }
  return out
}

export function hexToBytes(s: string): Uint8Array {
  const out = new Uint8Array(Math.floor(s.length / 2))
  for (let i = 0; i + 1 < s.length; i += 2) {
    out[i / 2] = parseInt(s.substr(i, 2), 16)
  }
  return out
}

export function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) { return false }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) { return false }
  }
  return true
}

export function utf8Encode(s: string): Uint8Array {
  const out = new Uint8Array(utf8Len(s))
  let o = 0
  for (let i = 0; i < s.length; i++) {
    let c: number = s.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      const c2: number = s.charCodeAt(i + 1)
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        c = 0x10000 + ((c - 0xD800) << 10) + (c2 - 0xDC00)
        i++
      }
    }
    if (c < 0x80) {
      out[o] = c
      o++
    } else if (c < 0x800) {
      out[o] = 0xC0 | (c >> 6)
      out[o + 1] = 0x80 | (c & 0x3F)
      o += 2
    } else if (c < 0x10000) {
      out[o] = 0xE0 | (c >> 12)
      out[o + 1] = 0x80 | ((c >> 6) & 0x3F)
      out[o + 2] = 0x80 | (c & 0x3F)
      o += 3
    } else {
      out[o] = 0xF0 | (c >> 18)
      out[o + 1] = 0x80 | ((c >> 12) & 0x3F)
      out[o + 2] = 0x80 | ((c >> 6) & 0x3F)
      out[o + 3] = 0x80 | (c & 0x3F)
      o += 4
    }
  }
  return out
}

function utf8Len(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c >= 0xD800 && c <= 0xDBFF && i + 1 < s.length) {
      const c2 = s.charCodeAt(i + 1)
      if (c2 >= 0xDC00 && c2 <= 0xDFFF) {
        n += 4
        i++
        continue
      }
    }
    if (c < 0x80) { n += 1 } else if (c < 0x800) { n += 2 } else if (c < 0x10000) { n += 3 } else { n += 4 }
  }
  return n
}

export function utf8Decode(bytes: Uint8Array): string {
  let out = ''
  let i = 0
  while (i < bytes.length) {
    const b = bytes[i]
    if (b < 0x80) {
      out += String.fromCharCode(b)
      i++
    } else if (b < 0xE0 && i + 1 < bytes.length) {
      out += String.fromCharCode(((b & 0x1F) << 6) | (bytes[i + 1] & 0x3F))
      i += 2
    } else if (b < 0xF0 && i + 2 < bytes.length) {
      out += String.fromCharCode(((b & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F))
      i += 3
    } else if (i + 3 < bytes.length) {
      const cp = ((b & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) | ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F)
      const v = cp - 0x10000
      out += String.fromCharCode(0xD800 + (v >> 10), 0xDC00 + (v & 0x3FF))
      i += 4
    } else {
      i++
    }
  }
  return out
}
