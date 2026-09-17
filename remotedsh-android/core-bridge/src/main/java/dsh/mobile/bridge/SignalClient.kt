// core-bridge —— 信令 WSS 客户端（03 §3.3）：心跳义务、退避重连、封闭集合分发、错误文案矩阵
package dsh.mobile.bridge

import dsh.mobile.contract.PROTO_VER
import dsh.mobile.pairing.DeviceIdentity
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import android.os.Handler
import android.os.Looper
import java.util.concurrent.TimeUnit
import kotlin.math.min
import kotlin.random.Random

/** 连接状态机事件（app 层状态机消费，03 §4） */
sealed class SignalEvent {
    data class HelloOk(val pair: PairSnapshot?, val peerOnline: Boolean) : SignalEvent()
    data class PairOk(val pairId: String, val agentId: String, val turn: TurnBlock) : SignalEvent()
    data class PunchOffer(val pairId: String, val sdp: String) : SignalEvent()
    data class PunchAnswer(val pairId: String, val sdp: String) : SignalEvent()
    data class RelayAlloc(val turn: TurnBlock) : SignalEvent()
    data class Presence(val peerOnline: Boolean) : SignalEvent()
    object ByeFromPeer : SignalEvent()
    object ByeOk : SignalEvent()
    data class Error(val code: String, val msg: String) : SignalEvent()
}

data class PairSnapshot(val pairId: String, val phoneId: String, val agentId: String)
data class TurnBlock(val uris: List<String>, val username: String, val credential: String, val ttlSec: Long)

class SignalClient(
    private val sigURL: String, // 完整端点 wss://host/v1/signal（03 §3.3）
    private val listener: (SignalEvent) -> Unit,
) {
    private val client = OkHttpClient.Builder()
        .pingInterval(0, TimeUnit.MILLISECONDS) // 心跳是应用层 ping/pong（契约 §4），不用 WS 帧
        .build()
    private var ws: WebSocket? = null
    private var heartbeatStarted = false
    private var backoffMs = 500L
    private var closedByUs = false
    private val handler = Handler(Looper.getMainLooper())
    private val connectRunnable = Runnable { connect() }

    fun connect() {
        closedByUs = false
        val request = Request.Builder().url(sigURL).build()
        ws = client.newWebSocket(request, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                backoffMs = 500L
                // hello（契约 §4.1/§4.2）：ts=epoch 秒、nonce 32B→base64url（每次新生成）、sig=DER→base64url
                val ts = System.currentTimeMillis() / 1000
                val nonce = randomNonce()
                val hello = JSONObject().apply {
                    put("t", "hello")
                    put("role", "app")
                    put("pub", DeviceIdentity.publicKeyB64u()) // 漏带必然 AUTH_FAILED
                    put("ts", ts)
                    put("nonce", nonce)
                    put("sig", DeviceIdentity.signHello(ts, nonce))
                    put("proto_ver", PROTO_VER)
                }
                webSocket.send(hello.toString())
                startHeartbeat(webSocket) // 心跳义务：每 25s（不发会被 60s 判离线，03 §3.3）
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                dispatch(JSONObject(text))
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                heartbeatStarted = false
                if (closedByUs) return
                // 指数退避 500ms→30s + 抖动，通过 Handler postDelayed 避免阻塞 OkHttp 回调线程
                handler.removeCallbacks(connectRunnable)
                val delay = backoffMs + Random.nextLong(0, backoffMs / 3)
                backoffMs = min(backoffMs * 2, 30_000L)
                handler.postDelayed(connectRunnable, delay)
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                heartbeatStarted = false
            }
        })
    }

    private fun startHeartbeat(webSocket: WebSocket) {
        if (heartbeatStarted) return
        heartbeatStarted = true
        Thread {
            while (heartbeatStarted) {
                try { webSocket.send(JSONObject().put("t", "ping").toString()) } catch (_: Exception) { break }
                Thread.sleep(25_000)
            }
        }.apply { isDaemon = true }.start()
    }

    private fun dispatch(obj: JSONObject) {
        when (obj.optString("t")) {
            "hello.ok" -> listener(
                SignalEvent.HelloOk(
                    pair = obj.optJSONObject("pair")?.let {
                        PairSnapshot(it.getString("pair_id"), it.getString("phone_id"), it.getString("agent_id"))
                    },
                    peerOnline = obj.optBoolean("peer_online"),
                ),
            )
            "pair.ok" -> {
                val turn = obj.getJSONObject("turn")
                listener(SignalEvent.PairOk(obj.getString("pair_id"), obj.getString("agent_id"), TurnBlock(
                    uris = turn.getJSONArray("uris").let { a -> (0 until a.length()).map { a.getString(it) } },
                    username = turn.getString("username"),
                    credential = turn.getString("credential"),
                    ttlSec = turn.getLong("ttl"),
                )))
            }
            "punch.offer" -> listener(SignalEvent.PunchOffer(obj.getString("pair_id"), obj.getString("sdp")))
            "punch.answer" -> listener(SignalEvent.PunchAnswer(obj.getString("pair_id"), obj.getString("sdp")))
            "relay.alloc" -> {
                val turn = obj.getJSONObject("turn")
                listener(SignalEvent.RelayAlloc(TurnBlock(
                    uris = turn.getJSONArray("uris").let { a -> (0 until a.length()).map { a.getString(it) } },
                    username = turn.getString("username"),
                    credential = turn.getString("credential"),
                    ttlSec = turn.getLong("ttl"),
                )))
            }
            "presence" -> listener(SignalEvent.Presence(obj.getBoolean("peer_online")))
            "bye" -> listener(SignalEvent.ByeFromPeer)
            "bye.ok" -> listener(SignalEvent.ByeOk)
            "pong" -> {}
            "error" -> listener(SignalEvent.Error(obj.getString("code"), obj.optString("msg")))
            else -> {} // Bridge 是封闭集合执行者，客户端忽略未知 t
        }
    }

    fun send(obj: JSONObject) { ws?.send(obj.toString()) }

    /** 本端主动解除：发 bye{user} 后由 app 层等 bye.ok（超时 2s），不得只清本地状态（03 §3.3） */
    fun sendBye() {
        send(JSONObject().put("t", "bye").put("reason", "user"))
    }

    fun close() {
        closedByUs = true
        heartbeatStarted = false
        handler.removeCallbacks(connectRunnable)
        ws?.close(1000, "client close")
    }

    private fun randomNonce(): String {
        val b = ByteArray(32)
        java.security.SecureRandom().nextBytes(b)
        return android.util.Base64.encodeToString(b, android.util.Base64.NO_WRAP or android.util.Base64.NO_PADDING or android.util.Base64.URL_SAFE)
    }
}
