// hello 规范化序列化与签名（契约 §4.2）——三端 MUST 逐字节一致
// 被签名串 = UTF-8 "hello|" + String(ts) + "|" + nonce；sig = ECDSA P-256/SHA-256 DER → base64url
// proto_ver 恒为 "1.0.5"（契约 §7）
import { createSign, createVerify, createHash, createPublicKey, randomBytes } from 'node:crypto'

export const PROTO_VER = '1.0.5'

export function canonicalBytes(ts, nonce) {
  if (!Number.isSafeInteger(ts) || ts < 0) throw new TypeError('ts must be a non-negative integer (epoch seconds)')
  return Buffer.from(`hello|${ts}|${nonce}`, 'utf8') // String(ts) = 十进制 ASCII
}

/** 私钥：PKCS8 PEM。返回 DER → base64url 的 sig（契约 §4.2 明令禁止 P1363） */
export function signHello(privateKeyPem, ts, nonce) {
  const s = createSign('sha256')
  s.update(canonicalBytes(ts, nonce))
  return s.sign(privateKeyPem).toString('base64url')
}

export function verifyHello(pubSpkiPemOrDer, ts, nonce, sigB64url) {
  try {
    const v = createVerify('sha256')
    v.update(canonicalBytes(ts, nonce))
    return v.verify(pubSpkiPemOrDer, Buffer.from(sigB64url, 'base64url'))
  } catch { return false }
}

/** agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1） */
export function sha256PubBase64url(pubSpkiDerOrPem) {
  const der = typeof pubSpkiDerOrPem === 'string'
    ? Buffer.from(pubSpkiDerOrPem.replace(/-----(BEGIN|END) PUBLIC KEY-----/g, '').replace(/\s+/g, ''), 'base64')
    : pubSpkiDerOrPem
  return createHash('sha256').update(der).digest().toString('base64url')
}

/** 组装 hello 消息（契约 §4.1：role/pub/boot_id/ts/nonce/sig/proto_ver） */
export function buildHello({ role, privateKeyPem, bootId, ts = Math.floor(Date.now() / 1000), nonce = randomNonce() }) {
  if (role === 'agent' && !bootId) throw new TypeError('agent MUST carry boot_id (契约 §4.3)')
  return {
    t: 'hello', role, boot_id: bootId,
    pub: pubB64uFromPem(privateKeyPem), ts, nonce,
    sig: signHello(privateKeyPem, ts, nonce), proto_ver: PROTO_VER,
  }
}

function pubB64uFromPem(pem) {
  return createPublicKey(pem).export({ format: 'der', type: 'spki' }).toString('base64url')
}
export const randomNonce = () => randomBytes(32).toString('base64url')
