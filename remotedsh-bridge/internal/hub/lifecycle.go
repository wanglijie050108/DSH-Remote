// pair 生命周期（02 §2.1：判据是「同一个 DSH 进程」，不是「连接是否在」）
// 五个销毁触发条件，每一个都 MUST 向仍在线的对端主动推送（契约 §4.3）。
// 硬性约束（02 §2.1）：连接关闭回调不销毁；所有权绑定连接代次；通知按 id 解析当前连接；boot_id 与 pair 同存。
package hub

import (
	"fmt"
	"log"
	"time"

	"remotedsh-bridge/internal/auth"
)

// ---- 连接注册（hello 成功后）----

// AttachAgent：同 id 重复上线 → 踢旧连接（标记 stale，其 close/bye 不做任何动作）。
func (h *Hub) AttachAgent(conn *Conn) (kicked *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.genCounter++
	conn.Gen = h.genCounter
	if old, ok := h.agents[conn.ID]; ok && old != conn {
		old.Stale = true
		kicked = old
	}
	h.agents[conn.ID] = conn
	return kicked
}

// AttachPhone：同上。
func (h *Hub) AttachPhone(conn *Conn) (kicked *Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.genCounter++
	conn.Gen = h.genCounter
	if old, ok := h.phones[conn.ID]; ok && old != conn {
		old.Stale = true
		kicked = old
	}
	h.phones[conn.ID] = conn
	return kicked
}

// AgentHelloCheck：pair 存在时的 boot_id 比对（条件②）。
// resumed=true：同 boot_id 免扫码恢复（取消宽限计时器）。
// resumed=false：已按条件②销毁并向手机推送 AGENT_RESTARTED。
func (h *Hub) AgentHelloCheck(pair *Pair, bootID string) (resumed bool) {
	h.mu.Lock()
	if pair.AgentBootID == bootID {
		if pair.GraceTimer != nil {
			pair.GraceTimer.Stop()
			pair.GraceTimer = nil
		}
		h.mu.Unlock()
		return true
	}
	phoneID := pair.PhoneID
	h.destroyLocked(pair, "boot_id changed (DSH restarted)")
	h.mu.Unlock()
	// 条件②推送：手机收 AGENT_RESTARTED（主动推送，不依赖对方下次 hello）
	h.Notify(phoneID, map[string]interface{}{"t": "error", "code": "AGENT_RESTARTED", "msg": "电脑上的 DSH 已重启，请重新扫码"})
	return false
}

// AgentOffline：agent 连接关闭（或 sweeper 判死）→ 不销毁 pair；重新起算 T=24h；推送 presence。
// stale 连接跳过（02 §2.1 约束 1：踢旧不得触发销毁/宽限）。
func (h *Hub) AgentOffline(conn *Conn) {
	h.mu.Lock()
	if conn.Stale || h.agents[conn.ID] != conn {
		h.mu.Unlock()
		return
	}
	delete(h.agents, conn.ID)
	pair := h.pairForAgentLocked(conn.ID)
	if pair == nil {
		h.mu.Unlock()
		return
	}
	phoneID := pair.PhoneID
	startGraceTimerLocked(pair, func() {
		// 条件③到期：销毁 + 清 ptok + 推手机 PAIR_EXPIRED
		h.mu.Lock()
		p := h.pairs[pair.PairID]
		if p == nil {
			h.mu.Unlock()
			return
		}
		phoneID := p.PhoneID
		h.destroyLocked(p, "grace expired (T=24h)")
		h.mu.Unlock()
		h.Notify(phoneID, map[string]interface{}{"t": "error", "code": "PAIR_EXPIRED", "msg": "PC 离线超过 24 小时，配对已失效，请重新扫码"})
	})
	h.mu.Unlock()
	h.Notify(phoneID, map[string]interface{}{"t": "presence", "peer_online": false})
}

// PhoneOffline：手机断开不销毁 pair（契约 §4.3）；推送 presence 给 agent。
func (h *Hub) PhoneOffline(conn *Conn) {
	h.mu.Lock()
	if conn.Stale || h.phones[conn.ID] != conn {
		h.mu.Unlock()
		return
	}
	delete(h.phones, conn.ID)
	var agentID string
	if pair := h.PairForPhoneLocked(conn.ID); pair != nil {
		agentID = pair.AgentID
	}
	h.mu.Unlock()
	if agentID != "" {
		h.Notify(agentID, map[string]interface{}{"t": "presence", "peer_online": false})
	}
}

// startGraceTimerLocked：每次 agent 断开**重新起算**（不得沿用剩余时间，契约 §4.3）。
func startGraceTimerLocked(pair *Pair, onExpire func()) {
	if pair.GraceTimer != nil {
		pair.GraceTimer.Stop()
	}
	pair.GraceTimer = time.AfterFunc(GraceT, onExpire)
}

// ---- pair.ready（插件出 QR 前注册 token；Bridge 只存 hash，§4.1/§4.4）----

func (h *Hub) RegisterPairToken(agentID, ptokHash string, ttl time.Duration) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if ttl <= 0 || ttl > PTokTTL {
		ttl = PTokTTL
	}
	// 同一 agent 再次注册 MUST 作废旧 hash（§4.4）
	for k, rec := range h.ptok {
		if rec.AgentID == agentID {
			delete(h.ptok, k)
		}
	}
	h.ptok[ptokHash] = &TokenRec{AgentID: agentID, ExpireAt: time.Now().Add(ttl)}
}

// ConsumePairToken：单次有效；返回 agent_id。
func (h *Hub) ConsumePairToken(ptokHash string) (string, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	rec, ok := h.ptok[ptokHash]
	if !ok || time.Now().After(rec.ExpireAt) {
		delete(h.ptok, ptokHash)
		return "", false
	}
	delete(h.ptok, ptokHash)
	return rec.AgentID, true
}

// ---- pair.bind（02 §3.2；双向唯一性 + PAIR_LIMIT）----

type BindResult struct {
	Status string // "ok" | "PAIR_LIMIT" | "PEER_OFFLINE"
	Pair   *Pair
}

func (h *Hub) Bind(phone *Conn, agentID string) BindResult {
	h.mu.Lock()
	// 容量（02 §2.2）：超限直接拒绝，不做 LRU 淘汰（用户 2026-09-13 决策）
	if len(h.pairs) >= PairLimit {
		h.mu.Unlock()
		return BindResult{Status: "PAIR_LIMIT"}
	}
	agentConn := h.agents[agentID]
	if agentConn == nil {
		h.mu.Unlock()
		return BindResult{Status: "PEER_OFFLINE"} // QR 5min 内 agent 应在线
	}
	// 条件④：新手机对同一 agent bind → 销毁旧 pair、推旧手机 PAIR_REPLACED
	if old := h.pairForAgentLocked(agentID); old != nil && old.PhoneID != phone.ID {
		oldPhoneID := old.PhoneID
		h.destroyLocked(old, "replaced by new phone (cond ④)")
		defer h.Notify(oldPhoneID, map[string]interface{}{"t": "error", "code": "PAIR_REPLACED", "msg": "已在另一台手机完成配对"})
	}
	// 条件⑤：已配对手机对另一 agent bind（每 phone 至多 1 pair，v1.0.5）→ 销毁旧 pair、推旧 agent PAIR_REPLACED
	if oldPID, ok := h.phoneIndex[phone.ID]; ok {
		if old := h.pairs[oldPID]; old != nil && old.AgentID != agentID {
			oldAgentID := old.AgentID
			h.destroyLocked(old, "phone rebound to another agent (cond ⑤)")
			defer h.Notify(oldAgentID, map[string]interface{}{"t": "error", "code": "PAIR_REPLACED", "msg": "该手机已在另一台电脑完成配对"})
		}
	}
	h.nextPairID++
	pairID := fmt.Sprintf("pair-%d", h.nextPairID)
	pair := &Pair{
		PairID:      pairID,
		AgentID:     agentID,
		AgentBootID: agentConn.BootID,
		PhoneID:     phone.ID,
		CreatedAt:   time.Now(),
	}
	h.pairs[pairID] = pair
	h.phoneIndex[phone.ID] = pairID
	turn := auth.AllocTurn(h.turnSecret, pairID, h.turnHost)
	h.mu.Unlock()

	payload := map[string]interface{}{"t": "pair.ok", "pair_id": pairID, "agent_id": agentID, "turn": turn}
	h.Notify(phone.ID, payload)
	h.Notify(agentID, payload)
	log.Printf("[hub] pair created: %s agent=%s… phone=%s…", pairID, short(agentID), short(phone.ID))
	return BindResult{Status: "ok", Pair: pair}
}

// destroyLocked：销毁本体（调用方持锁）。不投递通知——通知由触发方完成（02 §2.1 约束 3）。
// §4.4：销毁时清除该 agent 的 ptok —— 销毁前生成的未过期 QR MUST 不可再绑定。
func (h *Hub) destroyLocked(pair *Pair, reason string) {
	if pair.GraceTimer != nil {
		pair.GraceTimer.Stop()
	}
	delete(h.pairs, pair.PairID)
	if pid, ok := h.phoneIndex[pair.PhoneID]; ok && pid == pair.PairID {
		delete(h.phoneIndex, pair.PhoneID)
	}
	for k, rec := range h.ptok {
		if rec.AgentID == pair.AgentID {
			delete(h.ptok, k)
		}
	}
	if h.DestroyHook != nil {
		hook := h.DestroyHook
		go hook(pair.PairID, reason)
	}
}

// ---- punch（撮合转发；绝不跨 pair 路由，§4.5）----

// RequestPunch：agent 离线（宽限期内）→ PEER_OFFLINE，不得静默丢弃（契约 §4.1）。
// ok=true 时返回当前 agent 连接（由调用方投递）。
func (h *Hub) RequestPunch(pair *Pair) (*Conn, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	agent := h.agents[pair.AgentID]
	if agent == nil {
		return nil, false
	}
	pair.LastPunchRequestAt = time.Now()
	return agent, true
}

// OfferAllowed：自发重发 ≥2s 限流（02 §3.3）；OfferRequestedWindow 内出现过的 punch.request 使 offer 不受限。
func (h *Hub) OfferAllowed(pair *Pair, now time.Time) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	requested := now.Sub(pair.LastPunchRequestAt) < OfferRequestedWindow
	if !requested && now.Sub(pair.LastOfferAt) < OfferMinGap {
		return false // 窗口内丢弃
	}
	pair.LastOfferAt = now
	return true
}

// ---- bye（条件①：显式撤销）----

// ProcessBye：验证发送代次 → 立即销毁 → （调用方）回 bye.ok → 转发对端（对端离线只回 bye.ok）。
// ok=false：过期代次 bye → 忽略（02 §2.1 约束 2）。pair 为 nil 且 ok=true：无 pair，仍回 bye.ok。
func (h *Hub) ProcessBye(sender *Conn) (pair *Pair, peerID string, ok bool) {
	h.mu.Lock()
	var pairObj *Pair
	if sender.Role == RoleAgent {
		pairObj = h.pairForAgentLocked(sender.ID)
	} else if pid, isPhone := h.phoneIndex[sender.ID]; isPhone {
		pairObj = h.pairs[pid]
	}
	if pairObj == nil {
		h.mu.Unlock()
		return nil, "", true
	}
	// 过期代次的 bye 忽略（02 §2.1 约束 2）：sender 必须是该 pair 当前的 agent 或 phone 连接
	current := h.agents[pairObj.AgentID] == sender || h.phones[pairObj.PhoneID] == sender
	if !current {
		h.mu.Unlock()
		return nil, "", false
	}
	var peer string
	if sender.Role == RoleAgent {
		peer = pairObj.PhoneID
	} else {
		peer = pairObj.AgentID
	}
	h.destroyLocked(pairObj, "bye (explicit revoke)")
	h.mu.Unlock()
	return pairObj, peer, true
}

// ---- sweeper（60s 无帧判离线；与 close 走同一条 GRACE 流程，02 §3.2）----

func (h *Hub) Sweep(now time.Time) {
	h.mu.Lock()
	var deadAgents, deadPhones []*Conn
	for id, c := range h.agents {
		if now.Unix()-c.LastAt > int64(SilentAfter.Seconds()) {
			deadAgents = append(deadAgents, c)
			delete(h.agents, id)
		}
	}
	for id, c := range h.phones {
		if now.Unix()-c.LastAt > int64(SilentAfter.Seconds()) {
			deadPhones = append(deadPhones, c)
			delete(h.phones, id)
		}
	}
	h.mu.Unlock()
	for _, c := range deadAgents {
		h.AgentOffline(c) // 同一条 GRACE 流程
	}
	for _, c := range deadPhones {
		h.PhoneOffline(c)
	}
}

func short(id string) string {
	if len(id) > 8 {
		return id[:8]
	}
	return id
}
