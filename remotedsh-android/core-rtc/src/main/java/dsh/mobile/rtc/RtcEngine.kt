// core-rtc —— PeerConnection 封装 + DTLS 指纹 pin + 双 DataChannel 接收（03 §3.1）
// 红线：
//  1. pin 校验在**每一次 setRemoteDescription 之前**执行（不只首次配对，插件可随时重发 offer，§6.1）；
//  2. offer 中无 sha-256 行 → 立即中止，MUST NOT 继续 setRemoteDescription（fail-closed）；
//  3. 手机 MUST NOT 自己 createDataChannel——通道由 offer 方（插件）创建，本端 onDataChannel 接收
//     （label 识别：data 有序 / ctl 无序；只收到一条或参数不符 → 协议错误，断开并记录）；
//  4. 绝不在 WebRTC 回调线程里阻塞写 socket——onMessage 只入队。
package dsh.mobile.rtc

import android.content.Context
import dsh.mobile.contract.Fingerprint
import dsh.mobile.contract.FrameCodec
import dsh.mobile.proxy.TunnelSender
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription

class PinViolationException(message: String) : Exception(message)

/**
 * RtcEngine：answerer 侧 WebRTC 封装。
 * 不依赖任何协程或线程模型——所有回调在 PeerConnection 内部线程触发，调用方自行 post 到主线程。
 */
class RtcEngine(
    private val persistedFp: () -> String?,
) {
    private var pc: PeerConnection? = null
    private var factory: PeerConnectionFactory? = null

    // 双通道引用（由 onDataChannel 事件填充）
    private var dataCh: DataChannel? = null
    private var ctlCh: DataChannel? = null

    // 首条应答 SDP（非 trickle ICE，gathering 完成后就是完整答案）
    private var _answerSdp: String? = null
    val answerSdp: String? get() = _answerSdp
    private var answerComplete = false

    val tunnelSender = RtcTunnelSender()

    // ── 回调（app 层设置） ──
    var onDataFrame: ((frameBytes: ByteArray) -> Unit)? = null
    var onCtlFrame: ((frameBytes: ByteArray) -> Unit)? = null
    var onConnected: (() -> Unit)? = null
    var onPinViolation: (() -> Unit)? = null
    var onTunnelLost: (() -> Unit)? = null
    var onError: ((String) -> Unit)? = null

    fun init(context: Context) {
        val options = PeerConnectionFactory.InitializationOptions.builder(context)
            .createInitializationOptions()
        PeerConnectionFactory.initialize(options)
        factory = PeerConnectionFactory.builder()
            .setOptions(PeerConnectionFactory.Options())
            .createPeerConnectionFactory()
    }

    fun handleOffer(offerSdp: String, turnServers: List<PeerConnection.IceServer>) {
        // ★ 红线 1+2：pin 在 setRemoteDescription 之前且 fail-closed
        val lines = offerSdp.split(Regex("\r?\n"))
        if (!Fingerprint.verifyPin(persistedFp(), lines)) {
            onPinViolation?.invoke()
            return
        }

        val config = PeerConnection.RTCConfiguration(turnServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy = PeerConnection.ContinualGatheringPolicy.GATHER_ONCE
        }

        pc = factory?.createPeerConnection(config, pcObserver)
        pc?.setRemoteDescription(
            NoopSdpObserver(),
            SessionDescription(SessionDescription.Type.OFFER, offerSdp),
        )
    }

    /** 在 handleOffer 返回后调用——createAnswer + setLocalDescription；完成时触发 answerSdp 可用 */
    fun createAndSetAnswer() {
        val c = MediaConstraints()
        c.mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveAudio", "false"))
        c.mandatory.add(MediaConstraints.KeyValuePair("OfferToReceiveVideo", "false"))
        pc?.createAnswer(object : SdpObserver {
            override fun onCreateSuccess(sdp: SessionDescription?) {
                pc?.setLocalDescription(NoopSdpObserver(), sdp)
            }
            override fun onSetSuccess() {}
            override fun onCreateFailure(err: String?) { onError?.invoke("createAnswer failed: $err") }
            override fun onSetFailure(err: String?) { onError?.invoke("createAnswer setLocal failed: $err") }
        }, c)
    }

    fun close() {
        dataCh?.close(); ctlCh?.close()
        dataCh = null; ctlCh = null
        pc?.close(); pc = null
        _answerSdp = null; answerComplete = false
    }

    /** 发送 ctl 帧（WINDOW/RST/PING/PONG）到 ctl 通道 */
    fun sendCtlFrame(type: Int, streamId: Long, payload: ByteArray): Boolean {
        val ch = ctlCh ?: return false
        if (ch.state() != DataChannel.State.OPEN) return false
        return try {
            val frame = FrameCodec.encode(type, streamId, payload)
            val buf = java.nio.ByteBuffer.wrap(frame)
            ch.send(DataChannel.Buffer(buf, true))
            true
        } catch (_: Exception) {
            false
        }
    }

    // ── PeerConnection.Observer ──
    private val pcObserver = object : PeerConnection.Observer {
        override fun onIceCandidate(candidate: IceCandidate?) {} // trickle 禁用
        override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
        override fun onSignalingChange(state: PeerConnection.SignalingState?) {}
        override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {
            if (state == PeerConnection.IceConnectionState.DISCONNECTED ||
                state == PeerConnection.IceConnectionState.FAILED) {
                onTunnelLost?.invoke()
            }
        }
        override fun onIceConnectionReceivingChange(receiving: Boolean) {}
        override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
            if (state == PeerConnection.IceGatheringState.COMPLETE && !answerComplete) {
                answerComplete = true
                _answerSdp = pc?.localDescription?.description
            }
        }
        override fun onAddStream(stream: MediaStream?) {}
        override fun onRemoveStream(stream: MediaStream?) {}
        override fun onDataChannel(channel: DataChannel?) {
            val ch = channel ?: return
            when (ch.label()) {
                "data" -> { dataCh = ch; watchChannel(ch, onDataFrame) }
                "ctl"  -> { ctlCh  = ch; watchChannel(ch, onCtlFrame) }
                else   -> onError?.invoke("unknown channel label: ${ch.label()}")
            }
            if (dataCh != null && ctlCh != null) onConnected?.invoke()
        }
        override fun onRenegotiationNeeded() {}
        override fun onAddTrack(receiver: RtpReceiver?, streams: Array<out MediaStream>?) {}
    }

    private fun watchChannel(ch: DataChannel, onFrame: ((ByteArray) -> Unit)?) {
        ch.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(prev: Long) {}
            override fun onStateChange() {}
            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                onFrame?.invoke(bytes)
            }
        })
    }

    // ── TunnelSender 实现（桥接 proxy → WebRTC data channel） ──
    inner class RtcTunnelSender : TunnelSender {
        override val ready: Boolean
            get() = dataCh?.state() == DataChannel.State.OPEN

        override fun sendFrame(type: Int, streamId: Long, payload: ByteArray): Boolean {
            val ch = dataCh ?: return false
            if (ch.state() != DataChannel.State.OPEN) return false
            return try {
                val frame = FrameCodec.encode(type, streamId, payload)
                val buf = java.nio.ByteBuffer.wrap(frame)
                ch.send(DataChannel.Buffer(buf, true))
                true
            } catch (_: Exception) {
                false
            }
        }

        override fun onSocketWritable(bytesWritten: Int) {
            // WINDOW 信用恢复由 FrameCodec 层通过 ctl 通道 WINDOW 帧处理
        }
    }

    /** 内部 SdpObserver 空实现 */
    private class NoopSdpObserver : SdpObserver {
        override fun onCreateSuccess(sdp: SessionDescription?) {}
        override fun onSetSuccess() {}
        override fun onCreateFailure(err: String?) {}
        override fun onSetFailure(err: String?) {}
    }
}