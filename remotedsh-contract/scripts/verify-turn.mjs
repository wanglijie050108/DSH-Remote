#!/usr/bin/env node
// verify-turn —— 对真实 coturn 做 STUN 绑定 + 完整 TURN Allocate（02 §7 契约项：凭证与真实 coturn 互通实测）
// 用法：node scripts/verify-turn.mjs <host> <secret> [--pair probe-pair]
// 凭证按契约 §5 计算：username = "<expire>:<pair_id>"，credential = base64(HMAC-SHA1(secret, username))
// 流程（RFC 5389/8656 长期凭证机制）：Allocate(无凭证) → 401(NONCE/REALM) → Allocate(USERNAME/REALM/NONCE/MESSAGE-INTEGRITY) → 成功响应含 XOR-RELAYED-ADDRESS
import dgram from 'node:dgram'
import { createHmac, createHash, randomBytes } from 'node:crypto'

const [host = '127.0.0.1', secret = 'test', flag] = process.argv.slice(2)
const pairId = flag === '--pair' ? process.argv[4] : 'probe-pair'
const PORT = 3478
const COOKIE = 0x2112a442

const username = `${Math.floor(Date.now() / 1000) + 3600}:${pairId}`
const password = createHmac('sha1', secret).update(username).digest('base64')
console.log(`目标: ${host}:${PORT}  username=${username}`)

const attr = (type, value) => {
  const v = Buffer.isBuffer(value) ? value : Buffer.from(value)
  const pad = Buffer.alloc((4 - (v.length % 4)) % 4)
  const b = Buffer.alloc(4 + v.length + pad.length)
  b.writeUInt16BE(type, 0); b.writeUInt16BE(v.length, 2); v.copy(b, 4)
  return b
}
const header = (type, len, txid) => {
  const h = Buffer.alloc(20)
  h.writeUInt16BE(type, 0); h.writeUInt16BE(len, 2); h.writeUInt32BE(COOKIE, 4)
  txid.copy(h, 8)
  return h
}
const newTxid = () => randomBytes(12)

function parseAttrs(buf) {
  const out = {}
  let off = 20
  while (off + 4 <= buf.length) {
    const type = buf.readUInt16BE(off)
    const len = buf.readUInt16BE(off + 2)
    out[type] = buf.subarray(off + 4, off + 4 + len)
    off += 4 + len + ((4 - (len % 4)) % 4)
  }
  return out
}
const xorAddr = (v) => {
  const port = v.readUInt16BE(2) ^ (COOKIE >>> 16)
  const ip = [0, 1, 2, 3].map(i => v[4 + i] ^ ((COOKIE >>> (24 - 8 * i)) & 0xff)).join('.')
  return `${ip}:${port}`
}

const errCodeOf = (v) => (v ? (v[2] & 0x07) * 100 + v[3] : 0) // ERROR-CODE: class(3b)×100 + number(8b)（RFC 5389 §15.6）

function buildAllocate(txid, { username, realm, nonce, key }) {
  const attrs = [attr(0x0012, Buffer.from([17, 0, 0, 0]))] // REQUESTED-TRANSPORT = UDP
  if (username) attrs.push(attr(0x0006, username))
  if (realm) attrs.push(attr(0x0014, realm))
  if (nonce) attrs.push(attr(0x0015, nonce))
  const attrsLen = attrs.reduce((n, a) => n + a.length, 0)
  const miLen = key ? 24 : 0
  let msg = Buffer.concat([header(0x0003, attrsLen + miLen, txid), ...attrs])
  if (key) {
    const mi = createHmac('sha1', key).update(msg).digest() // 长期凭证：key = MD5(user:realm:pass)
    msg = Buffer.concat([msg, attr(0x0008, mi)])
  }
  return msg
}

const sock = dgram.createSocket('udp4')
const pending = new Map()
sock.on('message', (buf) => {
  const txid = buf.subarray(8, 20).toString('hex')
  pending.get(txid)?.(parseAttrs(buf), buf.readUInt16BE(0))
})
const request = (msg, timeoutMs = 3000) => new Promise((resolve, reject) => {
  const txid = msg.subarray(8, 20)
  const t = setTimeout(() => { pending.delete(txid.toString('hex')); reject(new Error('TIMEOUT（安全组 UDP 3478 未放行？）')) }, timeoutMs)
  pending.set(txid.toString('hex'), (attrs, type) => { clearTimeout(t); pending.delete(txid.toString('hex')); resolve({ attrs, type }) })
  sock.send(msg, PORT, host)
})

sock.bind(() => main())

async function main() {
  try {
    // ① STUN 绑定（裸 STUN，最基础的连通性）
    const bindingTxid = newTxid()
    const { attrs: bAttrs } = await request(header(0x0001, 0, bindingTxid))
    console.log('① STUN 绑定:', bAttrs[0x0020] ? 'PASS → 自见地址 ' + xorAddr(bAttrs[0x0020]) : '响应但无 XOR-MAPPED-ADDRESS')

    // ② Allocate 第一跳：预期 401 + NONCE/REALM
    const txid1 = newTxid()
    const r1 = await request(buildAllocate(txid1, {}))
    const code = errCodeOf(r1.attrs[0x0009])
    if (code !== 401) throw new Error(`预期 401，实得 ${code}`)
    const nonce = r1.attrs[0x0015].toString()
    const realm = r1.attrs[0x0014].toString()
    console.log(`② Allocate 首跳: 401 如期，realm=${realm}, nonce=${nonce.slice(0, 12)}…`)

    // ③ 带凭证 Allocate（长期凭证 key = MD5(user:realm:pass)）
    const key = createHash('md5').update(`${username}:${realm}:${password}`).digest()
    const txid2 = newTxid()
    const r2 = await request(buildAllocate(txid2, { username, realm, nonce, key }))
    const code2 = errCodeOf(r2.attrs[0x0009])
    if (code2 !== 0) {
      const unknown = r2.attrs[0x000a]
      const list = unknown ? Array.from({ length: unknown.length / 2 }, (_, i) => '0x' + unknown.readUInt16BE(i * 2).toString(16)).join(' ') : '(无列表)'
      throw new Error(`Allocate 失败: ${code2}（401=凭证错 / 437=分配错 / 420=完整性错）；服务器未知属性: ${list}`)
    }
    const relayed = xorAddr(r2.attrs[0x0016])
    const lifetime = r2.attrs[0x000d].readUInt32BE(0)
    console.log(`③ TURN 分配: PASS → relay 地址 ${relayed}（lifetime ${lifetime}s）`)
    console.log('TURN 互通验证：全部通过（契约 §5 + 02 §7 实测项）')
    process.exit(0)
  } catch (e) {
    console.error('FAIL:', e.message)
    process.exit(1)
  } finally {
    sock.close()
  }
}
