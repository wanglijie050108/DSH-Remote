// dshlink://pair QR 解析（契约 §2）与 TURN 凭证（契约 §5）
package dsh.mobile.contract

import android.net.Uri
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

data class PairQR(
    val v: Int,
    val s: String,  // 信令完整端点 wss://host/v1/signal
    val pt: String, // pair_token
    val fp: String, // 插件证书指纹
    val a: String,  // authority，恒 127.0.0.1:13080
    val t: String?, // 可选 launch token
)

object PairQRCodec {
    fun parse(uri: String): PairQR? {
        val u = try { Uri.parse(uri) } catch (_: Exception) { return null }
        if (u.scheme != "dshlink" || u.host != "pair") return null
        val v = u.getQueryParameter("v") ?: return null
        if (v != "1") return null // v1 只支持 v=1
        val s = u.getQueryParameter("s") ?: return null
        val pt = u.getQueryParameter("pt") ?: return null
        val fp = u.getQueryParameter("fp") ?: return null
        val a = u.getQueryParameter("a") ?: return null
        if (!s.startsWith("wss://")) return null // §2 完整端点
        return PairQR(1, s, pt, fp, a, u.getQueryParameter("t"))
    }
}

object TurnCreds {
    const val TTL_SECONDS = 3600 // 契约 §5

    fun username(pairId: String, ttlSeconds: Long = TTL_SECONDS, nowSec: Long): String =
        "${nowSec + ttlSeconds}:$pairId"

    fun credential(secret: String, username: String): String {
        val mac = Mac.getInstance("HmacSHA1")
        mac.init(SecretKeySpec(secret.toByteArray(Charsets.UTF_8), "HmacSHA1"))
        return android.util.Base64.encodeToString(mac.doFinal(username.toByteArray(Charsets.UTF_8)), android.util.Base64.NO_WRAP)
    }

    fun uris(host: String): List<String> = listOf(
        "stun:$host:3478",
        "turn:$host:3478?transport=udp",
        "turn:$host:3478?transport=tcp", // UDP 被封网络的兜底（§5）
    )
}
