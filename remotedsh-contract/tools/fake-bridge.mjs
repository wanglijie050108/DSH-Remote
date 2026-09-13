#!/usr/bin/env node
// fake-bridge —— 契约 §4 信令服务的参考实现（presence-only）
// 同时是 Go 版 Bridge（remotedsh-bridge）的行为规格：所有分支按契约 §4.1–§4.5 / 02 §2.1–§3.3 实现。
// 用法：node tools/fake-bridge.mjs --port 8080 [--secret test-secret] [--pair-limit 256]
import { WebSocketServer } from 'ws'
import { createHash, createHmac, createPublicKey } from 'node:crypto'
import { verifyHello, PROTO_VER } from '../js/hello.mjs'

const args = process.argv.slice(2)
const argOf = (k, d) => { const i = args.indexOf(`--${k}`); return i >= 0 ? args[i + 1] : d }
const PORT = Number(argOf('port', 8080))
const TURN_SECRET = argOf('secret', process.env.TURN_SECRET || 'fake-bridge-secret')
const PAIR_LIMIT = Number(argOf('pair-limit', 256))
const GRACE_MS = 24 * 3600 * 1000 // T = 24h（契约 §4.3，用户 2026-09-12 决策）
const NONCE_WINDOW_MS = 130_000 // §4.1：去重窗口 MUST ≥ 120s（验签窗 ±60s + 余量）
const TS_WINDOW_S = 60
const MAX_FRAME = 64 * 1024
const HELLO_DEADLINE_MS = 10_000
const MSG_RATE = 20 // msg/s/conn（02 §3.3）

const log = (...a) => console.log(new Date().toISOString(), '[fake-bridge]', ...a)

// ---------- 注册表（02 §2：全部内存态） ----------
const agents = new Map()   // agent_id → conn
const phones = new Map()   // phone_id → conn
const pairs = new Map()    // pair_id → {pair_id, agent_id, agent_boot_id, phone_id, createdAt, graceTimer}
const ptok = new Map()     // ptok_hash → {agent_id, expire_at}
const phoneIndex = new Map() // phone_id → pair_id（免扫码重连）
const nonces = new Map()   // nonce → firstSeenAt（去重）
const ipFails = new Map()  // ip → {fails, lockedUntil}（pair_token 猜测防护）
const lastSeen = new WeakMap() // conn → {frames: n, lastAt, helloOk: bool}

let nextPairId = 1

// ---------- TURN（契约 §5） ----------
function allocTurn(pairId, ttl = 3600) {
  const now = Math.floor(Date.now() / 1000)
  const username = `${now + ttl}:${pairId}`
  const credential = createHmac('sha1', TURN_SECRET).update(username).digest('base64')
  return { uris: ['stun:127.0.0.1:3478', 'turn:127.0.0.1:3478?transport=udp', 'turn:127.0.0.1:3478?transport=tcp'], username, credential, ttl }
}

// ---------- 工具 ----------
function send(conn, obj) {
  if (conn.ws.readyState === conn.ws.OPEN) conn.ws.send(JSON.stringify(obj))
}
function errorTo(conn, code, msg) { send(conn, { t: 'error', code, msg }) }

/** pair 记录存 id 不存连接（契约 §4.3）；投递时解析当前连接 */
function toAgent(pair, obj) { const c = agents.get(pair.agent_id); if (c) send(c, obj); return !!c }
function toPhone(pair, obj) { const c = phones.get(pair.phone_id); if (c) send(c, obj); return !!c }

function broadcastPresence(pair, online) {
  // 推送给对端：agent 的 presence 描述手机在线；phone 的描述 agent 在线
  toPhone(pair, { t: 'presence', peer_online: online })
}

/** pair 销毁：五个触发条件（契约 §4.3）。除销毁本身外不做其他事。 */
function destroyPair(pair, reason) {
  if (pair.graceTimer) clearTimeout(pair.graceTimer)
  pairs.delete(pair.pair_id)
  if (phoneIndex.get(pair.phone_id) === pair.pair_id) phoneIndex.delete(pair.phone_id)
  // 销毁时清除该 agent 的 ptok（§4.4：销毁前生成的未过期 QR MUST 不可再绑定）
  for (const [h, rec] of ptok) if (rec.agent_id === pair.agent_id) ptok.delete(h)
  log(`pair ${pair.pair_id} destroyed: ${reason}`)
  return reason
}

function startGraceTimer(pair) {
  if (pair.graceTimer) clearTimeout(pair.graceTimer) // 每次断开重新起算（契约 §4.3）
  pair.graceTimer = setTimeout(() => {
    if (!pairs.has(pair.pair_id)) return
    destroyPair(pair, 'grace expired (T=24h)')
    toPhone(pair, { t: 'error', code: 'PAIR_EXPIRED', msg: 'PC 离线超过 24 小时，配对已失效，请重新扫码' }) // ②③ 主动推送
  }, GRACE_MS)
  pair.graceTimer.unref?.()
}

function agentOnline(pair) { return agents.has(pair.agent_id) }
function phoneOnline(pair) { return phones.has(pair.phone_id) }

// ---------- hello（契约 §4.2 门禁，02 §3.2 校验顺序） ----------
function verifyHelloMsg(conn, msg, ip) {
  if (msg.proto_ver !== PROTO_VER) return { code: 'PROTO_VER_UNSUPPORTED', msg: `expect ${PROTO_VER}` } // ① 版本门禁（不重试）
  if (typeof msg.ts !== 'number' || Math.abs(Date.now() / 1000 - msg.ts) > TS_WINDOW_S) return { code: 'AUTH_FAILED', msg: 'ts out of ±60s window' }
  if (nonces.has(msg.nonce)) return { code: 'AUTH_FAILED', msg: 'nonce replay' } // ③ 去重窗口 130s ≥ 120s
  nonces.set(msg.nonce, Date.now())
  try {
    const pub = createPublicKey({ key: Buffer.from(msg.pub, 'base64url'), format: 'der', type: 'spki' })
    const ok = verifyHello(pub, msg.ts, msg.nonce, msg.sig) // ④ 按规范化字节串验签（§4.2）
    if (!ok) return { code: 'AUTH_FAILED', msg: 'bad signature' }
    return { ok: true, pubDer: Buffer.from(msg.pub, 'base64url') }
  } catch { return { code: 'AUTH_FAILED', msg: 'bad pub/sig encoding' } }
}

// ---------- 连接处理 ----------
const wss = new WebSocketServer({ port: PORT, maxPayload: MAX_FRAME })
wss.on('connection', (ws, req) => {
  // 02 §5.1：XFF 取最右；仅在可信代理存在时采信。fake-bridge 无代理层 → 用 socket 地址
  const ip = req.socket.remoteAddress || 'unknown'
  const conn = { ws, ip, role: null, id: null, bootId: null, stale: false, gen: ++connGen }
  lastSeen.set(conn, { count: 0, lastAt: Date.now(), helloOk: false })

  const helloDeadline = setTimeout(() => {
    if (!lastSeen.get(conn)?.helloOk) { log(`conn from ${ip}: hello deadline (10s) → close`); ws.close() }
  }, HELLO_DEADLINE_MS)
  helloDeadline.unref?.()

  ws.on('message', (raw) => {
    const ls = lastSeen.get(conn)
    ls.lastAt = Date.now()
    if (++ls.count > MSG_RATE * 2) { errorTo(conn, 'RATE_LIMITED', 'too many messages'); return } // 粗粒度 2s 窗口
    if (raw.length > MAX_FRAME) { ws.close(1009, 'frame too large'); return }
    let msg
    try { msg = JSON.parse(raw.toString()) } catch { ws.close(1002, 'bad json'); return }
    if (!ls.helloOk) return handleHello(conn, msg)
    return dispatch(conn, msg)
  })
  ws.on('close', () => {
    clearTimeout(helloDeadline)
    onConnClose(conn)
  })
  ws.on('error', () => { try { ws.close() } catch {} })
})
let connGen = 0

function handleHello(conn, msg) {
  if (msg.t !== 'hello') { errorTo(conn, 'AUTH_FAILED', 'hello required'); conn.ws.close(); return }
  const r = verifyHelloMsg(conn, msg)
  if (!r.ok) {
    if (r.code === 'PROTO_VER_UNSUPPORTED') errorTo(conn, r.code, r.msg)
    else errorTo(conn, r.code, r.msg)
    conn.ws.close()
    return
  }
  lastSeen.get(conn).helloOk = true
  const id = createHash('sha256').update(r.pubDer).digest('base64url') // agent_id / phone_id
  conn.role = msg.role
  conn.id = id
  if (msg.role === 'agent') {
    if (!msg.boot_id) { errorTo(conn, 'AUTH_FAILED', 'agent MUST carry boot_id'); conn.ws.close(); return }
    // 同 id 重复上线 → 踢旧连接（02 §3.2；旧连接标记 stale，其 close 不触发销毁）
    const old = agents.get(id)
    if (old && old !== conn && !old.stale) { old.stale = true; try { old.ws.close(4000, 'kicked') } catch {} }
    agents.set(id, conn)
    conn.bootId = msg.boot_id

    // agent 侧 pair 判定（契约 §4.3 ②：同 agent_id、boot_id 不同 → 销毁 + 推 AGENT_RESTARTED）
    const pair = [...pairs.values()].find(p => p.agent_id === id)
    if (pair) {
      if (pair.agent_boot_id !== msg.boot_id) {
        const phone = phones.get(pair.phone_id)
        destroyPair(pair, 'boot_id changed (DSH restarted)')
        if (phone) errorTo(phone, 'AGENT_RESTARTED', '电脑上的 DSH 已重启，请重新扫码')
        send(conn, { t: 'hello.ok', pair: null, peer_online: false, ts: Date.now() })
        return
      }
      // 同 boot_id 重连：取消宽限计时器、挂载新 conn（免扫码）
      if (pair.graceTimer) { clearTimeout(pair.graceTimer); pair.graceTimer = null }
      send(conn, { t: 'hello.ok', pair: { pair_id: pair.pair_id, phone_id: pair.phone_id, agent_id: pair.agent_id }, peer_online: phoneOnline(pair), ts: Date.now() })
      return
    }
    send(conn, { t: 'hello.ok', pair: null, peer_online: false, ts: Date.now() })
  } else if (msg.role === 'app') {
    const old = phones.get(id)
    if (old && old !== conn && !old.stale) { old.stale = true; try { old.ws.close(4000, 'kicked') } catch {} }
    phones.set(id, conn)
    const pairId = phoneIndex.get(id)
    const pair = pairId ? pairs.get(pairId) : null
    send(conn, { t: 'hello.ok', pair: pair ? { pair_id: pair.pair_id, phone_id: pair.phone_id, agent_id: pair.agent_id } : null, peer_online: pair ? agentOnline(pair) : false, ts: Date.now() })
  } else {
    errorTo(conn, 'AUTH_FAILED', 'role must be agent|app'); conn.ws.close()
  }
  log(`hello ok: ${msg.role} ${id.slice(0, 8)}… from ${conn.ip}`)
}

function onConnClose(conn) {
  if (conn.stale) return // 被踢的旧连接：不做任何生命周期动作（02 §2.1 约束 1）
  if (conn.role === 'agent' && agents.get(conn.id) === conn) {
    agents.delete(conn.id)
    const pair = [...pairs.values()].find(p => p.agent_id === conn.id)
    if (pair) {
      startGraceTimer(pair) // 重新起算（契约 §4.3）
      broadcastPresence(pair, false)
    }
  } else if (conn.role === 'app' && phones.get(conn.id) === conn) {
    phones.delete(conn.id)
    const pairId = phoneIndex.get(conn.id)
    const pair = pairId ? pairs.get(pairId) : null
    if (pair) toAgent(pair, { t: 'presence', peer_online: false }) // 手机断开不销毁 pair
  }
}

// ---------- 消息分发（t 是封闭集合，契约 §4） ----------
function dispatch(conn, msg) {
  const t = msg.t
  switch (t) {
    case 'ping': send(conn, { t: 'pong' }); return
    case 'pong': return

    case 'pair.ready': {
      if (conn.role !== 'agent') return deny(conn)
      const hash = String(msg.ptok_hash || '') // §4.1：agent 侧已算好 sha256(ptok)→base64url，Bridge 只存 hash
      if (!/^[A-Za-z0-9_-]{43}$/.test(hash)) return errorTo(conn, 'AUTH_FAILED', 'bad ptok_hash') // sha256→base64url 恒 43 字符
      const ttl = Math.min(Number(msg.ttl) || 300, 300)
      // 同 agent 再次注册 → 作废旧 hash（§4.4）
      for (const [h, rec] of ptok) if (rec.agent_id === conn.id) ptok.delete(h)
      ptok.set(hash, { agent_id: conn.id, expire_at: Date.now() + ttl * 1000 })
      send(conn, { t: 'pair.ready.ok', ts: Date.now() })
      return
    }

    case 'pair.bind': {
      if (conn.role !== 'app') return deny(conn)
      const lock = ipFails.get(conn.ip)
      if (lock && lock.lockedUntil > Date.now()) return errorTo(conn, 'RATE_LIMITED', 'try later')
      const hash = createHash('sha256').update(String(msg.ptok)).digest('base64url')
      const rec = ptok.get(hash)
      const fail = () => {
        const l = ipFails.get(conn.ip) || { fails: 0, lockedUntil: 0 }
        if (++l.fails >= 5) { l.lockedUntil = Date.now() + 10 * 60_000; l.fails = 0 } // 02 §3.3
        ipFails.set(conn.ip, l)
        errorTo(conn, 'AUTH_FAILED', 'invalid pair token')
      }
      if (!rec || rec.expire_at < Date.now()) { ptok.delete(hash); return fail() }
      ptok.delete(hash) // 单次有效
      if (pairs.size >= PAIR_LIMIT) return errorTo(conn, 'PAIR_LIMIT', '服务繁忙') // ②⑤之外先查容量（02 §2.2）

      const agentPair = [...pairs.values()].find(p => p.agent_id === rec.agent_id)
      if (agentPair && agentPair.phone_id !== conn.id) {
        // 条件④：新手机对同一 agent bind → 旧手机 PAIR_REPLACED
        const oldPhone = phones.get(agentPair.phone_id)
        destroyPair(agentPair, 'replaced by new phone (cond ④)')
        if (oldPhone) errorTo(oldPhone, 'PAIR_REPLACED', '已在另一台手机完成配对')
      }
      const myOldPairId = phoneIndex.get(conn.id)
      if (myOldPairId && pairs.has(myOldPairId)) {
        // 条件⑤：手机对另一 agent bind → 旧 agent PAIR_REPLACED（v1.0.5）
        const oldPair = pairs.get(myOldPairId)
        const oldAgent = agents.get(oldPair.agent_id)
        destroyPair(oldPair, 'phone rebound to another agent (cond ⑤)')
        if (oldAgent) errorTo(oldAgent, 'PAIR_REPLACED', '该手机已在另一台电脑完成配对')
      }

      const agentConn = agents.get(rec.agent_id)
      if (!agentConn) return errorTo(conn, 'PEER_OFFLINE', 'agent 不在线，无法完成绑定') // QR 5min 内 agent 应在线
      const pairId = `pair-${nextPairId++}`
      const pair = { pair_id: pairId, agent_id: rec.agent_id, agent_boot_id: agentConn.bootId, phone_id: conn.id, createdAt: Date.now(), graceTimer: null }
      pairs.set(pairId, pair)
      phoneIndex.set(conn.id, pairId)
      const turn = allocTurn(pairId)
      send(conn, { t: 'pair.ok', pair_id: pairId, agent_id: pair.agent_id, turn })
      send(agentConn, { t: 'pair.ok', pair_id: pairId, agent_id: pair.agent_id, turn })
      log(`pair created: ${pairId} agent=${pair.agent_id.slice(0, 8)} phone=${pair.phone_id.slice(0, 8)}`)
      return
    }

    case 'punch.request': {
      if (conn.role !== 'app') return deny(conn)
      const pair = pairs.get(msg.pair_id)
      if (!pair || pair.phone_id !== conn.id) return errorTo(conn, 'PAIR_NOT_FOUND', 'pair_id mismatch')
      if (!agentOnline(pair)) return errorTo(conn, 'PEER_OFFLINE', '对端不在线（宽限期内），等 presence 恢复后重试') // 不得静默丢弃
      pair.lastPunchRequestAt = Date.now()
      const agent = agents.get(pair.agent_id)
      send(agent, { t: 'punch.request', pair_id: pair.pair_id })
      return
    }

    case 'punch.offer':
    case 'punch.answer': {
      const pair = pairs.get(msg.pair_id)
      const isAgent = conn.role === 'agent'
      const expectedId = isAgent ? pair?.agent_id : pair?.phone_id
      if (!pair || expectedId !== conn.id) { errorTo(conn, 'PAIR_NOT_FOUND', 'pair_id assertion failed'); log('WARN pair_id assertion failed'); return }
      if (typeof msg.sdp !== 'string' || msg.sdp.length > MAX_FRAME) { conn.ws.close(1009, 'bad sdp'); return } // 02 §3.2 防放大
      const target = isAgent ? phones.get(pair.phone_id) : agents.get(pair.agent_id)
      if (!target) return errorTo(conn, 'PEER_OFFLINE', '对端不在线')
      if (t === 'punch.offer' && isAgent) {
        // 自发重发 ≥2s 限流（02 §3.3）：punch.request 之后 10s 内的 offer 视为受请求触发，不受限
        const requested = pair.lastPunchRequestAt && Date.now() - pair.lastPunchRequestAt < 10_000
        if (!requested && pair.lastOfferAt && Date.now() - pair.lastOfferAt < 2000) return // 窗口内丢弃
        pair.lastOfferAt = Date.now()
      }
      send(target, { t, pair_id: pair.pair_id, sdp: msg.sdp })
      return
    }

    case 'relay.request': {
      send(conn, { t: 'relay.alloc', turn: allocTurn(`relay-${conn.id.slice(0, 8)}`) })
      return
    }

    case 'presence.get': {
      const pair = conn.role === 'agent'
        ? [...pairs.values()].find(p => p.agent_id === conn.id)
        : phoneIndex.get(conn.id) ? pairs.get(phoneIndex.get(conn.id)) : null
      const peerOnline = pair ? (conn.role === 'agent' ? phoneOnline(pair) : agentOnline(pair)) : false
      send(conn, { t: 'presence', peer_online: peerOnline })
      return
    }

    case 'bye': {
      // ① 显式撤销：销毁 → bye.ok → 转发对端（契约 §4.1；过期代次的 bye 已在 stale/owned 判定中排除）
      const isAgent = conn.role === 'agent'
      const pair = isAgent
        ? [...pairs.values()].find(p => p.agent_id === conn.id)
        : phoneIndex.get(conn.id) ? pairs.get(phoneIndex.get(conn.id)) : null
      if (!pair) { send(conn, { t: 'bye.ok', ts: Date.now() }); return } // 无 pair 视为已撤销
      if (isAgent ? agents.get(pair.agent_id) !== conn : phones.get(pair.phone_id) !== conn) return // 过期代次 bye 忽略（02 §2.1 约束 2）
      const peerConn = isAgent ? phones.get(pair.phone_id) : agents.get(pair.agent_id)
      destroyPair(pair, `bye (${msg.reason})`)
      send(conn, { t: 'bye.ok', ts: Date.now() })
      if (peerConn) send(peerConn, { t: 'bye', reason: msg.reason })
      return
    }

    default:
      // 未知类型：error + 关闭（契约 §4：t 是封闭集合，永不实现通用转发）
      errorTo(conn, 'AUTH_FAILED', `unknown message type: ${t}`)
      conn.ws.close()
      return
  }
}

function deny(conn) { errorTo(conn, 'AUTH_FAILED', 'role not allowed for this message'); }

// 60s sweeper：半开连接发现（02 §3.2）——与 close 走同一条 GRACE 流程
setInterval(() => {
  const now = Date.now()
  for (const conn of [...agents.values(), ...phones.values()]) {
    const ls = lastSeen.get(conn)
    if (ls && now - ls.lastAt > 60_000) {
      log('sweeper: silent conn', conn.id?.slice(0, 8), '→ offline')
      try { conn.ws.terminate() } catch {}
      onConnClose(conn)
    }
  }
  for (const [n, at] of nonces) if (now - at > NONCE_WINDOW_MS) nonces.delete(n)
}, 30_000).unref?.()

wss.on('listening', () => log(`listening on ws://127.0.0.1:${PORT}/v1/signal (path-agnostic fake; Go 版只挂 /v1/signal)`))
