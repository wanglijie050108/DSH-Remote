// WS 传输层（02 §5）：仅 /v1/signal 端点；Signal 仅 compose 内网 expose（部署清单硬性项）
package hub

import (
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"

	"remotedsh-bridge/internal/limit"
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
}

// Server：HTTP 包装
type Server struct {
	Disp     *Dispatcher
	Conns    *limit.ConnCounter
	Token    *limit.TokenGuard
	upgrades atomic.Uint64
}

func NewServer(d *Dispatcher) *Server {
	return &Server{Disp: d, Conns: limit.NewConnCounter(), Token: limit.NewTokenGuard()}
}

// HandleSignal：/v1/signal。真实客户端 IP 取 socket 对端地址 ——
// 默认（无 trusted_proxies）Caddy 丢弃入站 XFF 并写入客户端地址，取最右 = 唯一元素（02 §5.1）。
// 本服务仅 compose 内网可达；若直连出现非 Caddy 网段来源应告警（部署被改坏）。
func (s *Server) HandleSignal(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/signal" {
		http.NotFound(w, r)
		return
	}
	ip, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		ip = r.RemoteAddr
	}
	if !s.Conns.Acquire(ip) {
		http.Error(w, "too many connections", http.StatusTooManyRequests) // 02 §3.3：单 IP ≤16
		return
	}
	defer s.Conns.Release(ip)

	ws, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	// 防 hello 超时与 defer ws.Close() 重复关闭：用 once 保证 Close 只执行一次
	var closeOnce sync.Once
	closeWS := func() { closeOnce.Do(func() { _ = ws.Close() }) }
	defer closeWS()

	conn := &Conn{
		IP:    ip,
		Send:  func(b []byte) error { return ws.WriteMessage(websocket.TextMessage, b) },
		Close: closeWS,
	}
	sess := &Session{Conn: conn}
	s.Disp.Register(sess)
	defer s.Disp.Unregister(sess)

	// hello 门禁：10s 内未收到合法 hello → 关闭（契约 §4.1）
	helloTimer := time.AfterFunc(limit.HelloDeadline, func() {
		if !sess.HelloOK {
			closeWS()
		}
	})
	defer helloTimer.Stop()

	ws.SetReadLimit(limit.MaxFrameBytes) // 入站帧上限 64KB（02 §3.2）
	for {
		mt, raw, err := ws.ReadMessage()
		if err != nil {
			break
		}
		if mt != websocket.TextMessage {
			closeWS() // 一帧一消息 JSON 文本帧
			break
		}
		s.Disp.HandleFrame(sess, raw)
	}
	// 连接关闭：按角色走 GRACE / presence —— 不在这里销毁 pair（02 §2.1 约束 1）
	if sess.HelloOK && !conn.Stale {
		switch conn.Role {
		case RoleAgent:
			s.Disp.Hub.AgentOffline(conn)
		case RoleApp:
			s.Disp.Hub.PhoneOffline(conn)
		}
	}
}

// Sweeper：60s 无帧判离线（02 §3.2；半开连接只靠它发现）
func (s *Server) StartSweeper() *time.Ticker {
	t := time.NewTicker(SweeperPeriod)
	go func() {
		for range t.C {
			s.Disp.Hub.Sweep(time.Now())
		}
	}()
	return t
}

const SweeperPeriod = 30 * time.Second