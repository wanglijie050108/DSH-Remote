// a=fingerprint 归一与选取（契约 §6.1 红线，逐字实现）
// 无 sha-256 行 → fail-closed（返回 null，调用方 MUST 中止，不得继续 setRemoteDescription）
package dsh.mobile.contract

object Fingerprint {
    private val LINE = Regex("""^\s*a\s*=\s*fingerprint\s*:\s*(\S+)\s+(.+)$""", RegexOption.IGNORE_CASE)

    /** 'a=fingerprint:sha-256 AA:BB:…' → 'aabb…'（64 hex 小写）或 null */
    fun normalizeLine(line: String): String? {
        val m = LINE.find(line) ?: return null
        val hashFunc = m.groupValues[1].lowercase() // 'SHA-256' → 'sha-256'
        if (hashFunc != "sha-256") return null
        return m.groupValues[2].replace(Regex("[:\\s]+"), "").lowercase()
    }

    /**
     * 从 offer SDP 行中取归一指纹。
     * 多行时取 sha-256 行；两级冲突以 media 级为准；media 无则取 session 级；都没有 → null（fail-closed）。
     */
    fun extract(offerLines: List<String>): String? {
        var session: String? = null
        var media: String? = null
        var inMedia = false
        for (line in offerLines) {
            if (line.startsWith("m=")) { inMedia = true; continue }
            val fp = normalizeLine(line) ?: continue
            if (inMedia) { if (media == null) media = fp } else if (session == null) session = fp
        }
        return media ?: session
    }

    /** pin 校验（§6.1）：与本地持久化 fp 按字节比较；任一缺失 → false */
    fun verifyPin(persistedFp: String?, offerLines: List<String>): Boolean {
        val offered = extract(offerLines) ?: return false
        if (persistedFp.isNullOrBlank()) return false
        val norm = persistedFp.replace(Regex("[:\\s]+"), "").lowercase()
        return offered == norm
    }
}
