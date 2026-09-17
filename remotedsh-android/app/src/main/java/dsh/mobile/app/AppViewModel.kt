// app 壳 —— 全模块胶水代码（串联 SignalClient / RtcEngine / LocalProxy / 状态机）
// 遵循 ponytail：不引入额外抽象，只接线
package dsh.mobile.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.lifecycle.AndroidViewModel
import dsh.mobile.bridge.PairSnapshot
import dsh.mobile.bridge.SignalClient
import dsh.mobile.bridge.SignalEvent
import dsh.mobile.bridge.TurnBlock
import dsh.mobile.contract.Frames
import dsh.mobile.contract.FrameCodec
import dsh.mobile.pairing.DeviceIdentity
import dsh.mobile.pairing.PairingState
import dsh.mobile.pairing.parseScannedQr
import dsh.mobile.proxy.LocalProxy
import dsh.mobile.proxy.TunnelSender
import dsh.mobile.rtc.RtcEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import org.json.JSONObject
import org.webrtc.PeerConnection
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

class AppViewModel(app: android.app.Application) : AndroidViewModel(app) {

    private val handler = Handler(Looper.getMainLooper())
    private val appScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // ── 模块实例 ──
    private val proxy = LocalProxy(appScope)
    private var signal: SignalClient? = null
    private var rtc: RtcEngine? = null

    // ── 状态 ──
    var state: AppState = AppState.Idle
        private set

    // 配对数据
    private var ptok: String = ""   // 用后即弃，不持久化
    private var pairId: String = "" // pair.ok 返回，供 punch.answer 用
    private var qrFp: String = ""   // ★ QR 中的证书指纹（与 agentId 不同！§3.1 安全锚点）
    private var turnBlock: TurnBlock? = null
    private var authority: String = "127.0.0.1:13080"
    private var launchToken: String? = null

    // stream 跟踪：streamId → (socket, 自上次 WINDOW 以来写入字节数)
    private val streams = ConcurrentHashMap<Long, Pair<Socket, AtomicInteger>>()

    // ── 回调（MainActivity 设置） ──
    var onNavigate: ((url: String) -> Unit)? = null
    var onStateChange: ((AppState) -> Unit)? = null

    init {
        proxy.onNewStream = { streamId, socket ->
            streams[streamId] = socket to AtomicInteger(0)
        }
        proxy.start()
    }

    // ── 公开入口 ──

    /** 扫码后调用 */
    fun onQrScanned(uri: String) {
        try {
            val qr = parseScannedQr(uri)
            ptok = qr.pt
            authority = qr.a
            launchToken = qr.t
            connect(qr.s, qr.fp)
        } catch (e: Exception) {
            setState(AppState.NeedPair(e.message ?: "二维码无效"))
        }
    }

    /** 恢复已有配对（跳过扫码） */
    fun restoreFromState(ps: PairingState) {
        val s = ps.sigURL ?: run { setState(AppState.NeedPair("缺少信令地址")); return }
        val fp = ps.fp ?: run { setState(AppState.NeedPair("缺少证书指纹，请重新扫码")); return }
        authority = ps.authority ?: "127.0.0.1:13080"
        connect(s, fp)
    }

    override fun onCleared() {
        signal?.close()
        rtc?.close()
        proxy.stop()
    }

    // ── 内部连接流程 ──

    private fun connect(sigUrl: String, fp: String) {
        setState(AppState.Signaling)
        qrFp = fp
        DeviceIdentity.ensureKey()

        signal = SignalClient(sigUrl, ::onSignalEvent)
        signal!!.connect()
    }

    // ── 信令事件分发 ──

    private fun onSignalEvent(event: SignalEvent) {
        when (event) {
            is SignalEvent.HelloOk -> onHelloOk(event)
            is SignalEvent.PairOk  -> onPairOk(event)
            is SignalEvent.PunchOffer -> onPunchOffer(event)
            is SignalEvent.RelayAlloc -> onRelayAlloc(event)
            is SignalEvent.Presence -> {} // 心跳维持
            is SignalEvent.ByeFromPeer -> setState(AppState.NeedPair("配对已断开"))
            is SignalEvent.ByeOk -> {} // 本端已发 bye，忽略
            is SignalEvent.PunchAnswer -> {} // app 不做 offer，忽略
            is SignalEvent.Error -> onSignalErrorEvent(event.code, event.msg)
        }
    }

    private fun onHelloOk(e: SignalEvent.HelloOk) {
        if (!e.peerOnline) {
            setState(AppState.NeedPair("PC 不在线"))
            return
        }
        // 重连路径（已有 pair）不需要重新 bind
        if (e.pair != null) {
            setState(AppState.Punching)
            return
        }
        // 首次配对路径：发 bind
        signal?.send(JSONObject().put("t", "bind").put("ptok", ptok))
    }

    private fun onPairOk(e: SignalEvent.PairOk) {
        pairId = e.pairId
        turnBlock = e.turn
        // agentId 仅用于日志/显示，pin 校验使用 QR 中的 fp（证书指纹 vs 公钥哈希，不同值）
        setState(AppState.Punching)
    }

    private fun onPunchOffer(e: SignalEvent.PunchOffer) {
        pairId = e.pairId
        handleOffer(e.sdp)
    }

    private fun onRelayAlloc(e: SignalEvent.RelayAlloc) {
        turnBlock = e.turn
    }

    private fun onSignalErrorEvent(code: String, msg: String) {
        // PAIR_REPLACED 总是发给被动方，始终提示重扫
        val isPassive = code == "PAIR_REPLACED"
        onSignalError(state, code, msg, isPassive) { setState(it) }
    }

    // ── WebRTC ──

    private fun handleOffer(offerSdp: String) {
        if (qrFp.isEmpty()) {
            setState(AppState.NeedPair("证书指纹尚未获得"))
            return
        }

        val engine = RtcEngine({ qrFp })
        rtc = engine
        engine.init(getApplication())

        engine.onPinViolation = {
            setState(AppState.NeedPair("证书指纹不匹配，请重新扫码"))
        }
        engine.onTunnelLost = {
            setState(AppState.Reconnecting("tunnel lost"))
        }
        engine.onConnected = {
            onTunnelReady()
        }
        engine.onError = { err -> Log.e(TAG, "RTC: $err") }
        engine.onDataFrame = { bytes -> onDataFrameReceived(bytes) }
        engine.onCtlFrame = { bytes -> onCtlFrameReceived(bytes) }

        engine.handleOffer(offerSdp, buildIceServers())
        engine.createAndSetAnswer()
        pollAnswerReady()
    }

    private fun pollAnswerReady() {
        val e = rtc ?: return
        val sdp = e.answerSdp
        if (sdp != null) {
            signal?.send(JSONObject().put("t", "punch.answer")
                .put("pair_id", pairId)
                .put("sdp", sdp))
            return
        }
        if (state is AppState.NeedPair) return
        handler.postDelayed({ pollAnswerReady() }, 100)
    }

    private fun onTunnelReady() {
        val engine = rtc ?: return
        proxy.senderProvider = { engine.tunnelSender }
        val url = launchToken?.let { "http://$authority/?token=$it" } ?: "http://$authority/"
        // webView.loadUrl 必须在主线程
        handler.post { onNavigate?.invoke(url) }
        setState(AppState.Connected(sinceMs = System.currentTimeMillis()))
    }

    // ── 隧道帧处理 ──

    private fun onDataFrameReceived(frameBytes: ByteArray) {
        try {
            val frame = FrameCodec.decode(frameBytes)
            when (frame.type) {
                Frames.TYPE_DATA -> {
                    val entry = streams[frame.streamId] ?: return
                    val (socket, written) = entry
                    proxy.routeToSocket(socket, frame.payload, written)
                    // WINDOW 回填已在 routeToSocket 内部累加；超阈值后由 ctl 发送
                    if (written.get() >= 64 * 1024) {
                        val delta = written.getAndSet(0)
                        rtc?.sendCtlFrame(Frames.TYPE_WINDOW, frame.streamId,
                            delta.toString().toByteArray())
                    }
                }
                Frames.TYPE_FIN -> {
                    val entry = streams[frame.streamId] ?: return
                    val (socket, _) = entry
                    try { socket.shutdownOutput() } catch (_: Exception) {}
                    // 不发 WINDOW——FIN 后不再接收
                }
                Frames.TYPE_RST -> {
                    val entry = streams.remove(frame.streamId) ?: return
                    try { entry.first.close() } catch (_: Exception) {}
                }
            }
        } catch (_: Exception) {}
    }

    private fun onCtlFrameReceived(frameBytes: ByteArray) {
        try {
            val frame = FrameCodec.decode(frameBytes)
            when (frame.type) {
                Frames.TYPE_WINDOW -> {
                    // 对端回填信用——TunnelSender 内部处理
                    val delta = try { String(frame.payload).toIntOrNull() ?: 0 } catch (_: Exception) { 0 }
                    if (delta > 0) rtc?.tunnelSender?.onSocketWritable(delta)
                }
                Frames.TYPE_RST -> {
                    val entry = streams.remove(frame.streamId) ?: return
                    try { entry.first.close() } catch (_: Exception) {}
                }
                Frames.TYPE_PING -> {
                    // DSH mux 每 2s 发 PING（SKILL §3 fact 17），必须回 PONG 否则 60s 断连
                    rtc?.sendCtlFrame(Frames.TYPE_PONG, frame.streamId, ByteArray(0))
                }
                Frames.TYPE_PONG -> {} // 收到对端 PONG，忽略
            }
        } catch (_: Exception) {}
    }

    // ── ICE 服务器 ──

    private fun buildIceServers(): List<PeerConnection.IceServer> {
        val servers = mutableListOf<PeerConnection.IceServer>()
        servers.add(PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer())
        val tb = turnBlock
        if (tb != null && tb.ttlSec > 300) {
            val uri = tb.uris.firstOrNull() ?: return servers
            servers.add(
                PeerConnection.IceServer.builder(uri)
                    .setUsername(tb.username)
                    .setPassword(tb.credential)
                    .createIceServer(),
            )
        }
        return servers
    }

    // ── 工具 ──

    private fun setState(s: AppState) {
        state = s
        handler.post { onStateChange?.invoke(s) }
    }

    companion object {
        private const val TAG = "AppVM"
    }
}