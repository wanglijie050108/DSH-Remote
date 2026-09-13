// pair 生命周期 9 项语义测试（02 §1 DoD）——直接驱动 hub，不经 WS 层
package hub

import (
	"strings"
	"testing"
	"time"
)

func newTestHub() *Hub {
	h := New("test-secret", "bridge.example.com")
	h.Notify = func(connID string, payload interface{}) {} // 测试注入自己的收集器
	return h
}

func mkConn(role Role, id string) *Conn {
	return &Conn{Role: role, ID: id, BootID: "boot-" + id, LastAt: time.Now().Unix()}
}

type recorder struct {
	events []string
}

func (r *recorder) notify(connID string, payload interface{}) {
	m, _ := payload.(map[string]interface{})
	r.events = append(r.events, connID[:6]+":"+m["t"].(string)+":"+mString(m["code"]))
}
func mString(v interface{}) string {
	if s, ok := v.(string); ok {
		return s
	}
	return ""
}

// ① 手机断开 → pair 保留
func TestPhoneDisconnectKeepsPair(t *testing.T) {
	h := newTestHub()
	rec := &recorder{}
	h.Notify = rec.notify
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	if r := h.Bind(phone, "agent-aaaaaaaa"); r.Status != "ok" {
		t.Fatalf("bind: %s", r.Status)
	}
	h.PhoneOffline(phone)
	if h.PairCount() != 1 {
		t.Fatalf("pair must survive phone disconnect (got %d)", h.PairCount())
	}
}

// ② 插件侧抖动（boot_id 相同）→ 保留并免扫码重建
func TestAgentReconnectSameBoot(t *testing.T) {
	h := newTestHub()
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	h.AgentOffline(agent)
	pair := h.PairForAgent("agent-aaaaaaaa")
	if pair == nil {
		t.Fatal("pair missing")
	}
	agent2 := mkConn(RoleAgent, "agent-aaaaaaaa") // 同 boot_id
	if !h.AgentHelloCheck(pair, agent2.BootID) {
		t.Fatal("same boot_id must resume")
	}
	if h.PairCount() != 1 {
		t.Fatalf("pair must survive (got %d)", h.PairCount())
	}
}

// ③ DSH 重启（boot_id 不同）→ 销毁 + AGENT_RESTARTED 推手机
func TestAgentRestartDestroysPair(t *testing.T) {
	h := newTestHub()
	rec := &recorder{}
	h.Notify = rec.notify
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	pair := h.PairForAgent("agent-aaaaaaaa")
	h.AgentHelloCheck(pair, "boot-NEW-PROCESS") // 新进程 boot_id
	if h.PairCount() != 0 {
		t.Fatal("pair must be destroyed")
	}
	if !anyEvent(rec, "phone-", "AGENT_RESTARTED") {
		t.Fatalf("phone must be pushed AGENT_RESTARTED, got %v", rec.events)
	}
}

// ④ 显式 bye → 立即销毁 + bye.ok + 转发对端
func TestByeDestroysAndForwards(t *testing.T) {
	h := newTestHub()
	rec := &recorder{}
	h.Notify = rec.notify
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	pair, peerID, ok := h.ProcessBye(phone)
	if !ok || pair == nil || peerID != "agent-aaaaaaaa" {
		t.Fatalf("bye failed: %v %v", ok, peerID)
	}
	if h.PairCount() != 0 {
		t.Fatal("pair must be destroyed")
	}
}

// ⑤⑤' 宽限期：T=24h 内同 boot_id 恢复 → 保留；宽限期计时器重新起算（不沿用剩余时间）
func TestGraceTimerRestart(t *testing.T) {
	h := newTestHub()
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	h.AgentOffline(agent)
	pair := h.PairForAgent("agent-aaaaaaaa")
	if pair.GraceTimer == nil {
		t.Fatal("grace timer must start on agent offline")
	}
	// 模拟计时器内部剩余时间已消耗：直接验证重连后计时器被取消、再次断开后重新起算（新 AfterFunc）
	agent2 := mkConn(RoleAgent, "agent-aaaaaaaa")
	h.AgentHelloCheck(pair, agent2.BootID)
	if pair.GraceTimer != nil {
		t.Fatal("timer must be cancelled on resume")
	}
	h.agents[agent2.ID] = agent2
	h.AgentOffline(agent2)
	if h.PairForAgent("agent-aaaaaaaa").GraceTimer == nil {
		t.Fatal("timer must restart (重新起算) on second offline")
	}
}

// ⑥ 新手机对同一 agent bind → 旧手机 PAIR_REPLACED（条件④）
func TestNewPhoneReplacesOld(t *testing.T) {
	h := newTestHub()
	rec := &recorder{}
	h.Notify = rec.notify
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phoneA := mkConn(RoleApp, "phone-aaaaaa"); h.AttachPhone(phoneA)
	h.Bind(phoneA, "agent-aaaaaaaa")
	phoneB := mkConn(RoleApp, "phone-bbbbbb"); h.AttachPhone(phoneB)
	h.Bind(phoneB, "agent-aaaaaaaa")
	if h.PairCount() != 1 {
		t.Fatalf("exactly one pair per agent (got %d)", h.PairCount())
	}
	if !anyEvent(rec, "phone-", "PAIR_REPLACED") {
		t.Fatalf("old phone must receive PAIR_REPLACED, got %v", rec.events)
	}
	if h.PairForPhone("phone-aaaaaa") != nil {
		t.Fatal("old phone index must be cleared")
	}
}

// ⑦ 已配对手机对另一 agent bind → 旧 pair 销毁 + 旧 agent PAIR_REPLACED（条件⑤，v1.0.5）
func TestPhoneRebindToAnotherAgent(t *testing.T) {
	h := newTestHub()
	rec := &recorder{}
	h.Notify = rec.notify
	agent1 := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent1)
	agent2 := mkConn(RoleAgent, "agent-bbbbbbbb"); h.AttachAgent(agent2)
	phone := mkConn(RoleApp, "phone-cccccc"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	h.Bind(phone, "agent-bbbbbbbb") // 换绑
	if h.PairCount() != 1 {
		t.Fatalf("exactly one pair per phone (got %d)", h.PairCount())
	}
	if h.PairForAgent("agent-aaaaaaaa") != nil {
		t.Fatal("old agent pair must be destroyed")
	}
	if !anyEvent(rec, "agent-", "PAIR_REPLACED") {
		t.Fatalf("old agent must receive PAIR_REPLACED, got %v", rec.events)
	}
}

// ⑧ 踢旧连接不得误删新挂载的 pair（02 §2.1 约束 1/2）
func TestKickedConnDoesNotDestroyPair(t *testing.T) {
	h := newTestHub()
	agent1 := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent1)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.Bind(phone, "agent-aaaaaaaa")
	agent2 := mkConn(RoleAgent, "agent-aaaaaaaa")
	kicked := h.AttachAgent(agent2)
	if kicked == nil || !kicked.Stale {
		t.Fatal("old conn must be marked stale")
	}
	h.AgentOffline(kicked) // 旧代次 close：不得触发 GRACE/销毁
	if h.PairCount() != 1 {
		t.Fatalf("pair must survive kick (got %d)", h.PairCount())
	}
	if h.AgentConn("agent-aaaaaaaa") != agent2 {
		t.Fatal("current conn must be the new one")
	}
	// 旧代次的 bye 同样忽略
	pair, _, ok := h.ProcessBye(kicked)
	if ok {
		t.Fatalf("stale bye must be ignored (pair=%v)", pair)
	}
	if h.PairCount() != 1 {
		t.Fatal("pair must survive stale bye")
	}
}

// ⑨ 销毁时清除 ptok：销毁前生成的未过期 QR MUST 不可再绑定（§4.4）
func TestDestroyClearsPairToken(t *testing.T) {
	h := newTestHub()
	agent := mkConn(RoleAgent, "agent-aaaaaaaa"); h.AttachAgent(agent)
	phone := mkConn(RoleApp, "phone-bbbbbbb"); h.AttachPhone(phone)
	h.RegisterPairToken("agent-aaaaaaaa", strings.Repeat("A", 43), 0)
	h.Bind(phone, "agent-aaaaaaaa")
	h.RegisterPairToken("agent-aaaaaaaa", strings.Repeat("B", 43), 0)
	// 销毁（bye）
	h.ProcessBye(phone)
	if _, ok := h.ConsumePairToken(strings.Repeat("B", 43)); ok {
		t.Fatal("ptok must be cleared on pair destruction (§4.4)")
	}
}

// 容量：PAIR_LIMIT（不淘汰，用户 2026-09-13 决策）
func TestPairLimit(t *testing.T) {
	h := newTestHub()
	// 直接注入 256 个 pair（绕过逐个 bind 的开销）
	for i := 0; i < 256; i++ {
		aid := "agent-" + pad(i)
		pid := "phone-" + pad(i)
		h.AttachAgent(mkConn(RoleAgent, aid))
		p := mkConn(RoleApp, pid)
		h.AttachPhone(p)
		h.Bind(p, aid)
	}
	if h.PairCount() != 256 {
		t.Fatalf("want 256, got %d", h.PairCount())
	}
	phoneX := mkConn(RoleApp, "phone-xxxxxx"); h.AttachPhone(phoneX)
	h.RegisterPairToken("agent-xxxxxxxx", strings.Repeat("C", 43), 0)
	if r := h.Bind(phoneX, "agent-xxxxxxxx"); r.Status != "PAIR_LIMIT" {
		t.Fatalf("want PAIR_LIMIT, got %s", r.Status)
	}
}

func pad(i int) string {
	s := "0000"
	for i > 0 {
		s = string(rune('0'+i%10)) + s
		i /= 10
	}
	return s[len(s)-4:]
}

func anyEvent(rec *recorder, connPrefix, code string) bool {
	for _, e := range rec.events {
		if strings.HasPrefix(e, connPrefix) && strings.Contains(e, code) {
			return true
		}
	}
	return false
}
