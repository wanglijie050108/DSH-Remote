// QR 配对载荷解析（契约 §2）——Go 侧（供 fake-agent 与 Bridge 侧工具使用）
package contract

import (
	"fmt"
	"net/url"
	"strings"
)

type PairQR struct {
	V  int    `json:"v"`
	S  string `json:"s"`  // 信令完整端点 wss://host/v1/signal
	PT string `json:"pt"` // pair_token（base64url，32B）
	FP string `json:"fp"` // 插件证书指纹（sha-256 冒号大写）
	A  string `json:"a"`  // authority，恒 127.0.0.1:13080
	T  string `json:"t"`  // 可选 launch token
}

func ParsePairQR(uri string) (*PairQR, error) {
	u, err := url.Parse(uri)
	if err != nil {
		return nil, err
	}
	if u.Scheme != "dshlink" || u.Host != "pair" {
		return nil, fmt.Errorf("not a dshlink://pair URI: scheme=%s host=%s", u.Scheme, u.Host)
	}
	q := u.Query()
	if q.Get("v") != "1" {
		return nil, fmt.Errorf("unsupported QR version: %s", q.Get("v"))
	}
	p := &PairQR{
		S:  q.Get("s"),
		PT: q.Get("pt"),
		FP: q.Get("fp"),
		A:  q.Get("a"),
		T:  q.Get("t"),
	}
	if p.S == "" || p.PT == "" || p.FP == "" || p.A == "" {
		return nil, fmt.Errorf("missing required field (s/pt/fp/a)")
	}
	if !strings.HasPrefix(p.S, "wss://") {
		return nil, fmt.Errorf("signal endpoint must be wss:// (got %q)", p.S)
	}
	return p, nil
}
