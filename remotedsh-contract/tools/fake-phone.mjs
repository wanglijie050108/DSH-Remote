#!/usr/bin/env node
// fake-phone —— 手机角色的参考客户端（03 的可执行规格，集成测试用）
// 用法：
//   node tools/fake-phone.mjs scan --qr "dshlink://pair?..." [--proxy 13080] [--name p1]
//   node tools/fake-phone.mjs resume [--name p1]            # 免扫码重连（用持久化配对信息）
//   node tools/fake-phone.mjs bye  [--name p1]              # 主动解除（等 bye.ok，超时 2s）
// 行为覆盖 03 §3.3 的存储清单、pin 红线、凭证路径、心跳义务与错误文案矩阵。
import { WebSocket } from 'ws'
import { RTCPeerConnection } from 'werift'
import net from 'node:net'
import { readFileSync, writeFileSync, existsSync } from 'node:fs'
import { generateKeyPairSync } from 'node:crypto'
import { buildHello, PROTO_VER } from '../js/hello.mjs'
import { parsePairQr } from '../js/qr-pair.mjs'
import { verifyPin } from '../js/fingerprint.mjs'
import { TunnelEndpoint } from './lib/tunnel-pump.mjs'

const args = process.argv.slice(2)
const cmd = args[0]
const argOf = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d }
const NAME = argOf('name', 'p1')
const STATE_FILE = argOf('state', `.fake-phone-${NAME}.json`)
const KEY_FILE = argOf('key', `.fake-phone-${NAME}-key.json`)
const PROXY_PORT = argOf('proxy', '13080')

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), `[${NAME}]`, ...a)
process.on('unhandledRejection', (e) => { log('UNHANDLED REJECTION:', e?.stack || e); })

// ---- 设备身份（测试密钥；App 用 Keystore，此处落盘仅为本工具） ----
function loadKey() {
  if (existsSync(KEY_FILE)) return JSON.parse(readFileSync(KEY_FILE, 'utf8')).pkcs8Pem
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
  const pkcs8Pem = privateKey.export({ format: 'pem', type: 'pkcs8' }).toString()
  writeFileSync(KEY_FILE, JSON.stringify({ pkcs8Pem }))
  return pkcs8Pem
}
const PRIV_PEM = loadKey()

// ---- 配对持久化（03 §3.3 存储清单：sigURL/authority/fp/agentId/TURN 凭证+到期） ----
function loadState() { return existsSync(STATE_FILE) ? JSON.parse(readFileSync(STATE_FILE, 'utf8')) : null }
function saveState(s) { writeFileSync(STATE_FILE, JSON.stringify(s, null, 2)) }
function clearState() { try { writeFileSync(STATE_FILE, '{}') } catch {} }

let state = loadState()
let ws, endpoint, tunnelReady = false, punchRetryTimer = null, offerInFlight = false, lastOfferAt = 0
let pendingResolvePunch = null
const turnCreds = () => (state?.turn && state.turn.expireAt > Date.now() + 300_000 ? state.turn : null) // TTL<300s 视为无效（契约 §5）

function connectSignal({ onHelloOk }) {
  const sigURL = state?.sigURL || argOf('sig')
  if (!sigURL) { console.error('no signal url (scan QR first or pass --sig)'); process.exit(1) }
  ws = new WebSocket(sigURL.replace(/^http/, 'ws'))
  ws.on('open', () => {
    ws.send(JSON.stringify(buildHello({ role: 'app', privateKeyPem: PRIV_PEM })))
  })
  ws.on('message', async (raw) => {
    const msg = JSON.parse(raw.toString())
    switch (msg.t) {
      case 'hello.ok':
        log('hello.ok pair=', msg.pair ? msg.pair.pair_id : null, 'peer_online=', msg.peer_online)
        onHelloOk?.(msg)
        return
      case 'pair.ok': {
        log('pair.ok →', msg.pair_id)
        state = { ...(state || {}), sigURL, authority: state?.authority || '127.0.0.1:13080', fp: state?.fp, agentId: msg.agent_id, pairId: msg.pair_id, turn: { ...msg.turn, expireAt: Date.now() + msg.turn.ttl * 1000 } }
        saveState(state)
        await ensureTurnAndPunch()
        return
      }
      case 'punch.offer': {
        await handleOffer(msg)
        return
      }
      case 'presence':
        log('presence peer_online=', msg.peer_online)
        if (msg.peer_online && !tunnelReady) await ensureTurnAndPunch() // PEER_OFFLINE 恢复后自动重试（03 §3.3）
        return
      case 'relay.alloc':
        state.turn = { ...msg.turn, expireAt: Date.now() + msg.turn.ttl * 1000 }
        saveState(state)
        pendingResolvePunch?.(); pendingResolvePunch = null
        return
      case 'bye':
        log('对端已主动解除配对，请重新扫码（NEED_PAIR + 拆本地隧道）')
        teardownTunnel(); clearState(); state = null
        return
      case 'pong': return
      case 'error': return handleError(msg)
      default: log('unknown t:', msg.t); return
    }
  })
  ws.on('close', () => { log('signal closed'); ws = null; tunnelReady = false })
  ws.on('error', (e) => log('signal error:', e.message))
  // 心跳义务：每 25s 发 ping（契约 §4；03 §3.3）
  clearInterval(heartbeat)
  heartbeat = setInterval(() => { if (ws) ws.send(JSON.stringify({ t: 'ping' })) }, 25_000)
  heartbeat.unref?.()
}
let heartbeat = null

function handleError(msg) {
  // 03 §3.3 文案矩阵（不静默失败）
  switch (msg.code) {
    case 'PEER_OFFLINE':
      log('PEER_OFFLINE：保持连接，等 presence 恢复后自动重试 punch.request')
      return
    case 'PAIR_NOT_FOUND': log('请重新扫码（NEED_PAIR + 拆本地隧道）'); teardownTunnel(); clearState(); state = null; return
    case 'AGENT_RESTARTED': log('电脑上的 DSH 已重启，请重新扫码（NEED_PAIR + 拆本地隧道）'); teardownTunnel(); clearState(); state = null; return
    case 'PAIR_EXPIRED': log('PC 离线超过 24 小时，配对已失效，请重新扫码（NEED_PAIR + 拆本地隧道）'); teardownTunnel(); clearState(); state = null; return
    case 'PAIR_REPLACED':
      // §4.5 v1.0.5：主动换绑方 MUST 忽略；被动方清配对。fake-phone 的换绑由再 scan 完成 → 这里视为被动方
      log('已在另一台手机完成配对（被动方 → 清配对 + 拆隧道）')
      teardownTunnel(); clearState(); state = null; return
    case 'PROTO_VER_UNSUPPORTED': log(`版本过旧（expect ${PROTO_VER}），请升级 App。不重试、不提示重新扫码`); process.exit(2); return
    case 'PAIR_LIMIT': log('服务繁忙，不自动重试'); return
    case 'RATE_LIMITED': case 'INTERNAL': log(msg.code, '→ 指数退避'); return
    default: log('error:', msg.code, msg.msg); return
  }
}

function send(obj) { if (ws) ws.send(JSON.stringify(obj)) }

async function ensureTurnAndPunch() {
  if (!state?.pairId && !state?.fp) { log('no pairing info; nothing to punch'); return }
  if (!turnCreds()) {
    log('no valid TURN creds (TTL<300s) → relay.request（任何新 gather 前必做，契约 §5）')
    send({ t: 'relay.request' })
    await new Promise(r => { pendingResolvePunch = r; setTimeout(r, 3000) })
  }
  send({ t: 'punch.request', pair_id: state.pairId })
  log('punch.request sent')
}

async function handleOffer(msg) {
  // 03 §3.3：App SHOULD 忽略更短窗口内的重复 offer；应答在途时幂等替换仅允许在旧 offer 明显失效（>6s）后进行
  const now = Date.now()
  if (offerInFlight && now - lastOfferAt < 6000) { log('duplicate offer in flight window → ignore'); return }
  lastOfferAt = now
  offerInFlight = true
  teardownTunnel(false)
  const lines = msg.sdp.split(/\r?\n/)
  // ★ pin 红线：每一次 setRemoteDescription 之前执行（03 §3.1；§6.1 fail-closed）
  if (!verifyPin(state?.fp, lines)) {
    log('PIN FAIL: 对端身份校验失败 → 中止（MUST NOT setRemoteDescription）')
    offerInFlight = false
    return
  }
  log('pin ok（与持久化 fp 逐字节一致）')
  const pc = new RTCPeerConnection({
    iceServers: (state.turn?.uris || []).map(u => ({ urls: u })), // 单阶段 ICE：首次 gather 即含 relay
  })
  pc.connectionStateChange.subscribe(s => {
    log('rtc conn:', s)
    if (s === 'disconnected' || s === 'failed') { log('ICE 主触发 → 重建（§3.5）'); tunnelReady = false; ensureTurnAndPunch().catch(() => {}) }
    if (s === 'connected') log('ice connected（endpoint 就绪后隧道才算 READY）')
  })
  let pendingDataResolve, pendingCtlResolve
  const gotData = new Promise(r => { pendingDataResolve = r })
  const gotCtl = new Promise(r => { pendingCtlResolve = r })
  pc.ondatachannel = ev => {
    const c = ev.channel
    log('onDataChannel:', c.label)
    if (c.label === 'data') pendingDataResolve?.(c)
    else if (c.label === 'ctl') pendingCtlResolve?.(c)
    else log('unknown channel label → 协议错误，断开（§3 通道识别）')
  }
  await pc.setRemoteDescription({ type: 'offer', sdp: msg.sdp })
  const answer = await pc.createAnswer()
  await pc.setLocalDescription(answer)
  send({ t: 'punch.answer', pair_id: state.pairId, sdp: pc.localDescription.sdp })
  const [dataCh, ctlCh] = await Promise.all([gotData, gotCtl])
  log('both DataChannels received via onDataChannel (label 识别；手机 MUST NOT createDataChannel)')
  endpoint?.close()
  endpoint = new TunnelEndpoint({ mode: 'initiator', log, onDead: () => { tunnelReady = false; ensureTurnAndPunch().catch(() => {}) } })
  endpoint.bindChannels(dataCh, ctlCh)
  tunnelReady = true // endpoint 就绪后才算 READY（消除 TUNNEL READY 日志与 endpoint 赋值间的竞态窗口）
  log('TUNNEL READY (P2P or TURN)')
  offerInFlight = false
  startProxy()
}

// ---- 本地代理（03 §3.2）：固定 authority，仅 loopback；隧道未就绪立即 close，不排队 ----
let server
function startProxy() {
  if (PROXY_PORT === 'off') return
  if (server) return
  server = net.createServer((socket) => {
    if (!socket.remoteAddress || !net.isIPv4(socket.remoteAddress) || !isLoopback(socket.remoteAddress)) { socket.destroy(); return }
    if (!tunnelReady || !endpoint) { socket.destroy(); return } // 立即 close，不排队不缓冲
    const id = endpoint.openStream(socket)
    if (id == null) { socket.destroy(); return }
    socket.on('close', () => endpoint?.finalize(id))
  })
  server.on('error', (e) => { if (e.code === 'EADDRINUSE') { console.error(`本地端口 ${PROXY_PORT} 被占用，请关闭占用它的应用并重试（不做端口回退，03 §3.2）`); process.exit(3) } })
  server.listen(Number(PROXY_PORT), '127.0.0.1', () => log(`local proxy on 127.0.0.1:${PROXY_PORT} (authority 固定，Host=127.0.0.1:13080)`))
}
const isLoopback = (ip) => ip === '127.0.0.1' || ip === '::1' || ip?.startsWith('127.')

function teardownTunnel(destroyServer = true) {
  endpoint?.close(); endpoint = null; tunnelReady = false
  if (destroyServer && server) { server.close(); server = null }
}

// ---- 命令 ----
if (cmd === 'scan') {
  const qr = parsePairQr(argOf('qr'))
  if (!qr || qr.error) { console.error('bad QR:', qr); process.exit(1) }
  log('QR parsed: sig=', qr.s, 'a=', qr.a, 't?', !!qr.t)
  state = { sigURL: qr.s, authority: qr.a, fp: qr.fp, turn: state?.turn } // 先拆旧隧道（主动换绑先拆后绑，03 §3.3）
  teardownTunnel()
  saveState(state)
  connectSignal({
    onHelloOk: (msg) => {
      if (msg.pair) { log('already paired (resume)'); ensureTurnAndPunch() }
      else { log('pair.bind →'); send({ t: 'pair.bind', ptok: qr.pt }) }
    },
  })
  startProxy()
} else if (cmd === 'resume') {
  if (!state?.fp) { console.error('no pairing info — scan first'); process.exit(1) }
  connectSignal({ onHelloOk: (msg) => { if (msg.pair) ensureTurnAndPunch(); else log('pair null → NEED_PAIR（请重新扫码）') } })
  startProxy()
} else if (cmd === 'bye') {
  if (!state) { console.error('nothing to unpair'); process.exit(0) }
  connectSignal({
    onHelloOk: async (msg) => {
      if (!msg.pair) { log('server has no pair; clearing local'); clearState(); process.exit(0) }
      send({ t: 'bye', reason: 'user' })
      const t0 = Date.now()
      const onByeOk = (raw) => { const m = JSON.parse(raw.toString()); if (m.t === 'bye.ok') { log(`bye.ok in ${Date.now() - t0}ms → 清本地 → IDLE`); teardownTunnel(); clearState(); process.exit(0) } }
      ws.on('message', onByeOk)
      setTimeout(() => { log('bye.ok timeout (2s) → 仍拆本地'); teardownTunnel(); clearState(); process.exit(0) }, 2000)
    },
  })
} else {
  console.error('usage: fake-phone.mjs scan|resume|bye ...')
  process.exit(1)
}
