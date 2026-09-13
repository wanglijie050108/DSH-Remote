// Package hub：连接管理、pair 表、boot_id 比对、宽限期计时器、双向唯一性、TTL sweeper（02 §2.1–§2.3）
//
// 四条硬性实现约束（02 §2.1，全部落实）：
//  1. 禁止在连接关闭回调里销毁 pair —— 销毁只由五个触发条件驱动；
//  2. pair 所有权绑定「当前连接」的代次（generation）——旧代次的 bye 按过期忽略；
//  3. 销毁通知按 id 解析当前连接投递（pair 记录即将被删，不存连接引用）；
//  4. boot_id 与 pair 一同保存；hello 缺 boot_id 或 proto_ver ≠ "1.0.5" → error + 关闭。
package hub

import (
	"sync"
	"time"
)

const (
	GraceT        = 24 * time.Hour // T = 24h（用户 2026-09-12 决策；纯内存上界，判据是 boot_id）
	PairLimit     = 256            // 实例 pair 上限（超限 PAIR_LIMIT，不淘汰——用户 2026-09-13 决策）
	PTokTTL       = 5 * time.Minute
	SweeperPeriod = 30 * time.Second
	SilentAfter   = 60 * time.Second // 60s 无帧判离线（02 §3.2；半开连接只靠它发现）
	OfferMinGap   = 2 * time.Second  // 自发 punch.offer 最小间隔（02 §3.3；punch.request 触发的不受限）
	OfferRequestedWindow = 10 * time.Second // 此窗口内出现过的 punch.request 使 offer 视为「受请求触发」
)

type Role string

const (
	RoleAgent Role = "agent"
	RoleApp   Role = "app"
)

// Conn：一条信令连接。gen 用于「踢旧连接」后识别过期代次（02 §2.1 约束 2）。
type Conn struct {
	Role     Role
	ID       string // agent_id / phone_id（sha256(pub)）
	BootID   string
	IP       string
	Gen      uint64
	Stale    bool // 被新连接踢掉的旧代次：其 close/bye 不做任何生命周期动作
	LastAt   int64
	Send     func([]byte) error
	Close    func()

}


type Pair struct {
	PairID      string
	AgentID     string
	AgentBootID string
	PhoneID     string
	CreatedAt   time.Time
	GraceTimer  *time.Timer

	LastOfferAt        time.Time // 自发 offer 限流（02 §3.3）
	LastPunchRequestAt time.Time
}

type TokenRec struct {
	AgentID  string
	ExpireAt time.Time
}

// Hub：全部内存态（presence-only：无数据库、无业务字节，02 §1/§2）
type Hub struct {
	mu         sync.Mutex
	agents     map[string]*Conn // agent_id → conn
	phones     map[string]*Conn // phone_id → conn
	pairs      map[string]*Pair // pair_id → pair
	ptok       map[string]*TokenRec
	phoneIndex map[string]string // phone_id → pair_id（免扫码重连；02 §2 漏列补齐）
	nonces     map[string]time.Time

	turnSecret string
	turnHost   string
	nextPairID uint64
	genCounter uint64

	// Notify：按设备 id 解析**当前**连接并投递（02 §2.1 约束 3；pair 记录即将被删，不存连接引用）
	Notify      func(connID string, payload interface{})
	DestroyHook func(pairID, reason string) // 仅供日志/测试观测

	dispatcher *Dispatcher // 反向引用（Deliver 用）；由 SetDispatcher 注入
}

func (h *Hub) TurnSecret() string { return h.turnSecret }
func (h *Hub) TurnHost() string   { return h.turnHost }
func (h *Hub) SetDispatcher(d *Dispatcher) {
	h.dispatcher = d
	h.Notify = d.Deliver
}

func New(turnSecret, turnHost string) *Hub {
	return &Hub{
		agents:     make(map[string]*Conn),
		phones:     make(map[string]*Conn),
		pairs:      make(map[string]*Pair),
		ptok:       make(map[string]*TokenRec),
		phoneIndex: make(map[string]string),
		nonces:     make(map[string]time.Time),
		turnSecret: turnSecret,
		turnHost:   turnHost,
	}
}

// ---- 查询 ----

func (h *Hub) AgentConn(id string) *Conn  { h.mu.Lock(); defer h.mu.Unlock(); return h.agents[id] }
func (h *Hub) PhoneConn(id string) *Conn  { h.mu.Lock(); defer h.mu.Unlock(); return h.phones[id] }
func (h *Hub) PairCount() int             { h.mu.Lock(); defer h.mu.Unlock(); return len(h.pairs) }
func (h *Hub) PairByID(id string) *Pair   { h.mu.Lock(); defer h.mu.Unlock(); return h.pairs[id] }
func (h *Hub) PairForPhone(phoneID string) *Pair {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.PairForPhoneLocked(phoneID)
}

func (h *Hub) PairForPhoneLocked(phoneID string) *Pair {
	pid, ok := h.phoneIndex[phoneID]
	if !ok {
		return nil
	}
	return h.pairs[pid]
}
func (h *Hub) PairForAgent(agentID string) *Pair {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range h.pairs {
		if p.AgentID == agentID {
			return p
		}
	}
	return nil
}

func (h *Hub) pairForAgentLocked(agentID string) *Pair {
	for _, p := range h.pairs {
		if p.AgentID == agentID {
			return p
		}
	}
	return nil
}

func (h *Hub) AgentOnline(agentID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.agents[agentID] != nil
}

func (h *Hub) PhoneOnline(phoneID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.phones[phoneID] != nil
}
