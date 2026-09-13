// 协议分发层：WS 端点 /v1/signal，读写 JSON 文本帧（02 §3.2，契约 §4）
// t 是封闭集合：default → error + 关闭连接。**永远不要新增「通用转发」类型** ——
// presence-only 的「代码路径中不存在业务字节」保证完全依赖这条规则。
package hub

import (
	"encoding/json"
	"log"
	"sync"
	"time"

	"remotedsh-bridge/internal/auth"
	"remotedsh-bridge/internal/limit"
)

// Message：入站消息（契约 §4.1；未知字段忽略）
type Message struct {
	T        string  `json:"t"`
	Role     string  `json:"role"`
	Pub      string  `json:"pub"`
	BootID   string  `json:"boot_id"`
	TS       int64   `json:"ts"`
	Nonce    string  `json:"nonce"`
	Sig      string  `json:"sig"`
	ProtoVer string  `json:"proto_ver"`
	PTokHash string  `json:"ptok_hash"`
	TTL      int64   `json:"ttl"`
	PTok     string  `json:"ptok"`
	PairID   string  `json:"pair_id"`
	SDP      *string `json:"sdp"`
	Reason   string  `json:"reason"`
}

// Session：一条连接的分发层状态
type Session struct {
	Conn    *Conn
	HelloOK bool
	Rate    limit.RateState

	writeMu sync.Mutex
}

func (s *Session) Send(payload interface{}) {
	b, err := json.Marshal(payload)
	if err != nil {
		return
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	_ = s.Conn.Send(b)
}

func (s *Session) SendError(code, msg string) {
	s.Send(map[string]interface{}{"t": "error", "code": code, "msg": msg})
}

// Dispatcher：持有 Hub、hello 门禁、会话表
type Dispatcher struct {
	Hub      *Hub
	Hello    *auth.HelloAuth
	sessions sync.Map // *Conn → *Session
}

func NewDispatcher(h *Hub, hello *auth.HelloAuth) *Dispatcher {
	return &Dispatcher{Hub: h, Hello: hello}
}

func (d *Dispatcher) Register(s *Session) { d.sessions.Store(s.Conn, s) }
func (d *Dispatcher) Unregister(s *Session) { d.sessions.Delete(s.Conn) }

// Deliver：按设备 id 解析当前连接并投递（Hub.Notify 的落点）
func (d *Dispatcher) Deliver(connID string, payload interface{}) {
	// connID 是设备 id；查 hub 当前连接，再查其 session
	var conn *Conn
	d.Hub.mu.Lock()
	if c, ok := d.Hub.agents[connID]; ok {
		conn = c
	} else if c, ok := d.Hub.phones[connID]; ok {
		conn = c
	}
	d.Hub.mu.Unlock()
	if conn == nil {
		return // 对端离线：销毁类通知不落盘（presence-only），由 hello.ok{pair:null} 兜底（§4.3）
	}
	if s, ok := d.sessions.Load(conn); ok {
		s.(*Session).Send(payload)
	}
}

// HandleFrame：处理一条入站文本帧（帧大小已由传输层校验 ≤64KB）
func (d *Dispatcher) HandleFrame(s *Session, raw []byte) {
	s.Conn.LastAt = time.Now().Unix()
	if !s.Rate.Allow() {
		s.SendError("RATE_LIMITED", "too many messages") // 02 §3.3：握手后无 HTTP 状态码
		return
	}
	var msg Message
	if err := json.Unmarshal(raw, &msg); err != nil {
		s.Conn.Close() // bad json
		return
	}
	if !s.HelloOK {
		d.handleHello(s, &msg)
		return
	}
	d.dispatch(s, &msg)
}

// handleHello：门禁（02 §3.2 顺序）：① proto_ver ② ts 窗口 ③ nonce 去重 ④ 验签
func (d *Dispatcher) handleHello(s *Session, msg *Message) {
	if msg.T != "hello" {
		s.SendError("AUTH_FAILED", "hello required")
		s.Conn.Close()
		return
	}
	if msg.ProtoVer != "1.0.5" { // ① 契约 §7
		s.SendError("PROTO_VER_UNSUPPORTED", "expect 1.0.5") // 客户端 MUST NOT 重试（§4.5）
		s.Conn.Close()
		return
	}
	if !auth.CheckTS(msg.TS) { // ②
		s.SendError("AUTH_FAILED", "ts out of ±60s window")
		s.Conn.Close()
		return
	}
	if !d.Hello.CheckNonce(msg.Nonce) { // ③ 窗口 ≥120s
		s.SendError("AUTH_FAILED", "nonce replay")
		s.Conn.Close()
		return
	}
	deviceID, err := auth.DeviceID(msg.Pub)
	if err != nil || !auth.VerifyHello(msg.Pub, msg.TS, msg.Nonce, msg.Sig) { // ④ 规范化字节串（§4.2）
		s.SendError("AUTH_FAILED", "bad signature")
		s.Conn.Close()
		return
	}

	switch msg.Role {
	case "agent":
		if msg.BootID == "" { // 约束 4
			s.SendError("AUTH_FAILED", "agent MUST carry boot_id")
			s.Conn.Close()
			return
		}
		s.Conn.Role = RoleAgent
		s.Conn.ID = deviceID
		s.Conn.BootID = msg.BootID
		if kicked := d.Hub.AttachAgent(s.Conn); kicked != nil {
			kicked.Close() // 踢旧连接（已标记 stale）
		}
		s.HelloOK = true
		d.afterAgentHello(s)
	case "app":
		s.Conn.Role = RoleApp
		s.Conn.ID = deviceID
		if kicked := d.Hub.AttachPhone(s.Conn); kicked != nil {
			kicked.Close()
		}
		s.HelloOK = true
		d.afterPhoneHello(s)
	default:
		s.SendError("AUTH_FAILED", "role must be agent|app")
		s.Conn.Close()
	}
}

func pairPayload(pair *Pair) map[string]interface{} {
	return map[string]interface{}{"pair_id": pair.PairID, "phone_id": pair.PhoneID, "agent_id": pair.AgentID}
}

func (d *Dispatcher) afterAgentHello(s *Session) {
	pair := d.Hub.PairForAgent(s.Conn.ID)
	if pair == nil {
		s.Send(map[string]interface{}{"t": "hello.ok", "pair": nil, "peer_online": false, "ts": time.Now().Unix()})
		return
	}
	if !d.Hub.AgentHelloCheck(pair, s.Conn.BootID) {
		// 条件②已销毁并推手机；agent 本端 hello.ok{pair:null} → 重新注册/出 QR
		s.Send(map[string]interface{}{"t": "hello.ok", "pair": nil, "peer_online": false, "ts": time.Now().Unix()})
		return
	}
	s.Send(map[string]interface{}{
		"t": "hello.ok", "pair": pairPayload(pair),
		"peer_online": d.Hub.PhoneOnline(pair.PhoneID), "ts": time.Now().Unix(),
	})
}

func (d *Dispatcher) afterPhoneHello(s *Session) {
	pair := d.Hub.PairForPhone(s.Conn.ID)
	if pair == nil {
		s.Send(map[string]interface{}{"t": "hello.ok", "pair": nil, "peer_online": false, "ts": time.Now().Unix()})
		return
	}
	s.Send(map[string]interface{}{
		"t": "hello.ok", "pair": pairPayload(pair),
		"peer_online": d.Hub.AgentOnline(pair.AgentID), "ts": time.Now().Unix(),
	})
}

// dispatch：t 是封闭集合（契约 §4）；未知类型 → error + 关闭
func (d *Dispatcher) dispatch(s *Session, msg *Message) {
	switch msg.T {
	case "ping":
		s.Send(map[string]interface{}{"t": "pong"})
	case "pong":
		// LastAt 已刷新

	case "pair.ready": // 仅 agent
		if s.Conn.Role != RoleAgent {
			s.SendError("AUTH_FAILED", "role not allowed")
			return
		}
		if len(msg.PTokHash) != 43 { // sha256 → base64url 恒 43 字符
			s.SendError("AUTH_FAILED", "bad ptok_hash")
			return
		}
		d.Hub.RegisterPairToken(s.Conn.ID, msg.PTokHash, time.Duration(msg.TTL)*time.Second)
		s.Send(map[string]interface{}{"t": "pair.ready.ok", "ts": time.Now().Unix()})

	case "pair.bind": // 仅 app
		if s.Conn.Role != RoleApp {
			s.SendError("AUTH_FAILED", "role not allowed")
			return
		}
		agentID, ok := d.Hub.ConsumePairToken(auth.PairTokenHash(msg.PTok))
		if !ok {
			s.SendError("AUTH_FAILED", "invalid pair token")
			return
		}
		switch r := d.Hub.Bind(s.Conn, agentID); r.Status {
		case "ok":
			// pair.ok 已由 Bind 内投递（两端）
		case "PAIR_LIMIT":
			s.SendError("PAIR_LIMIT", "服务繁忙") // 不自动重试（§4.5，用户 2026-09-13 决策）
		case "PEER_OFFLINE":
			s.SendError("PEER_OFFLINE", "agent 不在线，无法完成绑定")
		}

	case "punch.request": // app → agent
		if s.Conn.Role != RoleApp {
			s.SendError("AUTH_FAILED", "role not allowed")
			return
		}
		pair := d.Hub.PairByID(msg.PairID)
		if pair == nil || pair.PhoneID != s.Conn.ID {
			s.SendError("PAIR_NOT_FOUND", "pair_id mismatch") // 绝不跨 pair 路由（§4.5）
			log.Printf("[hub] WARN pair_id assertion failed (punch.request) from %s…", short(s.Conn.ID))
			return
		}
		agent, online := d.Hub.RequestPunch(pair)
		if !online {
			s.SendError("PEER_OFFLINE", "对端不在线（宽限期内），等 presence 恢复后重试") // 不得静默丢弃
			return
		}
		d.deliverConn(agent, map[string]interface{}{"t": "punch.request", "pair_id": pair.PairID})

	case "punch.offer", "punch.answer": // 对内转发；sdp 必须为字符串且 ≤64KB（防放大，02 §3.2）
		var pair *Pair
		var target *Conn
		if msg.T == "punch.offer" {
			if s.Conn.Role != RoleAgent {
				s.SendError("AUTH_FAILED", "role not allowed")
				return
			}
			pair = d.Hub.PairByID(msg.PairID)
			if pair == nil || pair.AgentID != s.Conn.ID {
				s.SendError("PAIR_NOT_FOUND", "pair_id assertion failed")
				log.Printf("[hub] WARN pair_id assertion failed (punch.offer) from %s…", short(s.Conn.ID))
				return
			}
			if msg.SDP == nil || len(*msg.SDP) > limit.MaxFrameBytes {
				s.Conn.Close()
				return
			}
			target = d.Hub.PhoneConn(pair.PhoneID)
			if target == nil {
				s.SendError("PEER_OFFLINE", "对端不在线")
				return
			}
			if !d.Hub.OfferAllowed(pair, time.Now()) {
				return // 自发重发窗口内丢弃（02 §3.3）
			}
		} else {
			if s.Conn.Role != RoleApp {
				s.SendError("AUTH_FAILED", "role not allowed")
				return
			}
			pair = d.Hub.PairByID(msg.PairID)
			if pair == nil || pair.PhoneID != s.Conn.ID {
				s.SendError("PAIR_NOT_FOUND", "pair_id assertion failed")
				return
			}
			if msg.SDP == nil || len(*msg.SDP) > limit.MaxFrameBytes {
				s.Conn.Close()
				return
			}
			target = d.Hub.AgentConn(pair.AgentID)
			if target == nil {
				s.SendError("PEER_OFFLINE", "对端不在线")
				return
			}
		}
		d.deliverConn(target, map[string]interface{}{"t": msg.T, "pair_id": pair.PairID, "sdp": *msg.SDP})

	case "relay.request": // 双向（§5：真实用途是为新 gather 准备有效凭证）
		turn := auth.AllocTurn(d.Hub.TurnSecret(), "relay-"+short(s.Conn.ID), d.Hub.TurnHost())
		s.Send(map[string]interface{}{"t": "relay.alloc", "turn": turn})

	case "presence.get": // 推送决策前 MUST 调用（防竞态）
		var peerOnline bool
		if s.Conn.Role == RoleAgent {
			if pair := d.Hub.PairForAgent(s.Conn.ID); pair != nil {
				peerOnline = d.Hub.PhoneOnline(pair.PhoneID)
			}
		} else if pair := d.Hub.PairForPhone(s.Conn.ID); pair != nil {
			peerOnline = d.Hub.AgentOnline(pair.AgentID)
		}
		s.Send(map[string]interface{}{"t": "presence", "peer_online": peerOnline})

	case "bye": // 条件①：显式撤销
		reason := msg.Reason
		if reason != "user" && reason != "shutdown" {
			reason = "user"
		}
		pair, peerID, ok := d.Hub.ProcessBye(s.Conn)
		if !ok {
			return // 过期代次 bye：忽略（02 §2.1 约束 2）
		}
		s.Send(map[string]interface{}{"t": "bye.ok", "ts": time.Now().Unix()})
		if pair != nil && peerID != "" {
			d.Deliver(peerID, map[string]interface{}{"t": "bye", "reason": reason}) // 对端离线则不转发（§4.1 bye 行）
		}

	default:
		// 封闭集合：未知 t → error + 关闭（§4）
		s.SendError("AUTH_FAILED", "unknown message type: "+msg.T)
		s.Conn.Close()
	}
}

// deliverConn：对已解析的当前连接直接投递
func (d *Dispatcher) deliverConn(target *Conn, payload interface{}) {
	if s, ok := d.sessions.Load(target); ok {
		s.(*Session).Send(payload)
	}
}
