// core-pairing —— QR 解析、Keystore 签名、配对状态存储（03 §3.3）
// 存储清单（必须完整）：sigURL / authority / fp（pin 红线依赖）/ agentId（仅显示）/ TURN 凭证+到期 / Keystore 别名
// 不存：ptok（用后即弃）、任何 DSH cookie（归 WebView CookieManager，HttpOnly 也读不到）
package dsh.mobile.pairing

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import dsh.mobile.contract.PairQR
import dsh.mobile.contract.PairQRCodec
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.spec.ECGenParameterSpec

/** 设备身份：Android Keystore P-256（硬件后备、不可导出），hello 签名用（契约 §6） */
object DeviceIdentity {
    private const val ANDROID_KEYSTORE = "AndroidKeyStore"
    const val ALIAS = "dsh-mobile-link-device"

    private fun keyStore(): KeyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }

    fun ensureKey() {
        if (keyStore().containsAlias(ALIAS)) return
        val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, ANDROID_KEYSTORE)
        kpg.initialize(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256)
                .build(),
        )
        kpg.generateKeyPair()
    }

    /** 公钥 SPKI DER → base64url（hello.pub；漏带必然 AUTH_FAILED，03 §3.3） */
    fun publicKeyB64u(): String {
        val pub = keyStore().getCertificate(ALIAS).publicKey.encoded
        return Base64.encodeToString(pub, Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
    }

    /** hello 签名：ECDSA P-256/SHA-256，Keystore 输出即 DER → base64url（§4.2 禁 P1363 天然满足） */
    fun signHello(ts: Long, nonce: String): String {
        val sig = Signature.getInstance("SHA256withECDSA")
        sig.initSign(keyStore().getKey(ALIAS, null) as java.security.PrivateKey)
        sig.update("hello|$ts|$nonce".toByteArray(Charsets.UTF_8)) // 被签字节串（§4.2，String(ts) 为十进制 ASCII）
        return Base64.encodeToString(sig.sign(), Base64.NO_WRAP or Base64.NO_PADDING or Base64.URL_SAFE)
    }
}

/** 配对状态（EncryptedFile / DataStore 落地由 app 层组装；本类定义清单与读写接口） */
data class PairingState(
    val sigURL: String?,      // 重连信令地址（完整端点）
    val authority: String?,   // 恒 127.0.0.1:13080
    val fp: String?,          // ★ 插件证书指纹：免扫码重连的 pin 依赖（不存则 App 重启后无法校验）
    val agentId: String?,     // 显示/日志/多设备预留（不参与校验，§6.2）
    val turnUris: List<String>?, // iceServers：免扫码重连与新 gather 都需要（只从 pair.ok 取不持久化 → iceServers 为空）
    val turnUsername: String?,
    val turnCredential: String?,
    val turnExpireAtMs: Long?,
    val keyAlias: String = DeviceIdentity.ALIAS,
) {
    /** TURN 凭证剩余 TTL < 300s 视为无效（契约 §5 统一阈值） */
    fun turnValid(nowMs: Long): Boolean =
        turnUris != null && turnUsername != null && turnCredential != null &&
            turnExpireAtMs != null && turnExpireAtMs - nowMs > 300_000
}

class QrParseException(message: String) : Exception(message)

/** 扫码入口：解析 dshlink://pair 并校验必填字段（契约 §2） */
fun parseScannedQr(uri: String): PairQR {
    val qr = PairQRCodec.parse(uri) ?: throw QrParseException("无法识别的二维码（需要 dshlink://pair）")
    if (qr.a != "127.0.0.1:13080") throw QrParseException("authority 与契约固定值不符：${qr.a}")
    return qr
}
