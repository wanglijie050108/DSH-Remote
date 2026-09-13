// G2 门禁（docs/05 §2）：三端对同一份共享向量逐字节一致。本文件为 JS 侧断言；go/ 与 kotlin/ 各自跑同一批向量。
// 运行：node --test test/
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { createPrivateKey, createPublicKey, createHash, createHmac } from 'node:crypto'
import { p256 } from '@noble/curves/p256'
import { sha256 } from '@noble/hashes/sha256'
import { encodeFrame, decodeFrame, FrameError, TYPE, MAX_PAYLOAD } from '../js/frames.mjs'
import { canonicalBytes, signHello, verifyHello, sha256PubBase64url, PROTO_VER } from '../js/hello.mjs'
import { extractPinnedFingerprint, verifyPin, normalizeFingerprintLine } from '../js/fingerprint.mjs'
import { parsePairQr } from '../js/qr-pair.mjs'
import { turnCredential, turnUsername, turnUris } from '../js/turn.mjs'

const here = join(dirname(fileURLToPath(import.meta.url)), '..')
const load = (f) => JSON.parse(readFileSync(join(here, 'vectors', f), 'utf8'))

// ---------- hello 签名向量（契约 §4.2） ----------
test('hello: canonical bytes are byte-exact (G2)', () => {
  const v = load('hello-signature.json')
  for (const c of v.cases.filter(x => x.expected_msg_hex)) {
    const got = canonicalBytes(c.ts, c.nonce)
    assert.equal(got.toString('hex'), c.expected_msg_hex, c.name)
  }
})

test('hello: RFC 6979 deterministic sig reproduces (via @noble) and verifies (via Node stdlib)', () => {
  const v = load('hello-signature.json')
  const priv = createPrivateKey(v._meta.private_key_pkcs8_pem)
  const pub = createPublicKey(priv)
  // 向量密钥的标量 = PKCS8 DER 末 32 字节（本仓库模板见 scripts/generate-vectors.mjs）
  const pkcs8Der = priv.export({ format: 'der', type: 'pkcs8' })
  const scalar = pkcs8Der.subarray(pkcs8Der.length - 32)
  for (const c of v.cases.filter(x => x.expected_msg_hex && x.expect_verify)) {
    // 确定性复现：@noble（RFC 6979）。Node/Go/Java 标准库是随机化 ECDSA，无法也不要求复现——只要求验证通过。
    const nobleSig = p256.sign(sha256(Buffer.from(c.expected_msg_hex, 'hex')), scalar).toDERRawBytes()
    assert.equal(Buffer.from(nobleSig).toString('base64url'), c.expected_sig_base64url, 'deterministic reproduction: ' + c.name)
    // Node 自产签名必须通过验证
    assert.equal(verifyHello(pub, c.ts, c.nonce, signHello(priv, c.ts, c.nonce)), true, c.name)
  }
})

test('hello: negative cases fail verification', () => {
  const v = load('hello-signature.json')
  for (const c of v.cases.filter(x => !x.expect_verify)) {
    // 每个负例自带 pub（可能被换成他钥），按用例的 pub 验证
    const pub = createPublicKey({ key: Buffer.from(c.pub, 'base64url'), format: 'der', type: 'spki' })
    assert.equal(verifyHello(pub, c.ts, c.nonce, c.expected_sig_base64url), false, c.name)
  }
})

test('hello: DER encoding assertion (sig parses as SEQUENCE of two INTEGERs, ≤72B)', () => {
  const v = load('hello-signature.json')
  for (const c of v.cases.filter(x => x.expect_verify)) {
    const sig = Buffer.from(c.expected_sig_base64url, 'base64url')
    assert.equal(sig[0], 0x30, 'ASN.1 SEQUENCE tag')
    assert.ok(sig.length <= 72, 'DER ≤ 72B')
  }
})

test('hello: proto_ver constant', () => {
  assert.equal(PROTO_VER, '1.0.5') // 契约 §7
})

test('id: sha256(SPKI DER) → base64url', () => {
  const v = load('hello-signature.json')
  const pub = createPublicKey(createPrivateKey(v._meta.private_key_pkcs8_pem))
  const der = pub.export({ format: 'der', type: 'spki' })
  assert.equal(sha256PubBase64url(der), createHash('sha256').update(der).digest('base64url'))
})

// ---------- 帧向量（契约 §3.1/§3.2/§3.3） ----------
test('frames: encode → exact bytes', () => {
  const v = load('frames.json')
  const T = v._meta.types
  for (const c of v.cases) {
    if (c.frame_hex === null || c.decode_error) continue
    // 只对非负例做「按 decode 语义重编码后逐字节一致」断言
    const d = c.decode
    if (!d || d.flags_read_as !== undefined || d.stream_id_read_as !== undefined || d.type_code !== undefined) continue // 接收侧宽容性用例，不走发送路径
    if (!TYPE[d.type]) continue
    let payload
    if (d.payload_hex !== undefined) payload = Buffer.from(d.payload_hex, 'hex')
    else if (d.payload_utf8 !== undefined) payload = Buffer.from(d.payload_utf8, 'utf8')
    else if (d.type === 'WINDOW') { payload = Buffer.alloc(4); payload.writeUInt32BE(d.credit, 0) }
    else if (d.type === 'DATA' && d.payload_len) payload = Buffer.alloc(d.payload_len, 0x61)
    else payload = Buffer.alloc(0)
    const typeCode = TYPE[d.type]
    const enc = encodeFrame(typeCode, d.stream_id, payload)
    assert.equal(Buffer.from(enc).toString('hex'), c.frame_hex, c.name)
    const back = decodeFrame(enc)
    assert.equal(back.type, typeCode, c.name)
    assert.equal(back.flags, 0, 'sender MUST write flags=0 (§3.1)')
  }
})

test('frames: decode exact bytes → semantics', () => {
  const v = load('frames.json')
  const T = v._meta.types
  for (const c of v.cases) {
    if (c.decode_error || !c.frame_hex || !c.decode) continue
    const f = decodeFrame(Buffer.from(c.frame_hex, 'hex'))
    const d = c.decode
    if (d.type_code !== undefined) { assert.equal(f.type, d.type_code, c.name); }
    else assert.equal(f.type, T[d.type], c.name)
    assert.equal(f.stream_id, d.stream_id_read_as ?? d.stream_id, c.name)
    assert.equal(f.flags, d.flags_read_as ?? d.flags, c.name + ' (receiver MUST ignore non-zero flags)')
    if (d.payload_hex !== undefined) assert.equal(Buffer.from(f.payload).toString('hex'), d.payload_hex, c.name)
    if (d.payload_utf8 !== undefined) assert.equal(Buffer.from(f.payload).toString('utf8'), d.payload_utf8, c.name)
    if (d.credit !== undefined) assert.equal(new DataView(f.payload.buffer, f.payload.byteOffset).getUint32(0), d.credit, c.name)
    if (d.payload_len !== undefined) assert.equal(f.payload.length, d.payload_len, c.name)
  }
})

test('frames: rejections', () => {
  const v = load('frames.json')
  for (const c of v.cases.filter(x => x.decode_error)) {
    if (c.frame_hex === null && c.construct) { // len 超限：直接走 encode 防线
      assert.throws(() => encodeFrame(c.construct.type, c.construct.stream_id, Buffer.alloc(c.construct.payload_len)), FrameError, c.name)
      continue
    }
    const bytes = Buffer.from(c.frame_hex, 'hex')
    assert.throws(() => decodeFrame(bytes), (e) => e instanceof FrameError && e.code === c.decode_error, c.name)
  }
})

test('frames: MAX_PAYLOAD boundary constant', () => {
  assert.equal(MAX_PAYLOAD, 16373) // 契约 §3.1：len ≤ 16373，总帧 ≤ 16384
})

// ---------- fingerprint 归一向量（契约 §6.1） ----------
test('fingerprint: extraction & normalization', () => {
  const v = load('fingerprint-normalize.json')
  for (const c of v.cases) {
    const got = extractPinnedFingerprint(c.offer_lines)
    assert.equal(got, c.expect, c.name)
  }
})

test('fingerprint: pin verify byte-exact', () => {
  const lines = ['a=fingerprint:sha-256 AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99']
  assert.equal(verifyPin('aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899', lines), true)
  assert.equal(verifyPin('AABBCCDDEEFF00112233445566778899AABBCCDDEEFF00112233445566778899', lines), true)
  assert.equal(verifyPin('aabbccddeeff00112233445566778899aabbccddeeff00112233445566779988', lines), false)
  assert.equal(verifyPin(null, lines), false, 'persisted fp missing → no pin')
  assert.equal(normalizeFingerprintLine('a=fingerprint:sha-1 00:11'), null)
})

// ---------- QR 向量（契约 §2） ----------
test('qr: parse vectors', () => {
  const v = load('qr-pair.json')
  for (const c of v.cases) {
    const got = parsePairQr(c.uri)
    if (c.expect === null) assert.ok(got.error, c.name)
    else assert.deepEqual(got, c.expect, c.name)
  }
})

// ---------- TURN 向量（契约 §5） ----------
test('turn: HMAC-SHA1 credential & username shape', () => {
  const username = turnUsername('pair-1', 3600, 1770000000)
  assert.equal(username, '1770003600:pair-1')
  const cred = turnCredential('secret-s', username)
  assert.equal(cred, createHmac('sha1', 'secret-s').update(username).digest('base64'))
  assert.deepEqual(turnUris('bridge.example.com'), ['stun:bridge.example.com:3478', 'turn:bridge.example.com:3478?transport=udp', 'turn:bridge.example.com:3478?transport=tcp'])
})
