// TURN 凭证签发（契约 §5）：username = "<expire_epoch>:<pair_id>"，credential = base64(HMAC-SHA1(S, username))
// 纯计算模块：Bridge（Go）与本仓库 fake-bridge 共用同一算法；S 仅存在于 Bridge 与 coturn 部署环境（不下发）
import { createHmac } from 'node:crypto'

export const TURN_TTL_SECONDS = 3600 // 契约 §5

export function turnUsername(pairId, ttlSeconds = TURN_TTL_SECONDS, nowSec = Math.floor(Date.now() / 1000)) {
  return `${nowSec + ttlSeconds}:${pairId}`
}

export function turnCredential(secret, username) {
  return createHmac('sha1', secret).update(username).digest('base64')
}

/** uris 按 §5 固定三元：STUN + TURN/UDP + TURN/TCP（UDP 被封网络的兜底） */
export function turnUris(host) {
  return [`stun:${host}:3478`, `turn:${host}:3478?transport=udp`, `turn:${host}:3478?transport=tcp`]
}

export function allocTurn(secret, pairId, host, ttlSeconds = TURN_TTL_SECONDS, nowSec = Math.floor(Date.now() / 1000)) {
  const username = turnUsername(pairId, ttlSeconds, nowSec)
  return { uris: turnUris(host), username, credential: turnCredential(secret, username), ttl: ttlSeconds }
}
