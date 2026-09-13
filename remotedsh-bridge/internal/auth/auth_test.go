// 验签与 TURN 单元测试 —— 直接消费 remotedsh-contract 共享向量（02 §7；G2 门禁）
package auth

import (
	"crypto/ecdsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
)

const vectorsDir = "../../../remotedsh-contract/vectors"

func loadVectors(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(vectorsDir, name))
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	return b
}

func TestHelloVectors(t *testing.T) {
	var v struct {
		Meta struct {
			PrivateKeyPkcs8Pem string `json:"private_key_pkcs8_pem"`
		} `json:"_meta"`
		Cases []struct {
			Name            string `json:"name"`
			Ts              int64  `json:"ts"`
			Nonce           string `json:"nonce"`
			Pub             string `json:"pub"`
			ExpectedMsgHex  string `json:"expected_msg_hex"`
			ExpectedSigB64u string `json:"expected_sig_base64url"`
			ExpectVerify    bool   `json:"expect_verify"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVectors(t, "hello-signature.json"), &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		got := VerifyHello(c.Pub, c.Ts, c.Nonce, c.ExpectedSigB64u)
		if got != c.ExpectVerify {
			t.Errorf("%s: verify = %v, want %v", c.Name, got, c.ExpectVerify)
		}
	}
	// 随机化 ECDSA 自产签名必须可被验证（Go SignASN1 = DER）
	block, _ := pem.Decode([]byte(v.Meta.PrivateKeyPkcs8Pem))
	key, _ := x509.ParsePKCS8PrivateKey(block.Bytes)
	priv := key.(*ecdsa.PrivateKey)
	if !VerifyHello(c0Pub(v), 1770000000, "nonce-go", signForTest(t, priv, 1770000000, "nonce-go")) {
		t.Fatal("Go sign/verify roundtrip failed")
	}
}

func c0Pub(v struct {
	Meta struct {
		PrivateKeyPkcs8Pem string `json:"private_key_pkcs8_pem"`
	} `json:"_meta"`
	Cases []struct {
		Name            string `json:"name"`
		Ts              int64  `json:"ts"`
		Nonce           string `json:"nonce"`
		Pub             string `json:"pub"`
		ExpectedMsgHex  string `json:"expected_msg_hex"`
		ExpectedSigB64u string `json:"expected_sig_base64url"`
		ExpectVerify    bool   `json:"expect_verify"`
	} `json:"cases"`
}) string {
	return v.Cases[0].Pub
}

func signForTest(t *testing.T, priv *ecdsa.PrivateKey, ts int64, nonce string) string {
	t.Helper()
	sig, err := SignWithContract(priv, ts, nonce)
	if err != nil {
		t.Fatal(err)
	}
	return sig
}

func TestCheckTS(t *testing.T) {
	if !CheckTS(nowUnix()) {
		t.Fatal("now should pass")
	}
	if CheckTS(nowUnix() - 61) {
		t.Fatal("-61s should fail")
	}
	if CheckTS(nowUnix() + 61) {
		t.Fatal("+61s should fail")
	}
}

func TestCheckNonceDedup(t *testing.T) {
	h := NewHelloAuth()
	if !h.CheckNonce("n1") {
		t.Fatal("first use must pass")
	}
	if h.CheckNonce("n1") {
		t.Fatal("replay must fail")
	}
	if !h.CheckNonce("n2") {
		t.Fatal("different nonce must pass")
	}
}

func TestPairTokenHash(t *testing.T) {
	h := PairTokenHash("tok")
	// sha256 → base64url 恒 43 字符
	if len(h) != 43 {
		t.Fatalf("len = %d, want 43", len(h))
	}
	if _, err := base64.RawURLEncoding.DecodeString(h); err != nil {
		t.Fatal(err)
	}
}

func TestAllocTurn(t *testing.T) {
	c := AllocTurn("secret-s", "pair-1", "bridge.example.com")
	if len(c.URIs) != 3 || c.URIs[2] != "turn:bridge.example.com:3478?transport=tcp" {
		t.Fatalf("uris = %v", c.URIs)
	}
	if c.TTL != 3600 {
		t.Fatalf("ttl = %d", c.TTL)
	}
	// username 形态 "<expire>:<pair_id>"
	if c.Username[len(c.Username)-len(":pair-1"):] != ":pair-1" {
		t.Fatalf("username = %s", c.Username)
	}
}
