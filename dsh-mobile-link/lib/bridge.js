// 信令客户端（01 §4.4）：WSS 长连接、hello 规范化签名、退避重连、消息分发
// hello 序列化严格按契约 §4.2：ts=epoch 秒十进制；nonce=32B→base64url（每次新生成）；
// 被签名串=UTF-8 "hello|" + String(ts) + "|" + nonce；sig=ECDSA P-256/SHA-256 DER→base64url（禁 P1363）。
import { createSign, randomBytes } from 'node:crypto'
import { WebSocket } from 'ws'
import { PROTO_VER } from './config.js'

export function canonicalHelloBytes(ts, nonce) {
  return Buffer.from(`hello|${ts}|${nonce}`, 'utf8')
}

export function signHelloBytes(privPem, ts, nonce) {
  const s = createSign('sha256')
  s.update(canonicalHelloBytes(ts, nonce))
  return s.sign(privPem).toString('base64url') // DER（Node 默认即 ASN.1）
}

const BACKOFF_MIN = 500
const BACKOFF_MAX = 30_000

/**
 * @param {object} opts
 * @param {string} opts.signalHost   主机名（DSML_SIGNAL_URL）
 * @param {string} opts.privPem      身份私钥（PKCS8 PEM）
 * @param {string} opts.pubB64u      SPKI DER → base64url
 * @param {string} opts.bootId       进程级 boot_id（§2.3）
 * @param {function} opts.log
 * 回调（均可选）：onHelloOk(msg) / onPairReadyOk / onPairOk(msg) / onPunchRequest / onPunchAnswer /
 *   onPresence(msg) / onRelayAlloc(msg) / onBye(msg) / onByeOk / onError(code,msg) / onFatalQuit(code)
 */
export class BridgeClient {
  constructor(opts) {
    this.opts = opts
    this.ws = null
    this.retryTimer = null
    this.backoff = BACKOFF_MIN
    this.closedByUs = false
    this.pingTimer = null // 应用层心跳：客户端每 25s（契约 §4）
  }

  get endpoint() {
    // signalScheme：显式 ws:// 仅开发期（05 §0.1）；默认 wss://（契约 §2）
    return `${this.opts.signalScheme || 'wss://'}${this.opts.signalHost}/v1/signal`
  }

  connect() {
    this.closedByUs = false
    const ws = new WebSocket(this.endpoint)
    this.ws = ws
    ws.on('open', () => {
      this.backoff = BACKOFF_MIN // 成功连接即复位退避
      const ts = Math.floor(Date.now() / 1000) // epoch 秒（不是毫秒，§4.2）
      const nonce = randomBytes(32).toString('base64url')
      const sig = signHelloBytes(this.opts.privPem, ts, nonce)
      ws.send(JSON.stringify({
        t: 'hello', role: 'agent', pub: this.opts.pubB64u,
        boot_id: this.opts.bootId, ts, nonce, sig, proto_ver: PROTO_VER,
      }))
      clearInterval(this.pingTimer)
      this.pingTimer = setInterval(() => { try { ws.send(JSON.stringify({ t: 'ping' })) } catch {} }, 25_000)
      this.pingTimer.unref?.()
    })
    ws.on('message', (raw) => {
      let msg
      try { msg = JSON.parse(raw.toString()) } catch { return }
      this.dispatch(msg)
    })
    ws.on('close', () => {
      clearInterval(this.pingTimer)
      if (this.closedByUs) return
      this.scheduleReconnect()
    })
    ws.on('error', (e) => { try { ws.close() } catch {} })
  }

  scheduleReconnect() {
    // 指数退避 500ms→30s + 抖动（01 §2.1 运行期故障：不阻断启动）
    const jitter = Math.floor(Math.random() * this.backoff * 0.3)
    const delay = this.backoff + jitter
    this.backoff = Math.min(this.backoff * 2, BACKOFF_MAX)
    this.opts.log?.(`bridge 断开，${delay}ms 后重连`)
    clearTimeout(this.retryTimer)
    this.retryTimer = setTimeout(() => this.connect(), delay)
    this.retryTimer.unref?.()
  }

  dispatch(msg) {
    const o = this.opts
    switch (msg.t) {
      case 'hello.ok': o.onHelloOk?.(msg); return
      case 'pair.ready.ok': o.onPairReadyOk?.(msg); return
      case 'pair.ok': o.onPairOk?.(msg); return
      case 'punch.request': o.onPunchRequest?.(msg); return
      case 'punch.answer': o.onPunchAnswer?.(msg); return
      case 'presence': o.onPresence?.(msg); return // 仅记日志（A5：自发重发暂停机制暂不做）
      case 'relay.alloc': o.onRelayAlloc?.(msg); return
      case 'bye': o.onBye?.(msg); return
      case 'bye.ok': o.onByeOk?.(msg); return
      case 'pong': return
      case 'error':
        if (msg.code === 'PROTO_VER_UNSUPPORTED') { o.onFatalQuit?.(msg.code, msg.msg); return } // 不重试（§4.5）
        o.onError?.(msg.code, msg.msg)
        return
      default: return // 收到未知 t：记日志忽略（Bridge 是封闭集合的执行者，客户端不因此断开）
    }
  }

  send(obj) { try { this.ws?.send(JSON.stringify(obj)) } catch {} }

  /** 进程退出路径（仅此路径）：bye{shutdown}，等 bye.ok ≤2s 后 resolve（尽力而为，01 §2.2） */
  sendByeOnShutdown(reason = 'shutdown') {
    if (!this.ws || this.ws.readyState !== this.ws.OPEN) return Promise.resolve(false)
    return new Promise((resolve) => {
      const timer = setTimeout(() => resolve(false), 2000)
      const origOnByeOk = this.opts.onByeOk
      this.opts.onByeOk = (msg) => {
        clearTimeout(timer)
        this.opts.onByeOk = origOnByeOk // 恢复原有回调
        resolve(true)
        origOnByeOk?.(msg) // 透传原回调（日志用）
      }
      this.send({ t: 'bye', reason })
    })
  }

  close() {
    this.closedByUs = true
    clearInterval(this.pingTimer)
    clearTimeout(this.retryTimer)
    try { this.ws?.close() } catch {}
    this.ws = null
  }
}
