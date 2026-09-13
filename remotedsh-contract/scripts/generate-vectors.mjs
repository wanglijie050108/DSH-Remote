// 生成共享测试向量（一次性运行，产物提交入库；重跑会生成新随机密钥 → 不要重跑后覆盖已发布的向量）
// 依据：契约 §4.2（hello 规范化序列化）、§3.1/§3.2（帧格式）、§6.1（pin 归一）、§2（QR 载荷）
// 签名向量用 @noble/curves 的 RFC 6979 确定性 ECDSA 生成期望签名；
//   Go / Java 标准库是随机化 ECDSA，不要求复现该签名，但 MUST 通过「验证该签名」+「被签字节串逐字节一致」断言（05 §2 G2 门禁）。
import { p256 } from '@noble/curves/p256'
import { sha256 } from '@noble/hashes/sha256'
import { writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import crypto from 'node:crypto'

const here = join(dirname(fileURLToPath(import.meta.url)), '..', 'vectors')

const b64url = (buf) => Buffer.from(buf).toString('base64url')
const hex = (buf) => Buffer.from(buf).toString('hex')

// ---------- hello 签名向量 ----------
// P-256 密钥模板（标准最小 PKCS8，67B）：
// SEQUENCE(65){ INTEGER 0; SEQ(19){OID 1.2.840.10045.2.1; OID 1.2.840.10045.3.1.7};
//   OCTET STRING(39){ SEQ(37){ INTEGER 1; OCTET STRING(32) scalar } } }
// SPKI(P-256) = 30 59 30 13 06 07 2a8648ce3d0201 06 08 2a8648ce3d030107 03 42 00 |0x04|X|Y|
const PKCS8_PREFIX = '3041020100301306072a8648ce3d020106082a8648ce3d03010704273025020101' + '0420'
function pkcs8Pem(scalar) {
  const der = Buffer.concat([Buffer.from(PKCS8_PREFIX, 'hex'), scalar])
  if (der.length !== 67) throw new Error(`PKCS8 template length broken: ${der.length}`)
  return '-----BEGIN PRIVATE KEY-----\n' + der.toString('base64').replace(/(.{64})/g, '$1\n') + '\n-----END PRIVATE KEY-----\n'
}
function spkiDer(pub) {
  return Buffer.concat([
    Buffer.from('3059301306072a8648ce3d020106082a8648ce3d030107034200', 'hex'), pub,
  ])
}

const priv = p256.utils.randomPrivateKey()
const pub = p256.getPublicKey(priv, false) // 未压缩点（65B = 0x04‖X‖Y），SPKI 模板按此构建
const privPem = pkcs8Pem(priv)
const pubB64u = b64url(spkiDer(pub))
if (spkiDer(pub).length !== 91) throw new Error('SPKI template broken')

// Node 标准库交叉验证 noble 产物（保证向量自身自洽：noble 签的，Node 验得过）
const keyObj = crypto.createPrivateKey(privPem)
const pubKeyObj = crypto.createPublicKey(keyObj)

const helloCases = []
for (const [ts, nonceSeed] of [
  [1770000000, 'a1'], [0, 'b2'], [9223372036854775807 >> 8, 'c3'],
]) {
  const nonce = b64url(p256.utils.randomPrivateKey()) // 32B → base64url（长度恰为 43，无填充）
  const msg = Buffer.from(`hello|${ts}|${nonce}`, 'utf8')
  const sig = p256.sign(sha256(msg), priv).toDERRawBytes() // RFC 6979 确定性，DER 编码
  const ok = crypto.verify('sha256', msg, pubKeyObj, sig)
  if (!ok) throw new Error('noble/Node 自洽性失败')
  helloCases.push({
    name: `ts=${ts} nonce=${nonce.slice(0, 8)}…`,
    ts, // JSON number，十进制整数（契约 §4.2）
    nonce,
    pub: pubB64u,
    expected_msg_hex: hex(msg), // 被签字节串：三端 MUST 逐字节一致（G2）
    expected_sig_base64url: b64url(sig), // RFC 6979 确定性签名；Go/Java 只验证不复现
    expect_verify: true,
  })
}
// 负例：篡改消息 / 篡改签名 / 换公钥
{
  const c = helloCases[0]
  helloCases.push({
    name: 'tampered ts (auth fail)',
    ts: c.ts + 1, nonce: c.nonce, pub: pubB64u, expected_msg_hex: null,
    expected_sig_base64url: c.expected_sig_base64url, expect_verify: false,
  })
  const bad = Buffer.from(c.expected_sig_base64url, 'base64url'); bad[8] ^= 0x01
  helloCases.push({
    name: 'tampered sig', ts: c.ts, nonce: c.nonce, pub: pubB64u, expected_msg_hex: c.expected_msg_hex,
    expected_sig_base64url: b64url(bad), expect_verify: false,
  })
  const other = p256.utils.randomPrivateKey()
  helloCases.push({
    name: 'wrong pub key', ts: c.ts, nonce: c.nonce,
    pub: b64url(spkiDer(p256.getPublicKey(other, false))), expected_msg_hex: c.expected_msg_hex,
    expected_sig_base64url: c.expected_sig_base64url, expect_verify: false,
  })
}

writeFileSync(join(here, 'hello-signature.json'), JSON.stringify({
  _meta: {
    source: '契约 §4.2 · docs/05 §2 G2 · scripts/generate-vectors.mjs 生成',
    rules: {
      ts: 'epoch 秒，十进制整数，无小数/前导零/指数',
      msg: 'UTF-8 "hello|" + String(ts) + "|" + nonce',
      nonce: '32B 随机 → base64url 无填充',
      sig: 'ECDSA P-256/SHA-256，DER(ASN.1 SEQUENCE(r,s)) → base64url；不得 P1363',
      pub: 'SPKI DER → base64url',
      note: 'expected_sig 为 RFC 6979 确定性签名：JS(@noble) 可断言复现；Go/Java(随机化 ECDSA) MUST 断言「验证通过」而非「逐字节复现」',
    },
    private_key_pkcs8_pem: privPem, // 仅测试密钥，不入生产
  },
  cases: helloCases,
}, null, 2) + '\n')

// ---------- 帧向量（契约 §3.1/§3.2） ----------
const AUTHORITY = '127.0.0.1:13080' // 契约 §1 固定值
const openPayload = JSON.stringify({ authority: AUTHORITY })
const ping8 = Buffer.from('0011223344556677', 'hex')
const dataPayload = Buffer.from('68656c6c6f20e4b8ade6968720f09f918b', 'hex') // "hello 中文 👋" — 字节透明，UTF-8 多字节原样

function frameBytes(ver, type, flags, streamId, payload) {
  const h = Buffer.alloc(11)
  h.writeUInt8(ver, 0); h.writeUInt8(type, 1); h.writeUInt8(flags, 2)
  h.writeUInt32BE(streamId, 3); h.writeUInt32BE(payload.length, 7)
  return Buffer.concat([h, payload])
}

const T = { OPEN: 0x01, DATA: 0x02, FIN: 0x03, RST: 0x04, WINDOW: 0x05, PING: 0x06, PONG: 0x07 }

const frameCases = [
  { name: 'OPEN authority', frame_hex: hex(frameBytes(1, T.OPEN, 0, 1, Buffer.from(openPayload, 'utf8'))), decode: { ver: 1, type: 'OPEN', flags: 0, stream_id: 1, payload_hex: hex(Buffer.from(openPayload, 'utf8')), payload_utf8: openPayload } },
  { name: 'DATA bytes are opaque (UTF-8 multi-byte untouched)', frame_hex: hex(frameBytes(1, T.DATA, 0, 7, dataPayload)), decode: { ver: 1, type: 'DATA', flags: 0, stream_id: 7, payload_hex: hex(dataPayload) } },
  { name: 'FIN empty payload', frame_hex: hex(frameBytes(1, T.FIN, 0, 3, Buffer.alloc(0))), decode: { ver: 1, type: 'FIN', flags: 0, stream_id: 3, payload_hex: '' } },
  { name: 'RST with reason', frame_hex: hex(frameBytes(1, T.RST, 0, 9, Buffer.from('stream limit', 'utf8'))), decode: { ver: 1, type: 'RST', flags: 0, stream_id: 9, payload_utf8: 'stream limit' } },
  { name: 'WINDOW credit 65536 (delta semantics §3.4)', frame_hex: hex(frameBytes(1, T.WINDOW, 0, 2, (() => { const b = Buffer.alloc(4); b.writeUInt32BE(65536, 0); return b })())), decode: { ver: 1, type: 'WINDOW', flags: 0, stream_id: 2, credit: 65536 } },
  { name: 'PING stream_id MUST be 0', frame_hex: hex(frameBytes(1, T.PING, 0, 0, ping8)), decode: { ver: 1, type: 'PING', flags: 0, stream_id: 0, payload_hex: hex(ping8) } },
  { name: 'PONG echoes PING payload, stream_id 0', frame_hex: hex(frameBytes(1, T.PONG, 0, 0, ping8)), decode: { ver: 1, type: 'PONG', flags: 0, stream_id: 0, payload_hex: hex(ping8) } },
  { name: 'boundary: len=16373 (max, total 16384) valid', frame_hex: hex(frameBytes(1, T.DATA, 0, 1, Buffer.alloc(16373, 0x61))), decode: { ver: 1, type: 'DATA', flags: 0, stream_id: 1, payload_len: 16373 }, note: '实现可按 payload 摘要断言，避免向量文件膨胀' },
  // 负例 / 接收方宽容性
  { name: 'ver=2 → reject (§3.1 非 1 立即断开)', frame_hex: hex(frameBytes(2, T.DATA, 0, 1, Buffer.from('x'))), decode_error: 'BAD_VER' },
  { name: 'len=16374 → reject + RST (§3.1 超限)', frame_hex: null, construct: { ver: 1, type: 'DATA', flags: 0, stream_id: 1, payload_len: 16374 }, decode_error: 'LEN_OVERFLOW' },
  { name: 'header truncated (7B) → incomplete, 丢弃并计错', frame_hex: '00010200000001', decode_error: 'HEADER_INCOMPLETE' },
  { name: 'flags=0x05 → receiver MUST ignore and decode (§3.1)', frame_hex: hex(frameBytes(1, T.DATA, 5, 4, Buffer.from('ok'))), decode: { ver: 1, type: 'DATA', flags_read_as: 5, stream_id: 4, payload_utf8: 'ok' } },
  { name: 'unknown type 0x2A → decode succeeds, dispatcher MUST silently ignore + count error, NOT close (§3.3)', frame_hex: hex(frameBytes(1, 0x2A, 0, 4, Buffer.from('y'))), decode: { ver: 1, type_code: 0x2A, flags: 0, stream_id: 4, payload_utf8: 'y' } },
  { name: 'PING with stream_id=5 → control frames ignore stream_id (§3.1)', frame_hex: hex(frameBytes(1, T.PING, 0, 5, ping8)), decode: { ver: 1, type: 'PING', flags: 0, stream_id_read_as: 5, payload_hex: hex(ping8) } },
]
writeFileSync(join(here, 'frames.json'), JSON.stringify({
  _meta: { source: '契约 §3.1/§3.2/§3.3 · scripts/generate-vectors.mjs 生成', types: T, header: '11B BE: ver u8, type u8, flags u8, stream_id u32, len u32' },
  cases: frameCases,
}, null, 2) + '\n')

// ---------- fingerprint 归一向量（契约 §6.1） ----------
const fpv = [
  { name: 'plain sha-256 line', offer_lines: ['a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'], expect: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' },
  { name: 'case/colon/whitespace normalization', offer_lines: ['a=fingerprint:sha-256 aa:bb:cc dd:ee:ff:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'], expect: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' },
  { name: 'hash-func with custom bits (sha-512) plus sha-256 line → take sha-256', offer_lines: ['a=fingerprint:sha-512 11:22:33', 'a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'], expect: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' },
  { name: 'session sha-1 + media sha-256 → sha-256 wins (RFC 8122 §5.1)', offer_lines: ['a=fingerprint:sha-1 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33', 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel', 'a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99'], expect: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' },
  { name: 'media sha-1 + session sha-256 → sha-256 line exists at session level → take it', offer_lines: ['a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99', 'm=application 9 UDP/DTLS/SCTP webrtc-datachannel', 'a=fingerprint:sha-1 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33'], expect: 'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899' },
  { name: 'only sha-1 → fail-closed (§6.1 无 sha-256 行立即中止)', offer_lines: ['a=fingerprint:sha-1 00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33'], expect: null },
  { name: 'no fingerprint at all → fail-closed', offer_lines: ['m=application 9 UDP/DTLS/SCTP webrtc-datachannel'], expect: null },
]
writeFileSync(join(here, 'fingerprint-normalize.json'), JSON.stringify({
  _meta: { source: '契约 §6.1 · scripts/generate-vectors.mjs 生成', rule: '取 sha-256 行（多行时归一后等于 sha-256 者；两级冲突 media 级为准）→ 剥前缀 → 删全部冒号与空白 → ASCII 小写 → 按字节比较；无 sha-256 行 = fail-closed' },
  cases: fpv,
}, null, 2) + '\n')

// ---------- QR 配对载荷向量（契约 §2） ----------
writeFileSync(join(here, 'qr-pair.json'), JSON.stringify({
  _meta: { source: '契约 §2 · scripts/generate-vectors.mjs 生成' },
  cases: [
    { name: 'full with token', uri: 'dshlink://pair?v=1&s=wss%3A%2F%2Fbridge.example.com%2Fv1%2Fsignal&pt=abc_def-123&fp=AA%3ABB%3ACC&a=127.0.0.1%3A13080&t=eyJhbGciOi', expect: { v: 1, s: 'wss://bridge.example.com/v1/signal', pt: 'abc_def-123', fp: 'AA:BB:CC', a: '127.0.0.1:13080', t: 'eyJhbGciOi' } },
    { name: 'without optional token', uri: 'dshlink://pair?v=1&s=wss%3A%2F%2Fbridge.example.com%2Fv1%2Fsignal&pt=xyz&fp=AA%3ABB%3ACC&a=127.0.0.1%3A13080', expect: { v: 1, s: 'wss://bridge.example.com/v1/signal', pt: 'xyz', fp: 'AA:BB:CC', a: '127.0.0.1:13080', t: null } },
    { name: 'missing pt → error', uri: 'dshlink://pair?v=1&s=wss%3A%2F%2Fb.example.com%2Fv1%2Fsignal&fp=AA&a=127.0.0.1%3A13080', expect: null },
    { name: 'wrong version v=2 → error', uri: 'dshlink://pair?v=2&s=wss%3A%2F%2Fb.example.com%2Fv1%2Fsignal&pt=x&fp=AA&a=127.0.0.1%3A13080', expect: null },
    { name: 'not a dshlink URL → error', uri: 'https://example.com/?v=1', expect: null },
  ],
}, null, 2) + '\n')

console.log('vectors written:', ['hello-signature.json', 'frames.json', 'fingerprint-normalize.json', 'qr-pair.json'].map(f => join('vectors', f)).join(', '))
console.log('test priv key fingerprint check: pub =', pubB64u.slice(0, 16) + '…')
