// Tunnel 状态机真 socket 测试（契约 §3.3/§3.4 核心红线）
// 覆盖：OPEN authority 断言、DATA 双向泵、FIN 半关闭不截断响应、WINDOW 增量语义、
//       终态迟到帧静默、收到 RST 不回、重复/无效 OPEN 忽略、超限 OPEN → RST（白名单①）。
import test from 'node:test'
import assert from 'node:assert/strict'
import net from 'node:net'
import { once } from 'node:events'
import { Tunnel, encodeFrame, decodeFrame, TYPE, AUTHORITY, MAX_PAYLOAD } from '../lib/tunnel.js'

/** 内存 DataChannel：直接把 send() 的帧喂给对端 onFrame */
function makeChannelPair(log = () => {}) {
  const a = { peer: null, bufferedAmount: 0, sent: [], onmessage: null }
  const b = { peer: null, bufferedAmount: 0, sent: [], onmessage: null }
  a.peer = b; b.peer = a
  for (const ch of [a, b]) {
    ch.send = (buf) => { ch.sent.push(Buffer.from(buf)); ch.peer.onmessage?.({ data: Buffer.from(buf) }) }
  }
  return [a, b]
}

async function startEchoServer() {
  const server = net.createServer((s) => { s.on('data', (d) => s.write(d)); s.on('error', () => {}) })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  return { server, port: server.address().port }
}

function makeTunnel(t, chData, chCtl, forwardTarget, log = () => {}) {
  const sentRst = []
  const tunnel = new Tunnel({
    forwardTarget,
    log,
    onDead: () => {},
  })
  // 拦截 _sendCtl 记录 RST
  const origSendCtl = tunnel._sendCtl.bind(tunnel)
  tunnel._sendCtl = (buf) => {
    const f = decodeFrame(buf)
    if (f.type === TYPE.RST) sentRst.push({ streamId: f.streamId, reason: f.payload.toString() })
    origSendCtl(buf)
  }
  tunnel.attach(chData, chCtl)
  tunnel.sentRst = sentRst
  return tunnel
}

test('Tunnel: OPEN → connect → DATA 双向泵 → FIN 半关闭不截断', async (t) => {
  const { server, port } = await startEchoServer()
  t.after(() => server.close())
  const [phoneData, plugData] = makeChannelPair()
  const [phoneCtl, plugCtl] = makeChannelPair()
  const tunnel = makeTunnel(t, plugData, plugCtl, `127.0.0.1:${port}`)

  // 手机侧：OPEN
  plugData.onmessage = (ev) => tunnel.onFrame(ev.data)
  plugCtl.onmessage = (ev) => tunnel.onFrame(ev.data) // ctl 入站（PING/RST/WINDOW 处理）
  const phoneReceived = []
  phoneData.onmessage = (ev) => phoneReceived.push(Buffer.from(ev.data))
  const phoneCtlReceived = []
  phoneCtl.onmessage = (ev) => phoneCtlReceived.push(Buffer.from(ev.data)) // WINDOW 走 ctl（§3.2）
  const body = Buffer.alloc(70 * 1024, 0x61) // 70KiB > 64KiB 阈值 → 应触发 WINDOW（增量语义）
  phoneData.send(encodeFrame(TYPE.OPEN, 1, Buffer.from(JSON.stringify({ authority: AUTHORITY }))))
  await new Promise((r) => setTimeout(r, 120))
  for (let off = 0; off < body.length; off += MAX_PAYLOAD) { // 手机侧按 ≤16373 切帧（§3.4.4）
    phoneData.send(encodeFrame(TYPE.DATA, 1, body.subarray(off, Math.min(off + MAX_PAYLOAD, body.length))))
  }
  await new Promise((r) => setTimeout(r, 300))
  // echo 回来
  const dataFrames = phoneReceived.filter((b) => b[1] === TYPE.DATA)
  assert.equal(Buffer.concat(dataFrames.map((b) => b.subarray(11))).toString().length, body.length, 'HTTP 请求经隧道回声完整')
  // WINDOW（增量语义）：echo 写入了 ≥64KiB
  await new Promise((r) => setTimeout(r, 100))
  const winFrames = phoneCtlReceived.filter((b) => b[1] === TYPE.WINDOW)
  assert.ok(winFrames.length >= 1, '写入 ≥64KiB 后必须发 WINDOW')
  if (winFrames.length >= 1) {
    const delta = winFrames[0].readUInt32BE(11)
    assert.ok(delta >= 64 * 1024, `WINDOW.credit 是增量（实测 ${delta}），非固定值`)
  }
  phoneData.send(encodeFrame(TYPE.FIN, 1)) // 手机请求半关闭
  await new Promise((r) => setTimeout(r, 150))
  assert.equal(tunnel.sentRst.length, 0)
  tunnel.detach()
})

test('Tunnel: OPEN authority 断言（≠契约固定值 → 静默忽略计错）', async (t) => {
  const { server, port } = await startEchoServer()
  t.after(() => server.close())
  const [phoneData, plugData] = makeChannelPair()
  const [, plugCtl] = makeChannelPair()
  const tunnel = makeTunnel(t, plugData, plugCtl, `127.0.0.1:${port}`)
  plugData.onmessage = (ev) => tunnel.onFrame(ev.data)
  phoneData.send(encodeFrame(TYPE.OPEN, 1, Buffer.from(JSON.stringify({ authority: '127.0.0.1:9999' }))))
  await new Promise((r) => setTimeout(r, 100))
  assert.equal(tunnel.streams.size, 0, 'authority 断言失败 → 不建流')
  assert.equal(tunnel.sentRst.length, 0, '不是白名单 RST')
  assert.ok(tunnel.errors >= 1)
  tunnel.detach()
})

test('Tunnel: 重复/无效 OPEN 静默忽略（v1.0.5，先于白名单①）', async (t) => {
  const { server, port } = await startEchoServer()
  t.after(() => server.close())
  const [phoneData, plugData] = makeChannelPair()
  const [, plugCtl] = makeChannelPair()
  const tunnel = makeTunnel(t, plugData, plugCtl, `127.0.0.1:${port}`)
  plugData.onmessage = (ev) => tunnel.onFrame(ev.data)
  const open = (id) => encodeFrame(TYPE.OPEN, id, Buffer.from(JSON.stringify({ authority: AUTHORITY })))
  phoneData.send(open(1))
  await new Promise((r) => setTimeout(r, 80))
  phoneData.send(open(1)) // 重复（活跃流）
  phoneData.send(open(0)) // 无效 id=0
  await new Promise((r) => setTimeout(r, 100))
  assert.equal(tunnel.streams.size, 1)
  assert.equal(tunnel.sentRst.length, 0, '重复/无效 OPEN 不回 RST（防误杀既有流）')
  assert.ok(tunnel.errors >= 2)
  tunnel.detach()
})

test('Tunnel: 超限新 OPEN → RST（白名单①）', async (t) => {
  const { server, port } = await startEchoServer()
  t.after(() => server.close())
  const [phoneData, plugData] = makeChannelPair()
  const [, plugCtl] = makeChannelPair()
  const tunnel = makeTunnel(t, plugData, plugCtl, `127.0.0.1:${port}`)
  plugData.onmessage = (ev) => tunnel.onFrame(ev.data)
  const open = (id) => encodeFrame(TYPE.OPEN, id, Buffer.from(JSON.stringify({ authority: AUTHORITY })))
  for (let i = 1; i <= 128; i++) phoneData.send(open(i)) // 塞满 128 并发上限
  phoneData.send(open(129)) // 超限 → RST
  await new Promise((r) => setTimeout(r, 300))
  assert.equal(tunnel.sentRst.filter((r) => r.streamId === 129).length, 1, '第 129 条 OPEN 收到 RST')
  assert.equal(tunnel.sentRst.filter((r) => r.streamId <= 128).length, 0, '既有流不被误杀')
  tunnel.detach()
})

test('Tunnel: PING → PONG 回显（stream_id=0，走 ctl）；终态迟到 DATA 静默', async (t) => {
  const { server, port } = await startEchoServer()
  t.after(() => server.close())
  const [phoneData, plugData] = makeChannelPair()
  const [phoneCtl, plugCtl] = makeChannelPair()
  const tunnel = makeTunnel(t, plugData, plugCtl, `127.0.0.1:${port}`)
  plugData.onmessage = (ev) => tunnel.onFrame(ev.data)
  plugCtl.onmessage = (ev) => tunnel.onFrame(ev.data)
  const ctlReceived = []
  phoneCtl.onmessage = (ev) => ctlReceived.push(Buffer.from(ev.data))
  const ping8 = Buffer.from('0011223344556677', 'hex')
  phoneCtl.send(encodeFrame(TYPE.PING, 0, ping8))
  await new Promise((r) => setTimeout(r, 60))
  const pong = ctlReceived.find((b) => b[1] === TYPE.PONG)
  assert.ok(pong, 'PONG 应答')
  assert.equal(pong.readUInt32BE(3), 0, 'PONG stream_id=0')
  assert.ok(pong.subarray(11).equals(ping8), '回显随机数')
  // 终态流迟到 DATA：RST 后再来 DATA → 不回 RST（防风暴）
  phoneData.send(encodeFrame(TYPE.OPEN, 7, Buffer.from(JSON.stringify({ authority: AUTHORITY }))))
  await new Promise((r) => setTimeout(r, 80))
  phoneCtl.send(encodeFrame(TYPE.RST, 7, Buffer.from('test')))
  await new Promise((r) => setTimeout(r, 60))
  phoneData.send(encodeFrame(TYPE.DATA, 7, Buffer.from('late frame')))
  await new Promise((r) => setTimeout(r, 60))
  assert.equal(tunnel.sentRst.filter((r) => r.streamId === 7).length, 0, '收到 RST 与终态迟到帧均不回 RST（防风暴）')
  tunnel.detach()
})
