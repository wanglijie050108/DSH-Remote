// app 壳 —— 状态机（03 §4）与自愈
package dsh.mobile.app

import dsh.mobile.bridge.SignalEvent
import dsh.mobile.bridge.TurnBlock

/** 连接状态机：IDLE → SIGNALING → PUNCHING → CONNECTED →(丢链)→ RECONNECT；错误路径 → NEED_PAIR */
sealed class AppState {
    object Idle : AppState()
    object Scanning : AppState()
    object Signaling : AppState()
    object Punching : AppState()
    data class Connected(val sinceMs: Long) : AppState()
    data class Reconnecting(val reason: String) : AppState()
    data class NeedPair(val message: String) : AppState() // 错误文案按原因区分（03 §1 DoD）
    data class UpgradeRequired(val message: String) : AppState() // PROTO_VER_UNSUPPORTED：不重试不重扫
    data class Busy(val message: String) : AppState() // PAIR_LIMIT：服务繁忙，不自动重试
}

/** 错误码 → 用户文案矩阵（03 §3.3，均不静默失败） */
fun onSignalError(state: AppState, code: String, msg: String, isPassivePairReplaced: Boolean, act: (AppState) -> Unit) {
    when (code) {
        "PEER_OFFLINE" -> act(state) // 保持连接，等 presence 恢复后自动重试（不清配对、不断开）
        "PAIR_NOT_FOUND" -> act(AppState.NeedPair("请重新扫码"))
        "AGENT_RESTARTED" -> act(AppState.NeedPair("电脑上的 DSH 已重启，请重新扫码"))
        "PAIR_EXPIRED" -> act(AppState.NeedPair("PC 离线超过 24 小时，配对已失效，请重新扫码"))
        "PAIR_REPLACED" ->
            // §4.5 v1.0.5：主动换绑方（本地已绑定更新的 pair）MUST 忽略；被动方清配对提示重扫
            if (isPassivePairReplaced) act(AppState.NeedPair("已在另一台手机完成配对"))
        "PROTO_VER_UNSUPPORTED" -> act(AppState.UpgradeRequired("客户端版本过旧，请升级 App（重扫码无法解决版本偏差）"))
        "PAIR_LIMIT" -> act(AppState.Busy("服务繁忙，请稍后再试")) // 不自动重试
        "RATE_LIMITED", "INTERNAL" -> act(AppState.Reconnecting(code)) // 指数退避（SignalClient 已处理）
    }
}

/** 隧道重建触发（03 §4 三条）：ICE disconnected/failed（主）、15s 无帧（兜底）、网络切换回调 */
fun onTunnelInterrupted(connectedAtMs: Long?, now: Long, act: (AppState) -> Unit) {
    act(AppState.Reconnecting("tunnel lost"))
}

/**
 * 长中断自愈：隧道中断超过 10s 后重建完成时 MUST 主动 webView.reload()
 * （阈值 10s，用户 2026-09-13 裁决——低于前端最早停车点 12.75s；reload 代价极低、宁可多 reload，§4）
 */
fun shouldReloadOnReconnect(interruptedAtMs: Long?, reconnectedAtMs: Long): Boolean =
    interruptedAtMs != null && (reconnectedAtMs - interruptedAtMs) > 10_000L
