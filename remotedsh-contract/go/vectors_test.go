// G2 门禁（docs/05 §2）：Go 侧消费与 JS/Kotlin 同一份共享向量。
// 运行：cd go && go test ./...
package contract

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const vectorsDir = "../vectors"

func loadVector(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(vectorsDir, name))
	if err != nil {
		t.Fatalf("load %s: %v", name, err)
	}
	return b
}

// ---------- hello 签名向量（契约 §4.2） ----------

func TestHelloCanonicalBytes(t *testing.T) {
	var v struct {
		Cases []struct {
			Name            string `json:"name"`
			Ts              int64  `json:"ts"`
			Nonce           string `json:"nonce"`
			ExpectedMsgHex  string `json:"expected_msg_hex"`
			ExpectVerify    bool   `json:"expect_verify"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVector(t, "hello-signature.json"), &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		if c.ExpectedMsgHex == "" {
			continue
		}
		got := CanonicalBytes(c.Ts, c.Nonce)
		want, _ := hexDecode(c.ExpectedMsgHex)
		if !bytes.Equal(got, want) {
			t.Errorf("%s: canonical bytes mismatch", c.Name)
		}
	}
}

func TestHelloVerifyVectors(t *testing.T) {
	var v struct {
		Meta struct {
			PrivateKeyPkcs8Pem string `json:"private_key_pkcs8_pem"`
		} `json:"_meta"`
		Cases []struct {
			Name             string `json:"name"`
			Ts               int64  `json:"ts"`
			Nonce            string `json:"nonce"`
			Pub              string `json:"pub"`
			ExpectedMsgHex   string `json:"expected_msg_hex"`
			ExpectedSigB64u  string `json:"expected_sig_base64url"`
			ExpectVerify     bool   `json:"expect_verify"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVector(t, "hello-signature.json"), &v); err != nil {
		t.Fatal(err)
	}
	// 向量密钥：PKCS8 PEM → ecdsa 私钥（Go 标准库随机化 ECDSA：只验证向量签名，不复现 RFC 6979）
	block, _ := pem.Decode([]byte(v.Meta.PrivateKeyPkcs8Pem))
	if block == nil {
		t.Fatal("bad test key PEM")
	}
	keyAny, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	priv := keyAny.(*ecdsa.PrivateKey)
	pubDER, _ := x509.MarshalPKIXPublicKey(&priv.PublicKey)

	for _, c := range v.Cases {
		pub := pubDER
		if c.Name == "wrong pub key" {
			pub, _ = base64.RawURLEncoding.DecodeString(c.Pub)
		}
		got := VerifyHello(pub, c.Ts, c.Nonce, c.ExpectedSigB64u)
		if got != c.ExpectVerify {
			t.Errorf("%s: verify = %v, want %v", c.Name, got, c.ExpectVerify)
		}
	}
	// Go 自产签名：DER（SignASN1）、自验证通过
	sig, err := SignHello(priv, 1770000000, "nonce-from-go")
	if err != nil {
		t.Fatal(err)
	}
	if !VerifyHello(pubDER, 1770000000, "nonce-from-go", sig) {
		t.Fatal("Go sign/verify roundtrip failed")
	}
	sigDER, _ := base64.RawURLEncoding.DecodeString(sig)
	if len(sigDER) == 0 || sigDER[0] != 0x30 || len(sigDER) > 72 {
		t.Fatalf("sig not DER/≤72B: %d bytes", len(sigDER))
	}
	// DeviceID = sha256(SPKI DER) → base64url
	sum := sha256.Sum256(pubDER)
	if DeviceID(pubDER) != base64.RawURLEncoding.EncodeToString(sum[:]) {
		t.Fatal("DeviceID mismatch")
	}
}

func TestHelloProtoVer(t *testing.T) {
	if ProtoVer != "1.0.5" {
		t.Fatalf("ProtoVer = %q (契约 §7)", ProtoVer)
	}
}

// ---------- 帧向量（契约 §3.1/§3.2/§3.3） ----------

func TestFramesVectors(t *testing.T) {
	var v struct {
		Types map[string]int `json:"types"`
		Cases []struct {
			Name         string `json:"name"`
			FrameHex     *string `json:"frame_hex"`
			Construct    *struct {
				Type       string `json:"type"`
				StreamID   uint32 `json:"stream_id"`
				PayloadLen int    `json:"payload_len"`
			} `json:"construct"`
			DecodeError string `json:"decode_error"`
			Decode      *struct {
				Ver             int    `json:"ver"`
				Type            string `json:"type"`
				TypeCode        *int   `json:"type_code"`
				Flags           int    `json:"flags"`
				FlagsReadAs     *int   `json:"flags_read_as"`
				StreamID        uint32 `json:"stream_id"`
				StreamIDReadAs  *uint32 `json:"stream_id_read_as"`
				PayloadHex      *string `json:"payload_hex"`
				PayloadUtf8     *string `json:"payload_utf8"`
				Credit          *uint32 `json:"credit"`
				PayloadLen      *int    `json:"payload_len"`
			} `json:"decode"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVector(t, "frames.json"), &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		// 解码方向
		if c.FrameHex != nil {
			b, _ := hexDecode(*c.FrameHex)
			f, err := DecodeFrame(b)
			if c.DecodeError != "" {
				if err == nil {
					t.Errorf("%s: expected decode error %s, got nil", c.Name, c.DecodeError)
				}
				continue
			}
			if err != nil {
				t.Errorf("%s: decode: %v", c.Name, err)
				continue
			}
			d := c.Decode
			if d == nil {
				continue
			}
			if d.TypeCode != nil {
				if int(f.Type) != *d.TypeCode {
					t.Errorf("%s: type = %#x want %#x", c.Name, f.Type, *d.TypeCode)
				}
			} else if code, ok := v.Types[d.Type]; ok && int(f.Type) != code {
				t.Errorf("%s: type = %#x want %#x", c.Name, f.Type, code)
			}
			wantFlags := d.Flags
			if d.FlagsReadAs != nil {
				wantFlags = *d.FlagsReadAs
			}
			if f.Flags != uint8(wantFlags) {
				t.Errorf("%s: flags = %d want %d (接收方忽略非 0 不得拒帧)", c.Name, f.Flags, wantFlags)
			}
			if d.StreamIDReadAs != nil {
				if f.StreamID != *d.StreamIDReadAs {
					t.Errorf("%s: stream_id = %d want %d", c.Name, f.StreamID, *d.StreamIDReadAs)
				}
			} else if f.StreamID != d.StreamID {
				t.Errorf("%s: stream_id = %d want %d", c.Name, f.StreamID, d.StreamID)
			}
			if d.PayloadHex != nil {
				want, _ := hexDecode(*d.PayloadHex)
				if !bytes.Equal(f.Payload, want) {
					t.Errorf("%s: payload mismatch", c.Name)
				}
			}
			if d.PayloadUtf8 != nil && string(f.Payload) != *d.PayloadUtf8 {
				t.Errorf("%s: payload utf8 mismatch", c.Name)
			}
			if d.Credit != nil {
				if binary.BigEndian.Uint32(f.Payload) != *d.Credit {
					t.Errorf("%s: credit mismatch", c.Name)
				}
			}
			if d.PayloadLen != nil && len(f.Payload) != *d.PayloadLen {
				t.Errorf("%s: payload len = %d want %d", c.Name, len(f.Payload), *d.PayloadLen)
			}
		}
		// 编码方向（跳过接收侧宽容性用例）
		if c.Decode != nil && c.DecodeError == "" && c.Decode.Type != "" && c.FrameHex != nil {
			code, ok := v.Types[c.Decode.Type]
			if !ok {
				continue
			}
			var payload []byte
			switch {
			case c.Decode.PayloadHex != nil:
				payload, _ = hexDecode(*c.Decode.PayloadHex)
			case c.Decode.PayloadUtf8 != nil:
				payload = []byte(*c.Decode.PayloadUtf8)
			case c.Decode.Credit != nil:
				payload = make([]byte, 4)
				binary.BigEndian.PutUint32(payload, *c.Decode.Credit)
			case c.Decode.PayloadLen != nil:
				payload = bytes.Repeat([]byte{'a'}, *c.Decode.PayloadLen)
			}
			enc, err := EncodeFrame(uint8(code), c.Decode.StreamID, payload)
			if err != nil {
				t.Errorf("%s: encode: %v", c.Name, err)
				continue
			}
			if !bytes.Equal(enc, mustHex(t, *c.FrameHex)) {
				t.Errorf("%s: encode bytes mismatch", c.Name)
			}
			if enc[2] != 0 {
				t.Errorf("%s: sender MUST write flags=0", c.Name)
			}
		}
		// 负例 construct（len 超限走 encode 防线）
		if c.Construct != nil {
			_, err := EncodeFrame(TypeData, c.Construct.StreamID, bytes.Repeat([]byte{'a'}, c.Construct.PayloadLen))
			if err == nil {
				t.Errorf("%s: expected encode overflow", c.Name)
			}
		}
	}
}

// ---------- fingerprint 归一向量（契约 §6.1） ----------

func TestFingerprintVectors(t *testing.T) {
	var v struct {
		Cases []struct {
			Name       string   `json:"name"`
			OfferLines []string `json:"offer_lines"`
			Expect     *string  `json:"expect"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVector(t, "fingerprint-normalize.json"), &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		got := ExtractPinnedFingerprint(c.OfferLines)
		want := ""
		if c.Expect != nil {
			want = *c.Expect
		}
		if got != want {
			t.Errorf("%s: got %q want %q", c.Name, got, want)
		}
	}
}

// ---------- QR 向量（契约 §2） ----------

func TestQRVectors(t *testing.T) {
	var v struct {
		Cases []struct {
			Name   string  `json:"name"`
			URI    string  `json:"uri"`
			Expect *struct {
				V  int     `json:"v"`
				S  string  `json:"s"`
				PT string  `json:"pt"`
				FP string  `json:"fp"`
				A  string  `json:"a"`
				T  *string `json:"t"`
			} `json:"expect"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(loadVector(t, "qr-pair.json"), &v); err != nil {
		t.Fatal(err)
	}
	for _, c := range v.Cases {
		got, err := ParsePairQR(c.URI)
		if c.Expect == nil {
			if err == nil {
				t.Errorf("%s: expected error", c.Name)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.Name, err)
			continue
		}
		if got.S != c.Expect.S || got.PT != c.Expect.PT || got.FP != c.Expect.FP || got.A != c.Expect.A {
			t.Errorf("%s: fields mismatch: %+v", c.Name, got)
		}
	}
}

// ---------- TURN（契约 §5） ----------

func TestTurn(t *testing.T) {
	now := time.Unix(1770000000, 0)
	if got := TurnUsername("pair-1", 3600, now); got != "1770003600:pair-1" {
		t.Fatalf("username = %q", got)
	}
	cred := TurnCredential("secret-s", "1770003600:pair-1")
	mac := hmacSha1("secret-s", "1770003600:pair-1")
	if cred != mac {
		t.Fatalf("credential = %q want %q", cred, mac)
	}
	uris := TurnUris("bridge.example.com")
	if len(uris) != 3 || uris[2] != "turn:bridge.example.com:3478?transport=tcp" {
		t.Fatalf("uris = %v", uris)
	}
}

// ---------- helpers ----------

func hexDecode(s string) ([]byte, error) { return hex.DecodeString(s) }

func mustHex(t *testing.T, s string) []byte {
	t.Helper()
	b, err := hex.DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func hmacSha1(secret, msg string) string {
	mac := hmac.New(sha1.New, []byte(secret))
	mac.Write([]byte(msg))
	return base64.StdEncoding.EncodeToString(mac.Sum(nil))
}
