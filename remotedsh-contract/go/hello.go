// hello 规范化序列化与验签（契约 §4.2）——与 js/hello.mjs、kotlin/Hello.kt 共用同一批向量
// 被签名串 = UTF-8 "hello|" + String(ts) + "|" + nonce；sig = ECDSA P-256/SHA-256，ASN.1 DER
package contract

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"fmt"
)

const ProtoVer = "1.0.5" // 契约 §7（§4.1：Bridge 严格校验）

// CanonicalBytes：Go 的 strconv.FormatInt 即十进制 ASCII（无小数/前导零/指数，契约 §4.2）
func CanonicalBytes(ts int64, nonce string) []byte {
	if ts < 0 {
		panic("ts must be epoch seconds ≥ 0")
	}
	return []byte(fmt.Sprintf("hello|%d|%s", ts, nonce))
}

func SignHello(priv *ecdsa.PrivateKey, ts int64, nonce string) (string, error) {
	digest := sha256.Sum256(CanonicalBytes(ts, nonce))
	sig, err := ecdsa.SignASN1(rand.Reader, priv, digest[:])
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(sig), nil
}

// VerifyHello：pub 为 SPKI DER；sigB64url 为 DER 签名（§4.2 禁 P1363——SignASN1/VerifyASN1 即 DER）。
func VerifyHello(pubSPKIDER []byte, ts int64, nonce, sigB64url string) bool {
	pubAny, err := x509.ParsePKIXPublicKey(pubSPKIDER)
	if err != nil {
		return false
	}
	pub, ok := pubAny.(*ecdsa.PublicKey)
	if !ok || pub.Curve != elliptic.P256() {
		return false
	}
	sig, err := base64.RawURLEncoding.DecodeString(sigB64url)
	if err != nil {
		return false
	}
	digest := sha256.Sum256(CanonicalBytes(ts, nonce))
	return ecdsa.VerifyASN1(pub, digest[:], sig)
}

// DeviceID：agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1）
func DeviceID(pubSPKIDER []byte) string {
	sum := sha256.Sum256(pubSPKIDER)
	return base64.RawURLEncoding.EncodeToString(sum[:])
}
