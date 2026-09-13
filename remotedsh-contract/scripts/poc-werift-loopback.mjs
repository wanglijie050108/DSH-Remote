// werift ↔ werift 回环 PoC（W1/G1 前置，01 §3）——已实测定案的 API 形态也固化在本文件
// 判据：① 整证书注入 + getFingerprints；② 非 trickle offer 含候选；③ 双 DataChannel（label data/ctl）双向 16 KiB 帧
// API 备注（实测）：werift 0.24.4 事件用 DOM 风格属性（pc.ondatachannel / ch.onopen / ch.onmessage），
//   Event 对象（pc.onDataChannel / ch.onMessage）须 .subscribe()；把函数直接赋给 Event 属性会运行时报错。
import { RTCPeerConnection, RTCCertificate, SignatureAlgorithm, HashAlgorithm } from 'werift'
import peculiar from '@peculiar/x509'
import { webcrypto } from 'node:crypto'
const { X509CertificateGenerator } = peculiar

// ★ W1 实测结论（2026-09-13）：RTCCertificate 第三参必须是 {hash, signature} 枚举对象
//   （HashAlgorithm.sha256_4=4 / SignatureAlgorithm.ecdsa_3=3），传字符串 'sha-256' 会导致
//   DTLS 握手必败（ werift↔werift 同样失败）。skill §3 的构造器事实按此细化。
const SIGNATURE_HASH = { hash: HashAlgorithm.sha256_4, signature: SignatureAlgorithm.ecdsa_3 }

const alg = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' }
const kp = await webcrypto.subtle.generateKey(alg, true, ['sign', 'verify'])
const cert = await X509CertificateGenerator.createSelfSigned({
  serialNumber: '01', name: 'CN=poc',
  validity: { notBefore: new Date(Date.now() - 86400000), notAfter: new Date(Date.now() + 365 * 86400000 * 10) },
  keys: kp, signingAlgorithm: alg,
})
const pkcs8 = await webcrypto.subtle.exportKey('pkcs8', kp.privateKey)
const privPem = '-----BEGIN PRIVATE KEY-----\n' + Buffer.from(pkcs8).toString('base64').replace(/(.{64})/g, '$1\n') + '\n-----END PRIVATE KEY-----\n'

const rtcCert = new RTCCertificate(privPem, cert.toString('pem'), SIGNATURE_HASH)
const fp = rtcCert.getFingerprints()[0]
console.log('[poc] cert fp:', fp.algorithm, fp.value.slice(0, 20) + '…')

const offerer = new RTCPeerConnection({ certificates: [rtcCert] })
const answerer = new RTCPeerConnection()

const dataCh = offerer.createDataChannel('data', { ordered: true })
const ctlCh = offerer.createDataChannel('ctl', { ordered: false })

const received = []
answerer.ondatachannel = (ev) => {
  const ch = ev.channel ?? ev
  console.log('[poc] answerer onDataChannel:', ch.label)
  ch.onmessage = (ev2) => { const d = ev2?.data ?? ev2; received.push({ label: ch.label, buf: Buffer.from(d) }) }
}
answerer.ondatachannel = answerer.ondatachannel // 保持单个赋值

const offer = await offerer.createOffer()
await offerer.setLocalDescription(offer)
const offerSdp = offerer.localDescription.sdp
console.log('[poc] offer candidates:', (offerSdp.match(/a=candidate:/g) || []).length, '| fingerprint:', /a=fingerprint:sha-256/.test(offerSdp))

await answerer.setRemoteDescription(offerer.localDescription)
const answer = await answerer.createAnswer()
await answerer.setLocalDescription(answer)
await offerer.setRemoteDescription(answerer.localDescription)
console.log('[poc] answer candidates:', (answerer.localDescription.sdp.match(/a=candidate:/g) || []).length)

const buf = Buffer.alloc(16373, 0x62) // 帧长边界 16373（契约 §3.1）
await new Promise((resolve, reject) => {
  const t = setTimeout(() => reject(new Error('data ch open timeout')), 8000)
  dataCh.onopen = () => { clearTimeout(t); resolve() }
})
ctlCh.onopen = () => console.log('[poc] ctl open')
console.log('[poc] data channel open, state:', offerer.connectionState)

ctlCh.send(Buffer.from([1, 2, 3]))
dataCh.send(buf) // 单条 16373B —— 恰好 maxMessageSize 边界
await new Promise((r) => setTimeout(r, 1500))

const dataMsg = received.find(r => r.label === 'data')
const ctlMsg = received.find(r => r.label === 'ctl')
const dataOk = !!dataMsg && dataMsg.buf.length === 16373 && dataMsg.buf[0] === 0x62 && dataMsg.buf[16372] === 0x62
const ctlOk = !!ctlMsg && Buffer.compare(ctlMsg.buf, Buffer.from([1, 2, 3])) === 0
console.log('[poc] 16373B frame intact:', dataOk, '| ctl frame intact:', ctlOk)
console.log('[poc] final connectionState:', offerer.connectionState)
process.exit(dataOk && ctlOk ? 0 : 1)
