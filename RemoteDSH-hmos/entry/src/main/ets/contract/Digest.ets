// 纯 TS SHA-256 / SHA-1 / HMAC-SHA1（契约 hello 的 id 摘要与 TURN 凭证 HMAC）
// 纯实现动机：本地单测即可对 RFC 向量逐字节验证，不依赖设备 cryptoFramework；
// 数据量级（SPKI 91B / username ~30B）下性能无影响。ECDSA 仍走 native cryptoFramework。
const K256: Uint32Array = new Uint32Array([
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
])

function rotr32(x: number, n: number): number {
  return ((x >>> n) | (x << (32 - n))) >>> 0
}

/** SHA-256（FIPS 180-4） */
export function sha256(data: Uint8Array): Uint8Array {
  const h = new Uint32Array([
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
  ])
  const l = data.length
  const total = (Math.floor((l + 8) / 64) + 1) * 64
  const m = new Uint8Array(total)
  m.set(data)
  m[l] = 0x80
  // 64-bit BE 位长：高 32 位 = floor(l / 2^29)（l*8 溢出分解）
  m[total - 8] = Math.floor(l / 0x20000000) & 255
  const lo = (l << 3) >>> 0
  m[total - 4] = (lo >>> 24) & 255
  m[total - 3] = (lo >>> 16) & 255
  m[total - 2] = (lo >>> 8) & 255
  m[total - 1] = lo & 255
  const w = new Uint32Array(64)
  for (let off = 0; off < total; off += 64) {
    for (let t = 0; t < 16; t++) {
      const i = off + t * 4
      w[t] = ((m[i] << 24) | (m[i + 1] << 16) | (m[i + 2] << 8) | m[i + 3]) >>> 0
    }
    for (let t = 16; t < 64; t++) {
      const s0 = rotr32(w[t - 15], 7) ^ rotr32(w[t - 15], 18) ^ (w[t - 15] >>> 3)
      const s1 = rotr32(w[t - 2], 17) ^ rotr32(w[t - 2], 19) ^ (w[t - 2] >>> 10)
      w[t] = (w[t - 16] + s0 + w[t - 7] + s1) >>> 0
    }
    let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7]
    for (let t = 0; t < 64; t++) {
      const S1 = rotr32(e, 6) ^ rotr32(e, 11) ^ rotr32(e, 25)
      const ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g)
      const t1 = (hh + S1 + ch + K256[t] + w[t]) >>> 0
      const S0 = rotr32(a, 2) ^ rotr32(a, 13) ^ rotr32(a, 22)
      const maj = (a & b) ^ (a & c) ^ (b & c)
      const t2 = (S0 + maj) >>> 0
      hh = g
      g = f
      f = e
      e = (d + t1) >>> 0
      d = c
      c = b
      b = a
      a = (t1 + t2) >>> 0
    }
    h[0] = (h[0] + a) >>> 0
    h[1] = (h[1] + b) >>> 0
    h[2] = (h[2] + c) >>> 0
    h[3] = (h[3] + d) >>> 0
    h[4] = (h[4] + e) >>> 0
    h[5] = (h[5] + f) >>> 0
    h[6] = (h[6] + g) >>> 0
    h[7] = (h[7] + hh) >>> 0
  }
  const out = new Uint8Array(32)
  for (let i = 0; i < 8; i++) {
    out[i * 4] = (h[i] >>> 24) & 255
    out[i * 4 + 1] = (h[i] >>> 16) & 255
    out[i * 4 + 2] = (h[i] >>> 8) & 255
    out[i * 4 + 3] = h[i] & 255
  }
  return out
}

function rotl32(x: number, n: number): number {
  return ((x << n) | (x >>> (32 - n))) >>> 0
}

/** SHA-1（FIPS 180-4） */
export function sha1(data: Uint8Array): Uint8Array {
  let h0 = 0x67452301, h1 = 0xefcdab89, h2 = 0x98badcfe, h3 = 0x10325476, h4 = 0xc3d2e1f0
  const l = data.length
  const total = (Math.floor((l + 8) / 64) + 1) * 64
  const m = new Uint8Array(total)
  m.set(data)
  m[l] = 0x80
  m[total - 8] = Math.floor(l / 0x20000000) & 255
  const lo = (l << 3) >>> 0
  m[total - 4] = (lo >>> 24) & 255
  m[total - 3] = (lo >>> 16) & 255
  m[total - 2] = (lo >>> 8) & 255
  m[total - 1] = lo & 255
  const w = new Uint32Array(80)
  for (let off = 0; off < total; off += 64) {
    for (let t = 0; t < 16; t++) {
      const i = off + t * 4
      w[t] = ((m[i] << 24) | (m[i + 1] << 16) | (m[i + 2] << 8) | m[i + 3]) >>> 0
    }
    for (let t = 16; t < 80; t++) {
      w[t] = rotl32(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1)
    }
    let a = h0, b = h1, c = h2, d = h3, e = h4
    for (let t = 0; t < 80; t++) {
      let f: number
      let k: number
      if (t < 20) {
        f = (b & c) | ((~b & 0xFFFFFFFF) & d)
        k = 0x5a827999
      } else if (t < 40) {
        f = b ^ c ^ d
        k = 0x6ed9eba1
      } else if (t < 60) {
        f = (b & c) | (b & d) | (c & d)
        k = 0x8f1bbcdc
      } else {
        f = b ^ c ^ d
        k = 0xca62c1d6
      }
      const temp = (rotl32(a, 5) + f + e + k + w[t]) >>> 0
      e = d
      d = c
      c = rotl32(b, 30)
      b = a
      a = temp
    }
    h0 = (h0 + a) >>> 0
    h1 = (h1 + b) >>> 0
    h2 = (h2 + c) >>> 0
    h3 = (h3 + d) >>> 0
    h4 = (h4 + e) >>> 0
  }
  const out = new Uint8Array(20)
  const hs = [h0, h1, h2, h3, h4]
  for (let i = 0; i < 5; i++) {
    out[i * 4] = (hs[i] >>> 24) & 255
    out[i * 4 + 1] = (hs[i] >>> 16) & 255
    out[i * 4 + 2] = (hs[i] >>> 8) & 255
    out[i * 4 + 3] = hs[i] & 255
  }
  return out
}

export type HashFn = (data: Uint8Array) => Uint8Array

/** HMAC（RFC 2104，块长 64）：HMAC-SHA1 用 sha1，HMAC-SHA256 用 sha256 */
export function hmac(hashFn: HashFn, key: Uint8Array, msg: Uint8Array): Uint8Array {
  const BLOCK = 64
  let k = key
  if (k.length > BLOCK) {
    k = hashFn(k)
  }
  const ipad = new Uint8Array(BLOCK)
  const opad = new Uint8Array(BLOCK)
  for (let i = 0; i < BLOCK; i++) {
    const kb = i < k.length ? k[i] : 0
    ipad[i] = kb ^ 0x36
    opad[i] = kb ^ 0x5c
  }
  const inner = new Uint8Array(BLOCK + msg.length)
  inner.set(ipad)
  inner.set(msg, BLOCK)
  const innerHash = hashFn(inner)
  const outer = new Uint8Array(BLOCK + innerHash.length)
  outer.set(opad)
  outer.set(innerHash, BLOCK)
  return hashFn(outer)
}

/** TURN 凭证专用：base64(HMAC-SHA1(S, username))（契约 §5） */
export function hmacSha1(key: Uint8Array, msg: Uint8Array): Uint8Array {
  return hmac(sha1, key, msg)
}
