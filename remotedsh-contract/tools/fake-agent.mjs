#!/usr/bin/env node
// fake-agent —— 插件角色的参考客户端（01 的可执行规格，集成测试用）
// 用法：
//   node tools/fake-agent.mjs --sig wss://127.0.0.1:8080/v1/signal [--forward 127.0.0.1:3080] [--name a1] [--port 8081]
//   连接到 fake-bridge；打印 QR（dshlink://）；等 pair.ok / punch.request → 发 offer → 建隧道。
import { WebSocket, WebSocketServer } from 'ws'
import { RTCPeerConnection, RTCCertificate, SignatureAlgorithm, HashAlgorithm } from 'werift'
import peculiar from '@peculiar/x509'
import net from 'node:net'
import { webcrypto, createHash, randomBytes } from 'node:crypto'
import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { buildHello, PROTO_VER } from '../js/hello.mjs'
import { createPublicKey } from 'node:crypto'
import { TunnelEndpoint } from './lib/tunnel-pump.mjs'

const args = process.argv.slice(2)
const argOf = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d }
const NAME = argOf('name', 'a1')
const SIG_URL = argOf('sig', 'ws://127.0.0.1:8080/v1/signal')
const FORWARD = argOf('forward', '127.0.0.1:3080')
const KEY_FILE = `.fake-agent-${NAME}-key.json`
const HTTP_PORT = Number(argOf('port', 0)) // 顺手开一个 HTTP 端点，用浏览器扫 QR

const log = (...a) => console.log(new Date().toISOString().slice(11, 19), `[${NAME}]`, ...a)

// ★ W1 实测：RTCCertificate 第三参必须为 {hash,signature} 枚举对象（见 scripts/poc-werift-loopback.mjs）
const SIGNATURE_HASH = { hash: HashAlgorithm.sha256_4, signature: SignatureAlgorithm.ecdsa_3 }

async function loadIdentity() {
  if (existsSync(KEY_FILE)) return JSON.parse(readFileSync(KEY_FILE, 'utf8'))
  const alg = { name: 'ECDSA', namedCurve: 'P-256', hash: 'SHA-256' }
  const kp = await webcrypto.subtle.generateKey(alg, true, ['sign', 'verify'])
  const cert = await peculiar.X509CertificateGenerator.createSelfSigned({
    serialNumber: '01', name: 'CN=dsh-mobile-link-fake',
    validity: { notBefore: new Date(Date.now() - 86400000), notAfter: new Date(Date.now() + 365 * 86400000 * 10) },
    keys: kp, signingAlgorithm: alg,
  })
  const pkcs8 = await webcrypto.subtle.exportKey('pkcs8', kp.privateKey)
  const id = {
    privPem: '-----BEGIN PRIVATE KEY-----\n' + Buffer.from(pkcs8).toString('base64').replace(/(.{64})/g, '$1\n') + '\n-----END PRIVATE KEY-----',
    certPem: cert.toString('pem'),
  }
  writeFileSync(KEY_FILE, JSON.stringify(id)) // 整证书持久化（§6：不重新派生，指纹全生命周期稳定）
  return id
}

const bootId = `boot-${process.pid}-${Date.now()}` // 进程级（§2.3）；真实插件用 globalThis 防 hot-reload
const id = await loadIdentity()
const rtcCert = new RTCCertificate(id.privPem, id.certPem, SIGNATURE_HASH)
const FP = rtcCert.getFingerprints().find(f => f.algorithm === 'sha-256')?.value
const PRIV = (await import('node:crypto')).createPrivateKey(id.privPem)
const PUB_B64U = createPublicKey(PRIV).export({ format: 'der', type: 'spki' }).toString('base64url')

let ws, pairId = null, ptok = null, pc = null, endpoint = null, iceServers = []
let lastSpontaneousOffer = 0

function connect() {
  ws = new WebSocket(SIG_URL)
  ws.on('open', () => {
    log('signal open → hello(agent, boot_id=' + bootId.slice(0, 12) + '…)')
    ws.send(JSON.stringify(buildHello({ role: 'agent', privateKeyPem: id.privPem, bootId })))
  })
  ws.on('message', (raw) => onMessage(JSON.parse(raw.toString())).catch(e => log('handler error:', e.message)))
  ws.on('close', () => { log('signal closed → 退避重连（不发 bye；pair 靠 boot_id 保留）'); setTimeout(connect, 1000) })
  ws.on('error', () => {})
  // 心跳义务：每 25s 发 ping（契约 §4；缺失会被 60s sweeper 判离线）
  if (heartbeat) clearInterval(heartbeat)
  heartbeat = setInterval(() => send({ t: 'ping' }), 25_000)
  heartbeat.unref?.()
}
let heartbeat = null
const send = (o) => ws?.send(JSON.stringify(o))

async function onMessage(msg) {
  switch (msg.t) {
    case 'hello.ok':
      if (msg.pair) { pairId = msg.pair.pair_id; log('hello.ok 免扫码恢复 pair', pairId, '→ 主动重发 offer（§3.5 规则1）'); ensureCredsThenOffer() }
      else {
        log('hello.ok 无 pair → pair.ready 注册 token（只在 hello.ok{pair:null} 后发，§4.4）')
        ptok = randomBytes(32).toString('base64url')
        send({ t: 'pair.ready', ptok_hash: createHash('sha256').update(ptok).digest('base64url'), ttl: 300 })
      }
      return
    case 'pair.ready.ok':
      await printQr() // ★ 必须等 pair.ready.ok 才出 QR（§4.1）
      return
    case 'pair.ok':
      pairId = msg.pair_id
      iceServers = msg.turn.uris.map(u => ({ urls: u }))
      log('pair.ok →', pairId, '（TURN 凭证已收；QR 作废不重印）')
      return
    case 'punch.request':
      log('punch.request → 受请求触发的 offer（不受 2s 窗口约束）')
      await makeOffer({ requested: true })
      return
    case 'punch.answer':
      log('punch.answer → setRemoteDescription')
      await pc?.setRemoteDescription({ type: 'answer', sdp: msg.sdp })
      return
    case 'relay.alloc':
      iceServers = msg.turn.uris.map(u => ({ urls: u }))
      log('relay.alloc → 凭证就绪，继续 gather')
      pendingAllocResolve?.(); pendingAllocResolve = null
      return
    case 'presence':
      log('presence peer_online=', msg.peer_online) // 仅记日志（A5：自发重发暂停机制暂不做）
      return
    case 'bye':
      log('对端 bye → 拆隧道 → 恢复未配对 → 恢复 QR 轮印（§4.4）')
      teardownRtc(); pairId = null
      ptok = randomBytes(32).toString('base64url')
      send({ t: 'pair.ready', ptok_hash: createHash('sha256').update(ptok).digest('base64url'), ttl: 300 })
      return
    case 'bye.ok':
      log('bye.ok')
      return
    case 'error':
      if (msg.code === 'PAIR_REPLACED') { log('PAIR_REPLACED → 拆隧道 → 恢复未配对 → 恢复 QR 轮印（E10⑦）'); teardownRtc(); pairId = null; ptok = randomBytes(32).toString('base64url'); send({ t: 'pair.ready', ptok_hash: createHash('sha256').update(ptok).digest('base64url'), ttl: 300 }) }
      else if (msg.code === 'PAIR_NOT_FOUND') { log('PAIR_NOT_FOUND（过期 offer）→ 拆隧道 → 恢复未配对'); teardownRtc(); pairId = null }
      else if (msg.code === 'PROTO_VER_UNSUPPORTED') { log(`版本过旧（expect ${PROTO_VER}）→ 明确报错退出装配（不重试）`); process.exit(2) }
      else log('error:', msg.code, msg.msg)
      return
    case 'pong': return
    default: log('unknown t:', msg.t)
  }
}
let pendingAllocResolve = null

async function ensureCredsThenOffer() {
  if (!iceServers.length) { send({ t: 'relay.request' }); await new Promise(r => { pendingAllocResolve = r; setTimeout(r, 3000) }) }
  await makeOffer({ requested: false }) // 免扫码恢复 → 主动重发（§3.5；自发窗口约束见 makeOffer）
}

async function makeOffer({ requested }) {
  // 握手在途时不自发重建（requested 的 offer 例外——对端明确要一次新 offer）
  if (!requested && pc && ['new', 'connecting'].includes(pc.connectionState)) { log('offer in flight → skip spontaneous rebuild'); return }
  if (!requested && Date.now() - lastSpontaneousOffer < 2000) { log('spontaneous offer < 2s window → skip'); return }
  lastSpontaneousOffer = Date.now()
  teardownRtc(false)
  pc = new RTCPeerConnection({ certificates: [rtcCert], iceServers }) // offer 方创建两条 DataChannel（§3）
  const dataCh = pc.createDataChannel('data', { ordered: true })   // OPEN/DATA/FIN
  const ctlCh = pc.createDataChannel('ctl', { ordered: false })    // PING/PONG/WINDOW/RST
  endpoint = new TunnelEndpoint({
    mode: 'acceptor', log,
    connectFactory: () => { // 到 DSH 的转发目标：127.0.0.1 + webServer.port（此处 fake 用 --forward）
      const [host, port] = FORWARD.split(':')
      const s = net.connect(Number(port), host)
      s.on('error', () => {})
      return s
    },
    onDead: () => { log('tunnel dead → 重建（发新 offer；stream_id 从 1 重启）'); teardownRtc(); makeOffer({ requested: false }) },
  })
  dataCh.onopen = () => { log('data channel open'); endpoint.bindChannels(dataCh, ctlCh) }
  pc.connectionStateChange.subscribe(s => {
    if (s === 'failed' || s === 'disconnected') log('rtc:', s, '→ 主触发重建')
    if (s === 'connected') endpoint && (endpoint.lastFrameAt = Date.now()) // ICE 建立耗时计入 15s 兜底
  })
  const offer = await pc.createOffer()
  await pc.setLocalDescription(offer) // 非 trickle：gather 完成后 SDP 已含候选（PoC 已验证）
  log('offer ready（candidates:', (pc.localDescription.sdp.match(/a=candidate:/g) || []).length, '）→ punch.offer')
  send({ t: 'punch.offer', pair_id: pairId, sdp: pc.localDescription.sdp })
}

function teardownRtc(closeEndpoint = true) {
  if (closeEndpoint) endpoint?.close()
  endpoint = null
  try { pc?.close() } catch {}
  pc = null
}

async function printQr() {
  const uri = `dshlink://pair?v=1&s=${encodeURIComponent(SIG_URL)}&pt=${ptok}&fp=${encodeURIComponent(FP)}&a=${encodeURIComponent('127.0.0.1:13080')}`
  log('QR READY（ptok 已注册，pair.ready.ok 已收）:')
  console.log('  ' + uri)
  const { default: qrcode } = await import('qrcode').catch(() => ({ default: null }))
  if (qrcode) {
    try { console.log(await qrcode.toString(uri, { type: 'terminal', small: true })) } catch {}
  }
}

// 优雅退出：进程退出路径发 bye（尽力而为，01 §2.2）
let byeSent = false
process.on('SIGINT', () => {
  if (!byeSent && pairId && ws) { byeSent = true; log('SIGINT → bye{shutdown} → 等 bye.ok（≤2s）→ exit'); send({ t: 'bye', reason: 'shutdown' }); setTimeout(() => process.exit(0), 2000) }
  else process.exit(0)
})
connect()
log(`fake-agent up. forward=${FORWARD} fp=${FP?.slice(0, 20)}…`)
