// dshlink://pair QR 载荷（契约 §2）——与 js/qr-pair.mjs 解析行为完全一致
package dsh.mobile.contract

data class PairQR(
    val v: Int,       // QR version（v1 = 1）
    val s: String,    // signal URL（wss://host/v1/signal）
    val pt: String,   // pair token（base64url, 43 chars）
    val fp: String,   // 插件证书 sha-256 指纹（hex, 用于 DTLS pin）
    val a: String,    // authority（恒 127.0.0.1:13080）
    val t: String?,   // launch token（可选，DSH /web 生成的带 token QR）
)

object PairQRCodec {
    /** 解析 dshlink://pair?... URI；失败返回 null（契约 §2） */
    fun parse(uri: String): PairQR? {
        val u = try { java.net.URI(uri) } catch (_: Exception) { return null }
        if (u.scheme != "dshlink" || u.host != "pair") return null
        val q = u.query ?: return null
        val params = mutableMapOf<String, String>()
        for (part in q.split("&")) {
            val eq = part.indexOf('=')
            if (eq > 0) params[part.substring(0, eq)] = part.substring(eq + 1)
        }
        val v = params["v"]?.toIntOrNull() ?: return null
        if (v != 1) return null // v1 only
        val s = params["s"] ?: return null
        if (!(s.startsWith("wss://") || s.startsWith("ws://"))) return null
        val pt = params["pt"] ?: return null
        val fp = params["fp"] ?: return null
        val a = params["a"] ?: return null
        return PairQR(v, s, pt, fp, a, params["t"])
    }
}