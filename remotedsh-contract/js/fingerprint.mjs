// a=fingerprint 归一与选取（契约 §6.1 红线，逐字实现；RFC 8122 §5.1 多行）
// 规则：取 hash-func 归一后等于 sha-256 的行（两级冲突 media 级为准）→ 剥前缀 → 删全部冒号与空白 → ASCII 小写 → 按字节比较
// 无 sha-256 行 → fail-closed（返回 null，调用方 MUST 中止，不得继续 setRemoteDescription）

/** 归一单行值：'sha-256 AA:BB:…' → 'aabb…'（64 hex 小写字符）或 null */
export function normalizeFingerprintLine(line) {
  const m = /^\s*a\s*=\s*fingerprint\s*:\s*(\S+)\s+(.+)$/i.exec(line)
  if (!m) return null
  const hashFunc = m[1].toLowerCase() // 'SHA-256' → 'sha-256'
  if (hashFunc !== 'sha-256') return null
  return m[2].replace(/[:\s]+/g, '').toLowerCase() // 删全部冒号与空白 → ASCII 小写
}

/**
 * 从 offer SDP 中取归一指纹。返回 64 字符小写 hex，或 null（fail-closed）。
 * offerLines: SDP 行数组（已按 \r?\n 切分）
 */
export function extractPinnedFingerprint(offerLines) {
  let sessionLevel = null
  let mediaLevel = null
  let inMedia = false
  for (const line of offerLines) {
    if (/^m=/.test(line)) { inMedia = true; continue }
    const fp = normalizeFingerprintLine(line)
    if (fp === null) continue
    if (inMedia) mediaLevel = mediaLevel ?? fp // 冲突时以 media 级为准（§6.1）
    else sessionLevel = sessionLevel ?? fp
  }
  const picked = mediaLevel ?? sessionLevel // 优先 media 级；media 无指纹时取 session 级的 sha-256 行
  return picked ?? null // 无 sha-256 行 → fail-closed
}

/** pin 校验（契约 §6.1）：persistedFp 与 offer 归一结果按字节比较；任一缺失即不匹配 */
export function verifyPin(persistedFp, offerLines) {
  const offered = extractPinnedFingerprint(offerLines)
  if (!offered || !persistedFp) return false
  return offered === String(persistedFp).replace(/[:\s]+/g, '').toLowerCase()
}
