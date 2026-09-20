// a=fingerprint 归一与选取（契约 §6.1 红线，逐字移植 remotedsh-contract/js/fingerprint.mjs）
// 规则：取 hash-func 归一后等于 sha-256 的行（两级冲突 media 级为准）→ 剥前缀 → 删全部冒号与空白 → ASCII 小写 → 按字节比较
// 无 sha-256 行 → fail-closed（返回空串，调用方 MUST 中止，不得继续 setRemoteDescription）
const FP_LINE_RE: RegExp = /^\s*a\s*=\s*fingerprint\s*:\s*(\S+)\s+(.+)$/i

/** 归一单行值：'sha-256 AA:BB:…' → 'aabb…'（64 hex 小写字符）；非 fingerprint 行或非 sha-256 → 空串 */
export function normalizeFingerprintLine(line: string): string {
  const m = FP_LINE_RE.exec(line)
  if (m === null || m.length < 3) {
    return ''
  }
  const hashFunc = m[1].toLowerCase()
  if (hashFunc !== 'sha-256') {
    return ''
  }
  return m[2].replace(/[:\s]+/g, '').toLowerCase()
}

/**
 * 从 offer SDP 行数组中取归一指纹。返回 64 字符小写 hex；无 sha-256 行 → 空串（fail-closed）。
 */
export function extractPinnedFingerprint(offerLines: string[]): string {
  let sessionLevel = ''
  let mediaLevel = ''
  let inMedia = false
  for (const line of offerLines) {
    if (line.startsWith('m=')) {
      inMedia = true
      continue
    }
    const fp = normalizeFingerprintLine(line)
    if (fp === '') {
      continue
    }
    if (inMedia) {
      if (mediaLevel === '') { mediaLevel = fp } // 冲突时以 media 级为准（§6.1）
    } else {
      if (sessionLevel === '') { sessionLevel = fp }
    }
  }
  return mediaLevel !== '' ? mediaLevel : sessionLevel
}

/** pin 校验（契约 §6.1）：persistedFp 与 offer 归一结果按字节比较；任一缺失即不匹配 */
export function verifyPin(persistedFp: string, offerLines: string[]): boolean {
  const offered = extractPinnedFingerprint(offerLines)
  if (offered === '' || persistedFp === '') {
    return false
  }
  return offered === persistedFp.replace(/[:\s]+/g, '').toLowerCase()
}
