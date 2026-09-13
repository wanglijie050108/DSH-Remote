// 插件帧编解码 vs 共享向量（01 §8：单测引用 remotedsh-contract 共享测试向量）
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { encodeFrame, decodeFrame, MAX_PAYLOAD, TYPE } from '../lib/tunnel.js'

const VECTORS = join(dirname(fileURLToPath(import.meta.url)), '..', '..', 'remotedsh-contract', 'vectors')
const load = (f) => JSON.parse(readFileSync(join(VECTORS, f), 'utf8'))

test('plugin frames: encode → exact bytes vs vectors', () => {
  const v = load('frames.json')
  const T = v._meta.types
  for (const c of v.cases) {
    const d = c.decode
    if (c.decode_error || !c.frame_hex || !d || d.flags_read_as !== undefined || d.stream_id_read_as !== undefined || d.type_code !== undefined || !TYPE[d.type]) continue
    let payload
    if (d.payload_hex !== undefined) payload = Buffer.from(d.payload_hex, 'hex')
    else if (d.payload_utf8 !== undefined) payload = Buffer.from(d.payload_utf8, 'utf8')
    else if (d.type === 'WINDOW') { payload = Buffer.alloc(4); payload.writeUInt32BE(d.credit, 0) }
    else if (d.type === 'DATA' && d.payload_len) payload = Buffer.alloc(d.payload_len, 0x61)
    else payload = Buffer.alloc(0)
    const enc = encodeFrame(TYPE[d.type], d.stream_id, payload)
    assert.equal(enc.toString('hex'), c.frame_hex, c.name)
    assert.equal(enc[2], 0, 'sender MUST write flags=0')
  }
})

test('plugin frames: decode semantics vs vectors', () => {
  const v = load('frames.json')
  const T = v._meta.types
  for (const c of v.cases) {
    if (c.decode_error || !c.frame_hex || !c.decode) continue
    const f = decodeFrame(Buffer.from(c.frame_hex, 'hex'))
    const d = c.decode
    assert.equal(f.type, d.type_code ?? T[d.type], c.name)
    assert.equal(f.streamId, d.stream_id_read_as ?? d.stream_id, c.name)
    assert.equal(f.flags, d.flags_read_as ?? d.flags, c.name + '（接收方忽略非 0 flags）')
    if (d.payload_hex !== undefined) assert.equal(f.payload.toString('hex'), d.payload_hex, c.name)
    if (d.payload_utf8 !== undefined) assert.equal(f.payload.toString('utf8'), d.payload_utf8, c.name)
  }
})

test('plugin frames: rejections (BAD_VER / LEN_OVERFLOW / INCOMPLETE)', () => {
  const v = load('frames.json')
  for (const c of v.cases) {
    if (!c.decode_error) continue
    if (c.frame_hex === null && c.construct) {
      assert.throws(() => encodeFrame(0x02, c.construct.stream_id, Buffer.alloc(c.construct.payload_len)), c.name)
      continue
    }
    const f = decodeFrame(Buffer.from(c.frame_hex, 'hex'))
    // 向量错误码 HEADER_INCOMPLETE ↔ 插件实现命名 INCOMPLETE
    assert.equal(f.error, c.decode_error === 'HEADER_INCOMPLETE' ? 'INCOMPLETE' : c.decode_error, c.name)
  }
  assert.equal(MAX_PAYLOAD, 16373)
})

test('plugin frames: RST 风暴回归（§3.3 v1.0.4/v1.0.5）', () => {
  // 终态/未知流的迟到 DATA/FIN/RST 静默忽略；收到 RST 不回；重复/无效 OPEN 静默忽略——由 Tunnel 状态机测试覆盖
  const f = decodeFrame(Buffer.from('01 02 00 00000005 00000003 616263'.replace(/ /g, ''), 'hex'))
  assert.equal(f.streamId, 5)
})
