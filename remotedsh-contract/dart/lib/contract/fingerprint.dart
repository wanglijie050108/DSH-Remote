// a=fingerprint 归一与选取（契约 §6.1 红线，逐字实现）—— 自 js/fingerprint.mjs 移植
// 规则：取 hash-func 归一后等于 sha-256 的行（两级冲突 media 级为准）→ 剥前缀 → 删全部冒号与空白
// → ASCII 小写 → 按字节比较；无 sha-256 行 → fail-closed（返回 null，调用方 MUST 中止）
final _fpLineRe =
    RegExp(r'^\s*a\s*=\s*fingerprint\s*:\s*(\S+)\s+(.+)$', caseSensitive: false);
final _colonWsRe = RegExp(r'[:\s]+');

/// 归一单行值：'sha-256 AA:BB:…' → 'aabb…'（64 hex 小写字符）或 null
String? normalizeFingerprintLine(String line) {
  final m = _fpLineRe.firstMatch(line);
  if (m == null) return null;
  final hashFunc = m.group(1)!.toLowerCase(); // 'SHA-256' → 'sha-256'
  if (hashFunc != 'sha-256') return null;
  return m.group(2)!.replaceAll(_colonWsRe, '').toLowerCase(); // 删冒号与空白 → 小写
}

/// 从 offer SDP 中取归一指纹。返回 64 字符小写 hex，或 null（fail-closed）。
/// offerLines：SDP 行数组（已按 \r?\n 切分）
String? extractPinnedFingerprint(List<String> offerLines) {
  String? sessionLevel;
  String? mediaLevel;
  var inMedia = false;
  for (final line in offerLines) {
    if (line.startsWith('m=')) {
      inMedia = true;
      continue;
    }
    final fp = normalizeFingerprintLine(line);
    if (fp == null) continue;
    if (inMedia) {
      mediaLevel ??= fp; // 冲突时以 media 级为准（§6.1）
    } else {
      sessionLevel ??= fp;
    }
  }
  return mediaLevel ?? sessionLevel; // 无 sha-256 行 → null（fail-closed）
}

/// pin 校验（契约 §6.1）：persistedFp 与 offer 归一结果按字节比较；任一缺失即不匹配
bool verifyPin(String? persistedFp, List<String> offerLines) {
  final offered = extractPinnedFingerprint(offerLines);
  if (offered == null || persistedFp == null || persistedFp.isEmpty) return false;
  return offered == persistedFp.replaceAll(_colonWsRe, '').toLowerCase();
}
