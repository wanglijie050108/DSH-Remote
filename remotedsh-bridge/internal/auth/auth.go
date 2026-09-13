// Package auth：hello 验签、pair_token 校验、TURN 凭证签发（02 §3.2，契约 §4.2/§5）
// 验签复用 remotedsh-contract/go（与 JS/Kotlin 共用同一批共享向量，G2 门禁）。
package auth

import (
	"crypto/ecdsa"
	"crypto/sha256"
	"encoding/base64"
	"sync"
	"time"

	contract "remotedsh-contract/go"
)

// HelloAuth：hello 门禁②③④（ts 时间窗、nonce 去重、验签）——proto_ver 由 hub 先行校验（顺序见 02 §3.2）
type HelloAuth struct {
	NonceWindow time.Duration // MUST ≥ 120s（§4.1：验签窗 ±60s + 时钟偏移）

	mu    sync.Mutex
	nonce map[string]time.Time
}

func NewHelloAuth() *HelloAuth {
	return &HelloAuth{NonceWindow: 130 * time.Second, nonce: make(map[string]time.Time)}
}

// CheckNonce：去重窗口 ≥120s（契约 §4.1 MUST；窗口内的 nonce 只接受一次）
func (h *HelloAuth) CheckNonce(nonce string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	now := time.Now()
	if _, ok := h.nonce[nonce]; ok {
		return false // 重放
	}
	h.nonce[nonce] = now
	for k, at := range h.nonce {
		if now.Sub(at) > h.NonceWindow {
			delete(h.nonce, k)
		}
	}
	return true
}

// VerifyHello：按契约 §4.2 的规范化字节串验证（pub 为 SPKI DER base64url）
func VerifyHello(pubB64u string, ts int64, nonce, sigB64url string) bool {
	pub, err := base64.RawURLEncoding.DecodeString(pubB64u)
	if err != nil {
		return false
	}
	return contract.VerifyHello(pub, ts, nonce, sigB64url)
}

// DeviceID：agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1）
func DeviceID(pubB64u string) (string, error) {
	pub, err := base64.RawURLEncoding.DecodeString(pubB64u)
	if err != nil {
		return "", err
	}
	return contract.DeviceID(pub), nil
}

// CheckTS：时间窗 ±60s（02 §3.2 校验顺序②）
func CheckTS(ts int64) bool {
	d := time.Now().Unix() - ts
	if d < 0 {
		d = -d
	}
	return d <= 60
}

// PairTokenHash：sha256(pair_token) → base64url（§4.1：pair.ready 只传 hash，Bridge 只存 hash）
func PairTokenHash(ptok string) string {
	sum := sha256.Sum256([]byte(ptok))
	return base64.RawURLEncoding.EncodeToString(sum[:])
}

// AllocTurn：TURN 凭证签发（契约 §5：username="<expire>:<pair_id>"，credential=base64(HMAC-SHA1(S, username))）
// 两端拿到的是同一个 coturn 用户名；签发新凭证不延长已有 allocation（§5「续期」语义红线）
func AllocTurn(secret, pairID, host string) contract.TurnCredentials {
	return contract.AllocTurn(secret, pairID, host, contract.TurnTTLSeconds, time.Now())
}

// SignWithContract：仅测试用（Go 标准库随机化 ECDSA；向量复现走 @noble，见 remotedsh-contract README）
func SignWithContract(priv *ecdsa.PrivateKey, ts int64, nonce string) (string, error) {
	return contract.SignHello(priv, ts, nonce)
}

func nowUnix() int64 { return time.Now().Unix() }