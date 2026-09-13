// G2 门禁（docs/05 §2）：Kotlin 侧消费与 JS/Go 同一份共享向量。
// 位于 remotedsh-contract/kotlin；remotedsh-android 的 core-contract 模块以源码方式引入本目录（03 §3）。
// 注：android.util.Base64 在 JVM 单测中不可用，TurnCreds.credential 的单测由 androidTest 承担；
//     本文件覆盖 Frames / Hello / Fingerprint / QR 解析（QrPair.parse 用 android.net.Uri，同样归 androidTest）。
package dsh.mobile.contract

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files
import java.nio.file.Paths
import java.util.Base64

class VectorsTest {
    private fun vector(name: String): JSONObject = JSONObject(
        Files.readString(Paths.get("..", "vectors", name)),
    )

    // ---------- hello（契约 §4.2） ----------
    @Test
    fun helloCanonicalBytes() {
        val v = vector("hello-signature.json")
        val cases = v.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            if (!c.has("expected_msg_hex")) continue
            val got = Hello.canonicalBytes(c.getLong("ts"), c.getString("nonce"))
            val want = hex(c.getString("expected_msg_hex"))
            assertTrue(c.getString("name"), got.contentEquals(want))
        }
    }

    @Test
    fun helloVerifyVectors() {
        val v = vector("hello-signature.json")
        val priv = Hello.privateKeyFromPkcs8Der(
            pemBody(v.getJSONObject("_meta").getString("private_key_pkcs8_pem")),
        )
        val cases = v.getJSONArray("cases")
        // 向量公钥取自正例自带 pub（SPKI DER → base64url）；Kotlin 自产签名用同钥自验
        val pubDer = Base64.getUrlDecoder().decode(cases.getJSONObject(0).getString("pub"))
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val pub = if (c.getString("name") == "wrong pub key") {
                Base64.getUrlDecoder().decode(c.getString("pub"))
            } else pubDer
            val got = Hello.verify(Hello.publicKeyFromSpkiDer(pub), c.getLong("ts"), c.getString("nonce"), c.getString("expected_sig_base64url"))
            assertEquals(c.getString("name"), c.getBoolean("expect_verify"), got)
        }
        // Kotlin 自产签名（随机化 ECDSA）：自验证通过，且为 DER ≤72B
        val sig = Hello.sign(priv, 1770000000L, "nonce-from-kotlin")
        assertTrue(Hello.verify(Hello.publicKeyFromSpkiDer(pubDer), 1770000000L, "nonce-from-kotlin", sig))
        val der = Base64.getUrlDecoder().decode(sig)
        assertTrue(der[0] == 0x30.toByte() && der.size <= 72)
    }

    // ---------- 帧向量（契约 §3.1–§3.3） ----------
    @Test
    fun framesVectors() {
        val v = vector("frames.json")
        val types = v.getJSONObject("types")
        val cases = v.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            if (!c.has("frame_hex") || c.isNull("frame_hex")) {
                // construct 负例：len 超限走 encode 防线
                if (c.has("construct") && !c.isNull("construct")) {
                    val ctor = c.getJSONObject("construct")
                    try {
                        FrameCodec.encode(types.getInt("DATA"), ctor.getLong("stream_id"), ByteArray(ctor.getInt("payload_len")))
                        throw AssertionError("${c.getString("name")}: expected LEN_OVERFLOW")
                    } catch (e: FrameException) {
                        assertEquals("LEN_OVERFLOW", e.code)
                    }
                }
                continue
            }
            val bytes = hex(c.getString("frame_hex"))
            try {
                val f = FrameCodec.decode(bytes)
                if (c.has("decode_error") && !c.isNull("decode_error")) {
                    throw AssertionError("${c.getString("name")}: expected ${c.getString("decode_error")}, decoded fine")
                }
                val d = c.getJSONObject("decode")
                if (d.has("type_code") && !d.isNull("type_code")) {
                    assertEquals(c.getString("name"), d.getInt("type_code"), f.type)
                } else if (d.has("type")) {
                    assertEquals(c.getString("name"), types.getInt(d.getString("type")), f.type)
                }
                val wantFlags = if (d.has("flags_read_as") && !d.isNull("flags_read_as")) d.getInt("flags_read_as") else d.optInt("flags")
                assertEquals(c.getString("name"), wantFlags, f.flags)
                val wantStream = if (d.has("stream_id_read_as") && !d.isNull("stream_id_read_as")) d.getLong("stream_id_read_as") else d.optLong("stream_id")
                assertEquals(c.getString("name"), wantStream, f.streamId)
                if (d.has("payload_hex") && !d.isNull("payload_hex")) {
                    assertTrue(c.getString("name"), f.payload.contentEquals(hex(d.getString("payload_hex"))))
                }
                if (d.has("payload_utf8") && !d.isNull("payload_utf8")) {
                    assertEquals(c.getString("name"), d.getString("payload_utf8"), String(f.payload, Charsets.UTF_8))
                }
                if (d.has("payload_len") && !d.isNull("payload_len")) {
                    assertEquals(c.getString("name"), d.getInt("payload_len"), f.payload.size)
                }
            } catch (e: FrameException) {
                if (!(c.has("decode_error") && !c.isNull("decode_error"))) throw AssertionError("${c.getString("name")}: unexpected ${e.code}", e)
                assertEquals(c.getString("name"), c.getString("decode_error"), e.code)
            }
        }
    }

    // ---------- fingerprint（契约 §6.1） ----------
    @Test
    fun fingerprintVectors() {
        val v = vector("fingerprint-normalize.json")
        val cases = v.getJSONArray("cases")
        for (i in 0 until cases.length()) {
            val c = cases.getJSONObject(i)
            val lines = mutableListOf<String>()
            val arr = c.getJSONArray("offer_lines")
            for (j in 0 until arr.length()) lines.add(arr.getString(j))
            val got = Fingerprint.extract(lines)
            if (c.isNull("expect")) assertNull(c.getString("name"), got)
            else assertEquals(c.getString("name"), c.getString("expect"), got)
        }
    }

    private fun hex(s: String): ByteArray {
        val out = ByteArray(s.length / 2)
        for (i in out.indices) out[i] = s.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        return out
    }

    private fun pemBody(pem: String): ByteArray =
        Base64.getMimeDecoder().decode(pem.replace(Regex("-----(BEGIN|END) PRIVATE KEY-----"), "").trim())
}
