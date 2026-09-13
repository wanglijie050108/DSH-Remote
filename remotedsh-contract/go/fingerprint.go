// a=fingerprint 归一与选取（契约 §6.1，逐字实现；RFC 8122 §5.1 多行）
// 无 sha-256 行 → fail-closed（返回 ""，调用方 MUST 中止，不得继续 SetRemoteDescription）
package contract

import "strings"

// NormalizeFingerprintLine：'a=fingerprint:sha-256 AA:BB:…' → 'aabb…'（64 hex 小写）或 ""
func NormalizeFingerprintLine(line string) string {
	rest, ok := strings.CutPrefix(strings.TrimSpace(line), "a=fingerprint:")
	if !ok {
		// 容忍 'a= fingerprint:' 的空白变体极罕见；按 §6.1 严格前缀处理即可
		return ""
	}
	sp := strings.IndexAny(rest, " \t")
	if sp < 0 {
		return ""
	}
	hashFunc := strings.ToLower(rest[:sp])
	if hashFunc != "sha-256" {
		return ""
	}
	value := rest[sp+1:]
	var b strings.Builder
	for _, r := range value {
		switch {
		case r == ':' || r == ' ' || r == '\t':
			// 删全部冒号与空白
		case r >= 'A' && r <= 'Z':
			b.WriteRune(r + 32) // ASCII 小写
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// ExtractPinnedFingerprint：从 offer SDP 行中取归一指纹。
// 多行时取 sha-256 行；两级冲突以 media 级为准；media 无则取 session 级；都没有 → ""（fail-closed）。
func ExtractPinnedFingerprint(offerLines []string) string {
	var session, media string
	inMedia := false
	for _, line := range offerLines {
		if strings.HasPrefix(line, "m=") {
			inMedia = true
			continue
		}
		fp := NormalizeFingerprintLine(line)
		if fp == "" {
			continue
		}
		if inMedia {
			if media == "" {
				media = fp
			}
		} else if session == "" {
			session = fp
		}
	}
	if media != "" {
		return media
	}
	return session // 无 sha-256 行时为 ""
}

// VerifyPin：与本地持久化 fp 按字节比较（§6.1：不是与内存里的 QR 内容比较）
func VerifyPin(persistedFp string, offerLines []string) bool {
	offered := ExtractPinnedFingerprint(offerLines)
	if offered == "" || persistedFp == "" {
		return false
	}
	norm := strings.ToLower(strings.Map(func(r rune) rune {
		if r == ':' || r == ' ' || r == '\t' {
			return -1
		}
		return r
	}, persistedFp))
	return offered == norm
}
