// 身份密钥与 DTLS 证书（01 §4.1 / 契约 §6）——全同步（apply() 装配期语义）
// 关键不变式（skill §3.1 安全锚）：a=fingerprint 是整张证书的哈希（不是公钥哈希），因此 DTLS 证书
// 必须**整证书持久化**（证书+私钥一起存）；重新派生的证书序列号/有效期不同 → 指纹变化 → 手机 pin 全部失效。
// 存储：$DSH_HOME/mobile-link/identity.json（Windows 不写 chmod 0600 —— 该语义在 Windows 不成立，01 §4.1）。
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes } from 'node:crypto'
import { selfSignedCertPem } from './cert.js'
import { RTCCertificate } from 'werift' // 纯定义 import（01 §2.1：import 期零 IO/零网络）

export class KeysError extends Error {}

/** 解析 $DSH_HOME（与 DSH 自身 .credentials.yaml 同一约定，01 §4.1） */
export function dshHome(env = process.env) {
  return env.DSH_HOME || join(env.USERPROFILE || env.HOME || '.', '.dsh')
}

function identityPath(env) {
  return join(dshHome(env), 'mobile-link', 'identity.json')
}

function b64u(buf) { return Buffer.from(buf).toString('base64url') }

/** 一次性生成：身份密钥（P-256，hello 签名）+ DTLS 证书（P-256，整证书持久化） */
function generate() {
  const idPair = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const privPem = idPair.privateKey.export({ format: 'pem', type: 'pkcs8' }).toString()
  const pubB64u = b64u(idPair.publicKey.export({ format: 'der', type: 'spki' }))
  const dtlsPair = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const dtlsKeyPem = dtlsPair.privateKey.export({ format: 'pem', type: 'pkcs8' }).toString()
  const certPem = selfSignedCertPem(dtlsKeyPem, dtlsPair.publicKey, {
    commonName: 'dsh-mobile-link',
    serialHex: randomBytes(8).toString('hex') || '01',
  })
  return { version: 1, privPem, pubB64u, dtls: { certPem, keyPem: dtlsKeyPem } }
}

/**
 * 载入或首次生成身份。损坏 → fail-fast（01 §2.1：报错并给出恢复方式）。
 * @returns {{ privPem, pubB64u, dtls:{certPem,keyPem}, agentId, path }}
 */
export function loadIdentity(env = process.env) {
  const path = identityPath(env)
  let raw
  if (existsSync(path)) {
    try {
      raw = JSON.parse(readFileSync(path, 'utf8'))
    } catch (e) {
      throw new KeysError(`身份文件损坏（${path}）：${e.message}。恢复方式：删除该文件后重启，将自动生成新钥，但所有手机需重新扫码。（01 §2.1）`)
    }
  } else {
    raw = generate()
    mkdirSync(dirname(path), { recursive: true })
    writeFileSync(path, JSON.stringify(raw, null, 2))
  }
  if (!raw?.privPem || !raw?.pubB64u || !raw?.dtls?.certPem || !raw?.dtls?.keyPem) {
    throw new KeysError(`身份文件字段缺失（${path}）。恢复方式：删除该文件后重启，将自动生成新钥，但所有手机需重新扫码。`)
  }
  try { createPrivateKey(raw.privPem) } catch {
    throw new KeysError(`身份文件私钥无法解析（${path}）。恢复方式：删除该文件后重启，将自动生成新钥，但所有手机需重新扫码。`)
  }
  const agentId = createHash('sha256').update(Buffer.from(raw.pubB64u, 'base64url')).digest('base64url') // 契约 §4.1
  return { ...raw, agentId, path }
}

/** 由持久化的 DTLS 证书构造 werift RTCCertificate 并取 sha-256 指纹（QR 的 fp，契约 §6：SHOULD 取 getFingerprints()） */
export function createDtlsCertificate(id) {
  // ★ W1 实测（remotedsh-contract/scripts/poc-werift-loopback.mjs）：第三参必须是 {hash, signature} 枚举对象；
  //   传字符串 'sha-256' 时 DTLS 握手必败（werift↔werift 同样失败）。
  const SIGNATURE_HASH = { hash: 4 /* HashAlgorithm.sha256_4 */, signature: 3 /* SignatureAlgorithm.ecdsa_3 */ }
  const cert = new RTCCertificate(id.dtls.keyPem, id.dtls.certPem, SIGNATURE_HASH)
  const fp = cert.getFingerprints().find((f) => String(f.algorithm).toLowerCase() === 'sha-256')
  if (!fp?.value) throw new KeysError('无法取得 DTLS 证书 sha-256 指纹（getFingerprints()）')
  return { certificate: cert, fp: fp.value }
}
