// core-rtc —— PeerConnection 封装 + DTLS 指纹 pin + 双 DataChannel 接收（03 §3.1）
// 红线：
//  1. pin 校验在**每一次 setRemoteDescription 之前**执行（不只首次配对——插件可随时重发 offer，§6.1）；
//  2. offer 中无 sha-256 行 → 立即中止，MUST NOT 继续 setRemoteDescription（fail-closed）；
//  3. 手机 MUST NOT 自己 createDataChannel——通道由 offer 方（插件）创建，本端 onDataChannel 接收两条
//     （label 识别：data 有序 / ctl 无序；只收到一条或参数不符 → 协议错误，断开并记录）；
//  4. 绝不在 WebRTC 回调线程里阻塞写 socket——onMessage 只入队。
package dsh.mobile.rtc

import dsh.mobile.contract.Fingerprint
import dsh.mobile.contract.Frame
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import io.getstream.webrtc.RoomPeerConnection // 占位导入；实际以 stream-webrtc-android 的 org.webrtc 门面为准（W1 验证）

class PinViolationException(message: String) : Exception(message)

/**
 * RtcEngine：answerer 侧封装。
 * @param persistedFp 本地持久化的插件证书指纹（§3.3 存储清单；不得与"内存里的 QR 内容"比较）
 */
class RtcEngine(private val persistedFp: () -> String?) {

    /** 每次 offer 到达时调用；返回 true 才允许继续 setRemoteDescription */
    fun verifyPin(offerSdp: String): Boolean {
        val lines = offerSdp.split(Regex("\r?\n"))
        if (!Fingerprint.verifyPin(persistedFp(), lines)) {
            throw PinViolationException("对端身份校验失败（fail-closed，§6.1）")
        }
        return true
    }

    /**
     * 处理 punch.offer：
     * 1. pin 校验（红线）→ 2. setRemoteDescription → 3. createAnswer → punch.answer
     * 数据通道由 onDataChannel 接收（MUST NOT createDataChannel）。
     */
    suspend fun onOffer(peer: RoomPeerConnection, offerSdp: String, onAnswer: (String) -> Unit) {
        verifyPin(offerSdp) // ★ 校验失败直接抛出，绝不 setRemoteDescription
        peer.setRemoteDescription(offerSdp)
        val answer = peer.createAnswer()
        peer.setLocalDescription(answer)
        onAnswer(answer)
    }

    /**
     * 通道就绪判定：label 识别（契约 §3 v1.0.4）。收到两条（data/ctl）且参数符合才回调 onReady。
     * 只收到一条或 label 不符 → 协议错误 → onProtocolError。
     */
    fun observeChannels(
        scope: CoroutineScope,
        onChannel: (label: String, frame: Frame) -> Unit,
        onReady: (dataChannel: Any, ctlChannel: Any) -> Unit,
        onProtocolError: (String) -> Unit,
    ) {
        val labels = mutableSetOf<String>()
        // 具体 onDataChannel 接线在 W1 后按 stream-webrtc-android API 落定：
        // peer.onDataChannel = { channel ->
        //     when (channel.label()) {
        //         "data" -> { /* ordered=true 可靠 */ }
        //         "ctl"  -> { /* ordered=false 可靠 */ }
        //         else   -> onProtocolError("unknown channel label")
        //     }
        // }
        scope.launch(Dispatchers.Default) { /* 通道到达计时：5s 未集齐两条 → onProtocolError("incomplete channels") */ }
    }
}
