// 同步 X.509 v3 自签证书构建器（纯 Node crypto，无 WebCrypto → 装配期可同步完成）
// 取代 @peculiar/x509：插件 apply() 必须同步装配（cordis 语义），而 WebCrypto 全部是异步 API。
// 产物是标准 X.509（werift 的 Certificate.fromPEM 直接可读）；ECDSA-SHA256（P-256）。
import { createSign } from 'node:crypto'

const OID_EC_PUBLIC_KEY = '2a8648ce3d0201'      // 1.2.840.10045.2.1
const OID_PRIME256V1 = '2a8648ce3d030107'      // 1.2.840.10045.3.1.7
const OID_ECDSA_WITH_SHA256 = '2a8648ce3d0403' // 1.2.840.10045.4.3.2
const OID_CN = '550403'                        // 2.5.4.3

function len(n) {
  if (n < 0x80) return Buffer.from([n])
  if (n < 0x100) return Buffer.from([0x81, n])
  return Buffer.from([0x82, n >> 8, n & 0xff])
}
function tlv(tag, content) { return Buffer.concat([Buffer.from([tag]), len(content.length), content]) }
function seq(...parts) { return tlv(0x30, Buffer.concat(parts)) }
function oid(dotted) {
  const bytes = [dotted.split('.')[0] * 40 + Number(dotted.split('.')[1])]
  for (const part of dotted.split('.').slice(2)) {
    let v = Number(part)
    const tmp = [v & 0x7f]
    v >>= 7
    while (v > 0) { tmp.unshift((v & 0x7f) | 0x80); v >>= 7 }
    bytes.push(...tmp)
  }
  return tlv(0x06, Buffer.from(bytes))
}
function integer(v) {
  // v: number | BigInt（serial 用 BigInt 防止超长十六进制溢出）
  if (v === 0 || v === 0n) return tlv(0x02, Buffer.from([0]))
  const out = []
  let n = typeof v === 'bigint' ? v : BigInt(v)
  while (n > 0n) { out.unshift(Number(n & 0xffn)); n >>= 8n }
  if (out[0] & 0x80) out.unshift(0)
  return tlv(0x02, Buffer.from(out))
}
function bitString(buf) { return tlv(0x03, Buffer.concat([Buffer.from([0]), buf])) }
function octetString(buf) { return tlv(0x04, buf) }
function utf8String(s) { return tlv(0x0c, Buffer.from(s, 'utf8')) }
function utcTime(d) {
  const yy = String(d.getUTCFullYear()).slice(2)
  const p = (x) => String(x).padStart(2, '0')
  return tlv(0x17, Buffer.from(`${yy}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}Z`))
}
function nameCN(cn) {
  // Name ::= SEQUENCE OF RDN；RDN ::= SET OF AttributeTypeAndValue
  const atv = seq(oid(OID_CN), utf8String(cn))
  return seq(tlv(0x31, atv))
}
/** EC SPKI：直接复用 Node crypto 导出的 DER（保证模板永不失配） */
function spkiFromKey(publicKey) { return publicKey.export({ format: 'der', type: 'spki' }) }

function ecSigAlg() { return seq(oid(OID_ECDSA_WITH_SHA256)) }

/**
 * 生成自签证书 PEM。
 * @param {string} privPem PKCS8 PEM（同时用于签名）
 * @param {import('node:crypto').KeyObject} publicKey 对应公钥
 * @param {{ commonName?: string, notBefore?: Date, notAfter?: Date, serialHex?: string }} opts
 */
export function selfSignedCertPem(privPem, publicKey, opts = {}) {
  const notBefore = opts.notBefore ?? new Date(Date.now() - 24 * 3600 * 1000)
  const notAfter = opts.notAfter ?? new Date(Date.now() + 20 * 365 * 24 * 3600 * 1000)
  const serial = Buffer.from((opts.serialHex ?? '01'), 'hex')

  const tbs = seq(
    tlv(0xa0, integer(2)), // [0] EXPLICIT version = v3
    integer(BigInt('0x' + serial.toString('hex'))),
    ecSigAlg(),
    nameCN(opts.commonName ?? 'dsh-mobile-link'),
    seq(utcTime(notBefore), utcTime(notAfter)),
    nameCN(opts.commonName ?? 'dsh-mobile-link'),
    spkiFromKey(publicKey), // SubjectPublicKeyInfo 已是完整 DER TLV
  )
  const s = createSign('sha256')
  s.update(tbs)
  const sig = s.sign(privPem) // ECDSA-SHA256，DER
  const cert = seq(tbs, ecSigAlg(), bitString(sig))
  return '-----BEGIN CERTIFICATE-----\n' + cert.toString('base64').replace(/(.{64})/g, '$1\n') + '\n-----END CERTIFICATE-----\n'
}

export { OID_EC_PUBLIC_KEY, OID_PRIME256V1 }
