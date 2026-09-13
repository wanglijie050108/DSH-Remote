// dsh-mobile-link —— apply()：最小装配 + dispose 清理（01 §2）
// 装配成功是硬性前提（§2.1）：import 期零 IO/零网络（本文件顶层只做定义）；apply() 只做本地装配（全同步）；
// 装配失败 → fail-fast（连带 DSH 启动失败，属已接受耦合）；运行期故障 → 退避重试 + 状态输出。
// inject 的代价（01 §2）：webServer/connection/approval 任一缺失 → FIBER_PENDING → DSH 启动失败。
// web profile 三行均在（已核实 F5/F6/F17）；fail-fast 全部自带自救指引（§2.1）。
import { randomBytes } from 'node:crypto'
import { loadConfig, ConfigError } from './config.js'
import { loadIdentity, createDtlsCertificate, KeysError } from './keys.js'
import { BridgeClient } from './bridge.js'
import { Tunnel } from './tunnel.js'
import { createOfferPeer } from './rtc.js'
import { newPairToken, ptokHash, buildPairUri, renderQr } from './pairing.js'
import { registerApprovalStub } from './approve.js'

export const name = 'dsh-mobile-link'
export const inject = ['webServer', 'connection', 'approval']

const CRED_TTL_THRESHOLD = 300_000 // 剩余 TTL < 300s 视为无效（契约 §5，v1.0.4 写死）

function makeLogger(level = 'info') {
  const order = { debug: 10, info: 20, warn: 30, error: 40 }
  const min = order[level] ?? 20
  const emit = (lv, ...a) => { if ((order[lv] ?? 20) >= min) console.log(`[dsh-mobile-link][${lv}]`, ...a) }
  return {
    debug: (...a) => emit('debug', ...a),
    info: (...a) => emit('info', ...a),
    warn: (...a) => emit('warn', ...a),
    error: (...a) => emit('error', ...a),
  }
}

/** boot_id：进程级（§2.3）。挂 globalThis —— web profile 的 patchReload: live 热重载重建插件实例时不变。 */
export function processBootId() {
  const g = globalThis
  if (!g.__DSML_BOOT_ID) {
    g.__DSML_BOOT_ID = `boot-${process.pid}-${Date.now().toString(36)}-${randomBytes(6).toString('hex')}`
  }
  return g.__DSML_BOOT_ID
}

export function apply(ctx) {
  const log = makeLogger(process.env.DSML_LOG_LEVEL || 'info')

  // ---- 装配期（fail-fast 阶段，全同步）----
  let cfg, identity, dtls
  try {
    cfg = loadConfig(process.env, ctx.webServer?.port ?? null)
    identity = loadIdentity(process.env)
    dtls = createDtlsCertificate(identity)
  } catch (e) {
    if (e instanceof ConfigError || e instanceof KeysError) {
      console.error(`[dsh-mobile-link][fatal] ${e.message}`)
    }
    throw e // 连带 DSH 启动失败 = 已接受耦合（§2.1）
  }
  const { certificate, fp } = dtls
  const bootId = processBootId()
  log.info(`assembled: boot_id=${bootId} agent_id=${identity.agentId.slice(0, 8)}… fp=${fp.slice(0, 16)}…`)

  // launch token：程序化取得（01 §6）；全程内存内，不落盘、不写日志、不进 pair.ready
  let launchToken = process.env.DSML_LAUNCH_TOKEN || null
  if (!launchToken) {
    try {
      const port = cfg.forwardTarget.split(':')[1]
      const url = ctx.connection?.authenticatedUrl?.(`http://127.0.0.1:${port}/`)
      if (url) launchToken = new URL(url).searchParams.get('token')
    } catch (e) {
      log.warn('authenticatedUrl() 不可用，QR 不带 t（手机将走 401 提示路径）:', e.message)
    }
  }

  // ---- 运行期状态 ----
  const state = {
    pairActive: false,   // 收到 pair.ok 且未被 §4.3 条件①–⑤销毁
    pairId: null,
    pairToken: null,     // 内存保存原值；收到 pair.ok 后用后即弃
    qrPrinted: false,
    iceServers: [],
    turn: null,          // {uris, username, credential, ttl, expireAt}
    pc: null,
    tunnel: null,
    pendingCreds: null,  // relay.request 等待
    lastSpontaneousOffer: 0,
    rebuilding: false,
  }

  // ---- 进程退出 vs fiber dispose（§2.2）----
  // 候选②：SIGINT/SIGTERM 置标志。DSH 自身处理器先注册先执行——不能靠标志阻止退出，
  // 但 bye 本就是尽力而为；该判定的失败方向是"漏发 bye"（安全侧）。
  const exitState = { processExiting: false }
  const markExiting = () => { exitState.processExiting = true }
  process.on('SIGINT', markExiting)
  process.on('SIGTERM', markExiting)

  const bridge = new BridgeClient({
    signalHost: cfg.signalUrl,
    signalScheme: cfg.signalScheme,
    privPem: identity.privPem,
    pubB64u: identity.pubB64u,
    bootId,
    log: (...a) => log.info(...a),
    onHelloOk: (msg) => {
      if (msg.pair) {
        // 免扫码恢复（boot_id 相同）：主动重发 offer（§3.5 规则 1；由重连触发，不受自发 2s 窗口约束）
        state.pairActive = true
        state.pairId = msg.pair.pair_id
        log.info(`hello.ok: 恢复 pair ${state.pairId}（peer_online=${msg.peer_online}）`)
        rebuild({ requested: true })
      } else {
        // 只在 hello.ok{pair:null} 后注册 pair.ready（§4.4：否则每次网络抖动都重印 QR）
        state.pairActive = false
        state.pairId = null
        registerPairToken()
      }
    },
    onPairReadyOk: () => {
      if (state.pairActive || state.qrPrinted) return // pair 存续期 MUST NOT 重印（§4.4）
      printQr()
    },
    onPairOk: (msg) => {
      state.pairActive = true
      state.pairId = msg.pair_id
      state.pairToken = null // 用后即弃（§4.3）
      state.qrPrinted = false
      state.turn = { ...msg.turn, expireAt: Date.now() + msg.turn.ttl * 1000 }
      state.iceServers = msg.turn.uris.map((u) => ({ urls: u }))
      log.info(`pair.ok: ${msg.pair_id}（TURN 凭证已收；QR 作废，存续期不重印）`)
    },
    onPunchRequest: () => rebuild({ requested: true }), // punch.request 触发的 offer 不受 2s 窗口约束（§3.5 规则 3）
    onPunchAnswer: async (msg) => {
      try {
        await state.pc?.setRemoteDescription({ type: 'answer', sdp: msg.sdp })
        log.info('punch.answer → setRemoteDescription 完成')
      } catch (e) { log.warn('answer 处理失败:', e.message) }
    },
    onPresence: (msg) => log.info(`presence: peer_online=${msg.peer_online}`), // A5：仅日志
    onRelayAlloc: (msg) => {
      state.turn = { ...msg.turn, expireAt: Date.now() + msg.turn.ttl * 1000 }
      state.iceServers = msg.turn.uris.map((u) => ({ urls: u }))
      state.pendingCreds?.resolve()
      state.pendingCreds = null
      log.info('relay.alloc: TURN 凭证就绪')
    },
    onBye: () => { // 条件①：对端主动解除 → 拆隧道 → 恢复未配对 → 恢复 QR 轮印（§4.4）
      log.info('对端 bye → 拆隧道，恢复未配对')
      teardownTunnel()
      state.pairActive = false
      state.pairId = null
      registerPairToken()
    },
    onByeOk: () => log.info('bye.ok'),
    onError: (code, msg) => {
      log.warn(`error ${code}: ${msg}`)
      if (code === 'PAIR_REPLACED' || code === 'PAIR_NOT_FOUND') {
        // 条件⑤收件方（手机已换绑他机）/ 过期 offer（02 §3.2）：拆隧道 → 恢复未配对 → 恢复轮印（§4.4/E10⑦）
        teardownTunnel()
        state.pairActive = false
        state.pairId = null
        registerPairToken()
      }
      // RATE_LIMITED / INTERNAL：BridgeClient 退避已覆盖
    },
    onFatalQuit: (code, msg) => {
      // PROTO_VER_UNSUPPORTED：明确报错，不重试（§4.5：升级客户端；重扫码解决不了版本偏差）
      log.error(`FATAL ${code}: ${msg} —— 请升级 dsh-mobile-link。停止重连。`)
      bridge.close()
    },
  })

  function registerPairToken() {
    state.pairToken = newPairToken()
    state.qrPrinted = false
    bridge.send({ t: 'pair.ready', ptok_hash: ptokHash(state.pairToken), ttl: 300 })
    log.info('pair.ready 已发送（等待 pair.ready.ok 才出 QR）')
  }

  async function printQr() {
    const uri = buildPairUri({ sigUrlHost: cfg.signalUrl, sigScheme: cfg.signalScheme, ptok: state.pairToken, fp, authority: cfg.authority, launchToken })
    try {
      const qrcodeModule = (await import('qrcode')).default
      console.log('\n' + await renderQr(uri, qrcodeModule) + '\n')
      state.qrPrinted = true
    } catch {
      console.log(`\n[dsh-mobile-link] 配对 URI（qrcode 渲染失败）：${uri}\n`)
      state.qrPrinted = true
    }
  }

  async function ensureTurnCreds() {
    if (state.turn && state.turn.expireAt - Date.now() > CRED_TTL_THRESHOLD) return
    // 任何一次新 gather 之前 MUST 先取有效凭证（§5）——否则 offer 静默缺 relay 候选
    log.info('TURN 凭证缺失或临近过期 → relay.request')
    bridge.send({ t: 'relay.request' })
    await new Promise((resolve) => {
      state.pendingCreds = { resolve }
      setTimeout(resolve, 3000) // 取不到也继续（host 候选仍可工作；下次重建再取）
    })
  }

  function teardownTunnel() {
    state.tunnel?.detach()
    state.tunnel = null
    try { state.pc?.close() } catch {}
    state.pc = null
  }

  /** 隧道重建（契约 §3.5）：销毁整条 PeerConnection 并发新 offer；stream_id 空间由新 Tunnel 实例从 1 重启 */
  async function rebuild({ requested }) {
    if (state.rebuilding) return
    state.rebuilding = true
    try {
      if (!requested && Date.now() - state.lastSpontaneousOffer < 2000) return // 自发重发 ≥2s（§3.5 规则 3）
      state.lastSpontaneousOffer = Date.now()
      teardownTunnel()
      await ensureTurnCreds()
      const { pc, dataCh, ctlCh, offer } = await createOfferPeer({ certificate, iceServers: state.iceServers, log: (...a) => log.info(...a) })
      state.pc = pc
      const tunnel = new Tunnel({
        forwardTarget: cfg.forwardTarget,
        log: (...a) => log.info(...a),
        onDead: () => rebuild({ requested: false }), // 15s 兜底触发器 → 重建
      })
      state.tunnel = tunnel
      dataCh.onopen = () => {
        log.info('data channel open → tunnel attach')
        tunnel.attach(dataCh, ctlCh)
      }
      pc.connectionStateChange.subscribe((s) => {
        if (s === 'failed' || s === 'disconnected') {
          log.info(`rtc ${s} → 主触发重建（§3.5）`)
          rebuild({ requested: false })
        }
        if (s === 'connected') tunnel.lastFrameAt = Date.now() // ICE 建立耗时不应计入 15s 兜底
      })
      bridge.send({ t: 'punch.offer', pair_id: state.pairId, sdp: offer.sdp })
      log.info('punch.offer 已发送')
    } catch (e) {
      log.warn('重建失败:', e.message)
    } finally {
      state.rebuilding = false
    }
  }

  bridge.connect()

  // ---- dispose（§2.2 清理顺序：bye（仅进程退出）→ socket/流 → DataChannel/PC → WSS → 定时器）----
  const unregisterSignals = () => {
    process.off('SIGINT', markExiting)
    process.off('SIGTERM', markExiting)
  }
  ctx.effect(() => {
    return () => {
      // 仅当进程退出时发 bye（热重载/disabled 不发——发 = 销毁 pair = 逼用户重新扫码，§2.2）
      const byePromise = exitState.processExiting ? bridge.sendByeOnShutdown('shutdown') : Promise.resolve(false)
      teardownTunnel()
      bridge.close()
      unregisterSignals()
      return byePromise.then((sent) => {
        if (exitState.processExiting) log.info(`进程退出清理完成（bye ${sent ? '已确认' : '尽力而为未确认'}）`)
        else log.info('fiber dispose 清理完成（未发 bye；依赖 boot_id 在宽限期内恢复）')
      })
    }
  }, 'dsh-mobile-link dispose')

  registerApprovalStub(ctx, (...a) => log.debug(...a))
  return { bootId, agentId: identity.agentId, fp }
}
