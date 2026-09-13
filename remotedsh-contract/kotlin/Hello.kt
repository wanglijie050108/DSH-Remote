// hello 规范化序列化与签名（契约 §4.2）——三端逐字节一致；向量 vectors/hello-signature.json
// 被签名串 = UTF-8 "hello|" + String(ts) + "|" + nonce
// sig = ECDSA P-256/SHA-256：java.security 的 "SHA256withECDSA" 本身输出 ASN.1 DER（§4.2 禁 P1363 满足）
package dsh.mobile.contract

import java.security.KeyFactory
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.PKCS8EncodedKeySpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64

object Hello {
    const val PROTO_VER = "1.0.5" // 契约 §7

    fun canonicalBytes(ts: Long, nonce: String): ByteArray =
        "hello|$ts|$nonce".toByteArray(Charsets.UTF_8) // String(ts) = 十进制 ASCII（无小数/前导零/指数）

    fun sign(privateKey: PrivateKey, ts: Long, nonce: String): String {
        val s = Signature.getInstance("SHA256withECDSA")
        s.initSign(privateKey)
        s.update(canonicalBytes(ts, nonce))
        return Base64.getUrlEncoder().withoutPadding().encodeToString(s.sign())
    }

    fun verify(publicKey: PublicKey, ts: Long, nonce: String, sigB64url: String): Boolean = try {
        val v = Signature.getInstance("SHA256withECDSA")
        v.initVerify(publicKey)
        v.update(canonicalBytes(ts, nonce))
        v.verify(Base64.getUrlDecoder().decode(sigB64url))
    } catch (_: Exception) {
        false
    }

    /** agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1） */
    fun deviceId(publicKey: PublicKey): String {
        val der = publicKey.encoded // X509EncodedKeySpec 形式即 SPKI DER
        val sum = MessageDigest.getInstance("SHA-256").digest(der)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(sum)
    }

    fun privateKeyFromPkcs8Der(der: ByteArray): PrivateKey =
        KeyFactory.getInstance("EC").generatePrivate(PKCS8EncodedKeySpec(der))

    fun publicKeyFromSpkiDer(der: ByteArray): PublicKey =
        KeyFactory.getInstance("EC").generatePublic(X509EncodedKeySpec(der))

    /** 32B 随机 → base64url 无填充（每次 hello 新生成，契约 §4.2） */
    fun randomNonce(): String {
        val b = ByteArray(32)
        SecureRandom().nextBytes(b)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b)
    }
}
