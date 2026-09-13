// Package limit：限流与门禁（02 §3.3）
// 单 IP 连接数 ≤16（IP 取 X-Forwarded-For 最右——仅当确实配置了可信代理；默认用 socket 对端地址）；
// 消息速率 ≤20 msg/s/conn（超限回 RATE_LIMITED）；入站帧上限 64KB；hello 10s 超时；pair_token 猜测锁定。
package limit

import (
	"sync"
	"time"
)

const (
	MaxFrameBytes   = 64 * 1024 // 入站帧上限（SDP 充足）(02 §3.2)
	HelloDeadline   = 10 * time.Second
	MsgPerWindow    = 20          // msg / window / conn
	RateWindow      = time.Second // 粗粒度 1s 窗口
	MaxConnsPerIP   = 16
	TokenMaxFails   = 5
	TokenLockout    = 10 * time.Minute
)

// TokenGuard：pair_token 连续失败锁定（防猜 token；IPv6 轮换下仅辅助，真正屏障是 32B 随机）
type TokenGuard struct {
	mu    sync.Mutex
	fails map[string]*tokenFail
}

type tokenFail struct {
	count       int
	lockedUntil time.Time
}

func NewTokenGuard() *TokenGuard {
	return &TokenGuard{fails: make(map[string]*tokenFail)}
}

func (g *TokenGuard) Allowed(ip string) bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	f, ok := g.fails[ip]
	return !ok || time.Now().After(f.lockedUntil)
}

func (g *TokenGuard) RecordFail(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	f, ok := g.fails[ip]
	if !ok {
		f = &tokenFail{}
		g.fails[ip] = f
	}
	f.count++
	if f.count >= TokenMaxFails {
		f.lockedUntil = time.Now().Add(TokenLockout)
		f.count = 0
	}
}

func (g *TokenGuard) RecordSuccess(ip string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	delete(g.fails, ip)
}

// ConnCounter：单 IP 并发连接数（02 §3.3：超限拒绝）
type ConnCounter struct {
	mu    sync.Mutex
	conns map[string]int
}

func NewConnCounter() *ConnCounter { return &ConnCounter{conns: make(map[string]int)} }

func (c *ConnCounter) Acquire(ip string) bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conns[ip] >= MaxConnsPerIP {
		return false
	}
	c.conns[ip]++
	return true
}

func (c *ConnCounter) Release(ip string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.conns[ip] > 0 {
		c.conns[ip]--
	}
	if c.conns[ip] == 0 {
		delete(c.conns, ip)
	}
}

// RateState：每连接消息速率计数（粗粒度 1s 窗口；超限回 RATE_LIMITED，不断开）
type RateState struct {
	mu       sync.Mutex
	window   int64
	count    int
}

func (r *RateState) Allow() bool {
	r.mu.Lock()
	defer r.mu.Unlock()
	window := time.Now().Unix()
	if r.window != window {
		r.window = window
		r.count = 0
	}
	r.count++
	return r.count <= MsgPerWindow
}
