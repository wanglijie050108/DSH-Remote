// 编排层：状态机（对齐 fake-phone.mjs 语义 + 03 §3.3 错误矩阵）+ 持久化 + 日志
// 状态流：IDLE → CONNECTING → SIGNING → (PAIRING | PUNCHING) → ANSWERING → READY
// 重连纪律：WS 断开 1s 退避重连（pair 靠 phone_id 保留，hello.ok{pair} 自动恢复）；
// ICE failed/disconnected 与隧道 15s 无帧都走 ensureTurnAndPunch 重建（§3.5 主触发）。
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { socket } from '@kit.NetworkKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SignalClient, SignalMsg } from '../signal/SignalMsg';
import { PairQr, PairQrResult, parsePairQr } from '../contract/QrPair';
import { verifyPin } from '../contract/Fingerprint';
import { PhoneIdentity, buildAppHello, PROTO_VER } from '../contract/Hello';
import { TurnBlock } from '../contract/Turn';
import { RtcEngine } from '../rtc/RtcEngine';
import { TunnelEndpoint } from '../tunnel/TunnelEndpoint';
import { LocalProxy } from '../proxy/LocalProxy';
import { b64uToBytes, bytesToB64u } from '../contract/Codec';

const TAG: string = '[Harness]'
const DOMAIN: number = 0xD001
const PROXY_PORT: number = 13080
const TURN_TTL_INVALID_MS: number = 300 * 1000 // TTL<300s 视为无效（契约 §5）
const RECONNECT_MS: number = 1000
const PUNCH_RETRY_MS: number = 25000 // 与插件 gather 看门狗 20s 错峰（changelog 020）
const PUNCH_MAX_ATTEMPTS: number = 6

export class PairState {
  public sigURL: string = ''
  public authority: string = ''
  public fp: string = ''
  public agentId: string = ''
  public pairId: string = ''
  public launchToken: string = '' // QR t= 参数：DSH web 首页鉴权 token（dsh 重启后随新 QR 更新）
  public turn: TurnBlock | null = null
  public turnExpireAt: number = 0
}

export class HarnessService {
  public static instance: HarnessService = new HarnessService()

  public rtc: RtcEngine = new RtcEngine()
  public proxy: LocalProxy = new LocalProxy()
  public identity: PhoneIdentity | null = null
  public pair: PairState | null = null
  public relayOnly: boolean = false
  public stoppedByUser: boolean = true
  public pendingPtok: string = ''

  private signal: SignalClient = new SignalClient()
  private tunnel: TunnelEndpoint | null = null
  private store: preferences.Preferences | null = null
  private logLines: string[] = []
  private reconnectTimer: number = -1
  private relayWaiter: number = -1
  private punchRetryTimer: number = -1
  private punchAttempt: number = 0
  private channelsOpened: Set<string> = new Set()
  private answering: boolean = false
  private awaitingAnswer: boolean = false

  // ---- 生命周期 ----
  public async init(context: common.UIAbilityContext): Promise<void> {
    this.store = preferences.getPreferencesSync(context, { name: 'dsh_harness' })
    await this.loadOrCreateIdentity()
    this.loadPairState()
    this.wireRtc()
    this.proxy.onAccept = (conn: socket.TCPSocketConnection): boolean => {
      return this.acceptProxyConnection(conn)
    }
    if (this.identity !== null) {
      this.log(`harness init：phone_id=${this.identity.getPhoneId().substring(0, 12)}…`)
    }
  }

  private async loadOrCreateIdentity(): Promise<void> {
    const priB64 = this.readStoredString('identity_pkcs8_b64')
    const pubB64 = this.readStoredString('identity_spki_b64')
    if (priB64.length > 0 && pubB64.length > 0) {
      try {
        this.identity = await PhoneIdentity.fromPkcs8AndSpkiDer(b64uToBytes(priB64), b64uToBytes(pubB64))
        this.log('identity：已从偏好恢复')
        return
      } catch (e) {
        this.log(`identity 恢复失败（重新生成）：${String(e)}`)
      }
    } else if (priB64.length > 0) {
      // 旧版只持久化了私钥：cryptoFramework 私钥单独恢复拿不到公钥（官方约束），只能重建身份
      this.log('identity：旧数据缺少 SPKI 公钥材料，重新生成（已配对过的设备需重新配对）')
    }
    this.identity = await PhoneIdentity.generate()
    this.saveIdentity(this.identity)
    this.log('identity：新生成并持久化')
  }

  private readStoredString(key: string): string {
    const raw = this.store?.getSync(key, '')
    return typeof raw === 'string' ? raw : ''
  }

  private saveIdentity(identity: PhoneIdentity): void {
    this.store?.putSync('identity_pkcs8_b64', bytesToB64u(identity.getPkcs8Der()))
    this.store?.putSync('identity_spki_b64', bytesToB64u(identity.getPubSpkiDer()))
    this.store?.flush()
  }

  private loadPairState(): void {
    const rawRaw = this.store?.getSync('pair_json', '')
    const raw = typeof rawRaw === 'string' ? rawRaw : ''
    if (raw.length === 0) {
      return
    }
    try {
      const r = JSON.parse(raw) as Record<string, Object>
      const p = new PairState()
      p.sigURL = String(r['sigURL'])
      p.authority = String(r['authority'])
      p.fp = String(r['fp'])
      p.agentId = String(r['agentId'])
      p.pairId = String(r['pairId'])
      if (r['launchToken'] !== undefined && r['launchToken'] !== null && typeof r['launchToken'] === 'string') {
        p.launchToken = String(r['launchToken'])
      }
      if (r['turn'] !== undefined && r['turn'] !== null && typeof r['turn'] === 'string' && String(r['turn']).length > 0) {
        const t = JSON.parse(String(r['turn'])) as Record<string, Object>
        const tb = new TurnBlock()
        tb.username = String(t['username'])
        tb.credential = String(t['credential'])
        tb.ttl = Number(t['ttl'])
        const uris = t['uris'] as Array<Object>
        for (const u of uris) {
          tb.uris.push(String(u))
        }
        p.turn = tb
      }
      p.turnExpireAt = Number(r['turnExpireAt'])
      this.pair = p
      this.log('pair state：已恢复（可免扫码重连）')
    } catch (e) {
      this.log(`pair state 恢复失败：${String(e)}`)
    }
  }

  private savePairState(): void {
    if (this.pair === null) {
      return
    }
    const p = this.pair
    const turnStr = p.turn === null ? '' : JSON.stringify(this.turnToRecord(p.turn))
    const obj: Record<string, Object> = {
      'sigURL': p.sigURL, 'authority': p.authority, 'fp': p.fp,
      'agentId': p.agentId, 'pairId': p.pairId, 'launchToken': p.launchToken,
      'turn': turnStr, 'turnExpireAt': p.turnExpireAt,
    }
    this.store?.putSync('pair_json', JSON.stringify(obj))
    this.store?.flush()
  }

  private turnToRecord(t: TurnBlock): Record<string, Object> {
    const uris: string[] = []
    for (const u of t.uris) {
      uris.push(u)
    }
    const o: Record<string, Object> = {
      'uris': uris, 'username': t.username, 'credential': t.credential, 'ttl': t.ttl,
    }
    return o
  }

  private clearPairState(): void {
    this.pair = null
    this.store?.putSync('pair_json', '')
    this.store?.flush()
  }

  // ---- 对外动作 ----
  /** 粘贴 QR 配对入口（v1 不做扫码） */
  public pairFromQr(qrText: string): boolean {
    const r: PairQrResult = parsePairQr(qrText.trim())
    if (!r.ok || r.qr === null) {
      this.log(`QR 解析失败：${r.error}`)
      return false
    }
    const qr: PairQr = r.qr
    // 先拆旧隧道（主动换绑先拆后绑，03 §3.3）
    this.teardownTunnel(true)
    this.clearPairState()
    const p = new PairState()
    p.sigURL = qr.s
    p.authority = qr.a
    p.fp = qr.fp
    p.launchToken = qr.t === null ? '' : qr.t
    this.pair = p
    this.pendingPtok = qr.pt
    this.savePairState()
    this.log(`QR OK：sig=${maskUrl(qr.s)} a=${qr.a} fp=${qr.fp.substring(0, 16)}… t=${qr.t === null ? '无' : '有'}`)
    this.stoppedByUser = false
    this.connectSignal()
    return true
  }

  /** 免扫码重连入口 */
  public resume(): boolean {
    if (this.pair === null || this.pair.fp === '') {
      this.log('无配对信息，请先粘贴 QR')
      return false
    }
    this.stoppedByUser = false
    this.connectSignal()
    return true
  }

  public stop(): void {
    this.stoppedByUser = true
    this.clearTimer(this.reconnectTimer)
    this.reconnectTimer = -1
    this.sendBye()
    this.teardownTunnel(true)
    this.signal.close()
    this.setState('IDLE', '已停止')
  }

  public setRelayOnly(on: boolean): void {
    this.relayOnly = on
    this.log(`relay-only 模式：${on ? '开' : '关'}（重建隧道后生效）`)
  }

  private sendBye(): void {
    if (this.pair !== null && this.signal.isUsable()) {
      const o: Record<string, string> = { 't': 'bye', 'reason': 'user' }
      this.signal.sendJson(o)
    }
  }

  // ---- 信令连接与 hello ----
  private connectSignal(): void {
    if (this.pair === null) {
      return
    }
    this.setState('CONNECTING', `连接 ${maskUrl(this.pair.sigURL)}`)
    this.signal.onOpen = () => {
      this.setState('SIGNING', 'hello 发送中')
      this.buildAndSendHello()
    }
    this.signal.onMsg = (msg: SignalMsg) => {
      this.onSignal(msg)
    }
    this.signal.onClose = () => {
      this.teardownTunnel(false)
      if (!this.stoppedByUser) {
        this.setState('BACKOFF', `${RECONNECT_MS}ms 后重连`)
        this.clearTimer(this.reconnectTimer)
        this.reconnectTimer = setTimeout(() => {
          this.connectSignal()
        }, RECONNECT_MS)
      }
    }
    this.signal.close()
    this.signal.connect(this.pair.sigURL)
  }

  private async buildAndSendHello(): Promise<void> {
    if (this.identity === null) {
      return
    }
    try {
      const hello = await buildAppHello(this.identity, Math.floor(Date.now() / 1000))
      this.signal.sendJson(hello)
      this.log(`hello 已发（role=app proto=${PROTO_VER} phone_id=${this.identity.getPhoneId().substring(0, 12)}…）`)
    } catch (e) {
      this.log(`hello 构造失败：${String(e)}`)
      this.setState('BACKOFF', 'hello 失败')
    }
  }

  // ---- 信令消息分发（对齐 fake-phone 错误矩阵） ----
  private onSignal(msg: SignalMsg): void {
    switch (msg.t) {
      case 'hello.ok':
        this.onHelloOk(msg)
        return
      case 'pair.ok':
        this.onPairOk(msg)
        return
      case 'relay.alloc':
        this.onRelayAlloc(msg)
        return
      case 'punch.offer':
        this.onPunchOffer(msg)
        return
      case 'presence':
        if (msg.peer_online === true && this.tunnel === null && this.pair !== null && this.pair.pairId !== '') {
          this.log('presence：对端恢复在线 → 自动 punch')
          this.ensureTurnAndPunch()
        }
        return
      case 'bye':
        this.log('对端 bye → 需重新扫码（NEED_PAIR）')
        this.teardownTunnel(true)
        this.clearPairState()
        this.setState('IDLE', '对端已解除配对，请重新扫码')
        return
      case 'bye.ok':
        this.log('bye.ok')
        return
      case 'pong':
        return
      case 'error':
        this.onError(msg.code, msg.msg)
        return
      default:
        this.log(`未知消息 t=${msg.t}`)
        return
    }
  }

  private onHelloOk(msg: SignalMsg): void {
    if (this.pair === null) {
      return
    }
    if (msg.pair !== null) {
      // 免扫码恢复：pair 保留在服务端
      this.pair.pairId = msg.pair.pair_id
      this.pair.agentId = msg.pair.agent_id
      this.savePairState()
      this.log(`hello.ok：已有 pair=${msg.pair.pair_id.substring(0, 12)}… → 免扫码恢复`)
      this.ensureTurnAndPunch()
    } else if (this.pendingPtok !== '') {
      // 扫码路径：fresh QR 的 ptok 只在此刻有效
      this.setState('PAIRING', 'pair.bind 发送中')
      const o: Record<string, string> = { 't': 'pair.bind', 'ptok': this.pendingPtok }
      this.signal.sendJson(o)
      this.log('pair.bind 已发')
    } else {
      // 服务端无 pair 且无 fresh ptok → NEED_PAIR
      this.log('hello.ok：pair=null 且无 fresh ptok → 清本地（NEED_PAIR）')
      this.teardownTunnel(true)
      this.clearPairState()
      this.setState('IDLE', '请重新扫码（NEED_PAIR）')
    }
  }

  private onPairOk(msg: SignalMsg): void {
    if (this.pair === null) {
      return
    }
    this.pair.pairId = msg.pair_id
    this.pair.agentId = msg.agent_id
    if (msg.turn !== null) {
      this.pair.turn = msg.turn
      this.pair.turnExpireAt = Date.now() + msg.turn.ttl * 1000
    }
    this.savePairState()
    this.log(`pair.ok → pair=${msg.pair_id.substring(0, 12)}… agent=${msg.agent_id.substring(0, 12)}…（TURN 凭证已收）`)
    this.ensureTurnAndPunch()
  }

  private onRelayAlloc(msg: SignalMsg): void {
    if (this.pair === null || msg.turn === null) {
      return
    }
    this.pair.turn = msg.turn
    this.pair.turnExpireAt = Date.now() + msg.turn.ttl * 1000
    this.savePairState()
    this.log(`relay.alloc：凭证就绪（ttl=${msg.turn.ttl}s uris=${msg.turn.uris.length}条）`)
    this.clearTimer(this.relayWaiter)
    this.relayWaiter = -1
    this.sendPunchRequest()
  }

  private turnValid(): boolean {
    return this.pair !== null && this.pair.turn !== null &&
      this.pair.turnExpireAt > Date.now() + TURN_TTL_INVALID_MS
  }

  private ensureTurnAndPunch(): void {
    if (this.pair === null || !this.signal.isUsable()) {
      return
    }
    if (!this.turnValid()) {
      this.setState('PUNCHING', 'relay.request（无有效 TURN 凭证）')
      const o: Record<string, string> = { 't': 'relay.request' }
      this.signal.sendJson(o)
      this.clearTimer(this.relayWaiter)
      this.relayWaiter = setTimeout(() => {
        this.relayWaiter = -1
        this.log('relay.alloc 3s 未达 → 直接 punch（可能无 relay）')
        this.sendPunchRequest()
      }, 3000)
      return
    }
    this.sendPunchRequest()
  }

  private sendPunchRequest(): void {
    if (this.pair === null) {
      return
    }
    // PUNCHING 重试（changelog 020 实测缺口）：插件端 rebuild 的 gather 看门狗 20s 解锁后，
    // 若手机只 punch 一次就干等，会错过解锁窗口——每 25s 重发，共 6 次后放弃并明示。
    if (this.punchAttempt >= PUNCH_MAX_ATTEMPTS) {
      this.setState('BACKOFF', '多次 punch 无 offer（插件端 gather 持续挂死？看 DSH 控制台「重建失败」日志）')
      return
    }
    this.punchAttempt++
    this.setState('PUNCHING', `punch.request 已发（第 ${this.punchAttempt}/${PUNCH_MAX_ATTEMPTS} 次），等 offer`)
    const o: Record<string, string> = { 't': 'punch.request', 'pair_id': this.pair.pairId }
    this.signal.sendJson(o)
    this.log(`punch.request 已发（第 ${this.punchAttempt} 次，relay-only=${this.relayOnly ? '开' : '关'}）`)
    this.clearTimer(this.punchRetryTimer)
    this.punchRetryTimer = setTimeout(() => {
      this.punchRetryTimer = -1
      if (this.tunnel === null && !this.stoppedByUser && this.signal.isUsable()) {
        this.sendPunchRequest()
      }
    }, PUNCH_RETRY_MS)
  }

  private onPunchOffer(msg: SignalMsg): void {
    if (this.pair === null || this.answering) {
      return
    }
    this.punchAttempt = 0
    this.clearTimer(this.punchRetryTimer)
    this.punchRetryTimer = -1
    this.answering = true
    this.awaitingAnswer = true
    this.channelsOpened.clear()
    const lines = msg.sdp.split(/\r?\n/)
    // ★ pin 红线：setRemoteDescription 之前逐字节校验（§6.1 fail-closed）
    if (!verifyPin(this.pair.fp, lines)) {
      this.log('PIN FAIL：对端身份校验失败 → 中止（不得 setRemoteDescription）')
      this.answering = false
      this.awaitingAnswer = false
      this.setState('BACKOFF', 'PIN 校验失败')
      return
    }
    this.log('pin ok：与持久化 fp 逐字节一致')
    this.setState('ANSWERING', 'RTC answer 生成中')
    this.rtc.cmdAnswer(msg.sdp, this.iceServersJson(), this.relayOnly)
  }

  private iceServersJson(): string {
    const arr: Record<string, string>[] = []
    if (this.pair !== null && this.pair.turn !== null) {
      for (const uri of this.pair.turn.uris) {
        const s: Record<string, string> = {
          'urls': uri, 'username': this.pair.turn.username, 'credential': this.pair.turn.credential,
        }
        arr.push(s)
      }
    }
    return JSON.stringify(arr)
  }

  private onError(code: string, detail: string): void {
    switch (code) {
      case 'PEER_OFFLINE':
        this.log('PEER_OFFLINE：保持连接，等 presence 恢复后自动重试')
        this.setState('PUNCHING', '对端离线，等待恢复')
        return
      case 'PAIR_NOT_FOUND':
        this.log('PAIR_NOT_FOUND → 需重新扫码')
        this.teardownTunnel(true)
        this.clearPairState()
        this.setState('IDLE', '请重新扫码（NEED_PAIR）')
        return
      case 'AGENT_RESTARTED':
        this.log('AGENT_RESTARTED → 需重新扫码')
        this.teardownTunnel(true)
        this.clearPairState()
        this.setState('IDLE', '电脑端已重启，请重新扫码')
        return
      case 'PAIR_EXPIRED':
        this.log('PAIR_EXPIRED → 需重新扫码')
        this.teardownTunnel(true)
        this.clearPairState()
        this.setState('IDLE', '配对已过期，请重新扫码')
        return
      case 'PAIR_REPLACED':
        this.log('PAIR_REPLACED（被动方）→ 清配对 + 拆隧道')
        this.teardownTunnel(true)
        this.clearPairState()
        this.signal.close()
        this.setState('IDLE', '已在另一台手机配对')
        return
      case 'PROTO_VER_UNSUPPORTED':
        this.log(`PROTO_VER_UNSUPPORTED：本机 proto=${PROTO_VER}，需升级（不重试）`)
        this.setState('IDLE', '版本过旧，需升级 App')
        this.signal.close()
        return
      case 'PAIR_LIMIT':
        this.log('PAIR_LIMIT：服务繁忙，不自动重试')
        this.setState('BACKOFF', 'PAIR_LIMIT')
        return
      case 'RATE_LIMITED':
      case 'INTERNAL':
        this.log(`${code} → 指数退避`)
        this.setState('BACKOFF', code)
        return
      default:
        this.log(`error ${code}: ${detail}`)
        return
    }
  }

  // ---- RTC 回调（init 时接线；Web 组件由 Index 页挂载） ----
  private wireRtc(): void {
    this.rtc.addChannelOpenListener('svc', (label: string) => {
      this.channelsOpened.add(label)
      if (this.channelsOpened.has('data') && this.channelsOpened.has('ctl')) {
        this.bindTunnel()
      }
    })
    this.rtc.addChannelCloseListener('svc', (label: string) => {
      this.log(`channel close: ${label}`)
      if (label === 'data' || label === 'rtc') {
        this.teardownTunnel(false)
        if (!this.stoppedByUser) {
          this.ensureTurnAndPunch()
        }
      }
    })
    this.rtc.addFrameListener('svc', (label: string, b64: string) => {
      if (this.tunnel !== null) {
        this.tunnel.onChannelFrame(label, b64uToBytes(b64))
      }
    })
    this.rtc.addIceListener('svc', (state: string) => {
      if (state === 'connection:failed' || state === 'connection:disconnected') {
        this.log(`rtc ${state} → 主触发重建（§3.5）`)
        this.teardownTunnel(false)
        if (!this.stoppedByUser) {
          this.ensureTurnAndPunch()
        }
      } else if (state === 'connection:connected') {
        this.log('rtc connected（隧道待双通道就绪）')
      }
    })
    this.rtc.addSdpListener('svc', (sdp: string, err: string) => {
      this.onAnswerSdp(sdp, err)
    })
    this.rtc.addErrorListener('svc', (msg: string) => {
      if (this.awaitingAnswer) {
        this.awaitingAnswer = false
        this.answering = false
        this.log(`answer 失败：${msg}`)
        this.setState('BACKOFF', 'answer 失败')
      }
    })
    this.rtc.addLogListener('svc', (m: string) => {
      this.log(`[WebRTC] ${m}`)
    })
  }

  private onAnswerSdp(sdp: string, err: string): void {
    if (!this.awaitingAnswer) {
      return
    }
    this.awaitingAnswer = false
    this.answering = false
    if (err !== '' || sdp === '') {
      this.log(`answer 生成失败：${err}`)
      this.setState('BACKOFF', 'answer 失败')
      return
    }
    const pairId = this.pair !== null ? this.pair.pairId : ''
    const o: Record<string, string> = { 't': 'punch.answer', 'pair_id': pairId, 'sdp': sdp }
    this.signal.sendJson(o)
    this.log(`punch.answer 已发（${sdp.length}B）`)
    this.setState('CONNECTING', '等 DataChannel 双开')
  }

  private bindTunnel(): void {
    this.teardownTunnel(false) // 先拆旧 endpoint（计时器/流表）
    const sendData = (bytes: Uint8Array): void => {
      this.rtc.cmdSend('data', bytes)
    }
    const sendCtl = (bytes: Uint8Array): void => {
      this.rtc.cmdSend('ctl', bytes)
    }
    this.tunnel = new TunnelEndpoint(sendData, sendCtl)
    this.tunnel.onDead = () => {
      this.log('隧道判死（15s 无帧）→ 重建')
      this.teardownTunnel(false)
      if (!this.stoppedByUser) {
        this.ensureTurnAndPunch()
      }
    }
    this.startProxy()
    this.setState('READY', `DSH 已就绪 http://127.0.0.1:${PROXY_PORT}`)
    this.log('TUNNEL READY（双通道就绪，代理已启动）')
  }

  public teardownTunnel(stopProxyToo: boolean): void {
    if (this.tunnel !== null) {
      this.tunnel.close()
      this.tunnel = null
    }
    this.channelsOpened.clear()
    if (stopProxyToo) {
      this.proxy.stop()
    }
  }

  private async startProxy(): Promise<void> {
    if (this.proxy.isListening()) {
      return
    }
    const ok = await this.proxy.start(PROXY_PORT)
    if (!ok) {
      this.log(`本地端口 ${PROXY_PORT} 被占用：请关闭占用应用后重试（不回退端口）`)
    }
  }

  /** LocalProxy.accept → 隧道开流；未就绪返回 false（proxy 层立即 close） */
  private acceptProxyConnection(conn: socket.TCPSocketConnection): boolean {
    if (this.tunnel === null) {
      return false
    }
    return this.tunnel.openStream(conn) !== null
  }

  // ---- 日志与状态（AppStorage 承载 UI 刷新依赖） ----
  public log(line: string): void {
    const ts = new Date().toISOString().substring(11, 23)
    const full = `${ts} ${line}`
    this.logLines.push(full)
    if (this.logLines.length > 500) {
      this.logLines.shift()
    }
    hilog.info(DOMAIN, TAG, '%{public}s', line)
    AppStorage.setOrCreate('logTail', this.logLines.join('\n'))
  }

  public setState(s: string, detail: string): void {
    AppStorage.setOrCreate('hState', s)
    AppStorage.setOrCreate('hDetail', detail)
    this.log(`state → ${s}（${detail}）`)
  }

  private clearTimer(t: number): void {
    if (t >= 0) {
      clearTimeout(t)
    }
  }
}

function maskUrl(url: string): string {
  const idx = url.indexOf('?')
  return idx > 0 ? url.substring(0, idx) + '?…' : url
}
