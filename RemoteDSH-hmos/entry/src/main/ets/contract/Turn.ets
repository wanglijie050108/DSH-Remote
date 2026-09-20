// TURN 凭证（契约 §5）——纯计算 port（对齐 remotedsh-contract/js/turn.mjs）
// username = "<expire_epoch>:<pair_id>"；credential = base64(HMAC-SHA1(S, username))
// S 仅存在于 Bridge 与 coturn；App 只透传 pair.ok/relay.alloc 收到的凭证，本模块用于自测与校验语义。
import { hmacSha1 } from './Digest';
import { utf8Encode, bytesToBase64 } from './Codec';

export const TURN_TTL_SECONDS: number = 3600

export function turnUsername(pairId: string, ttlSeconds: number, nowSec: number): string {
  return `${nowSec + ttlSeconds}:${pairId}`
}

export function turnCredential(secret: string, username: string): string {
  return bytesToBase64(hmacSha1(utf8Encode(secret), utf8Encode(username)))
}

/** uris 按 §5 固定三元：STUN + TURN/UDP + TURN/TCP */
export function turnUris(host: string): string[] {
  return [`stun:${host}:3478`, `turn:${host}:3478?transport=udp`, `turn:${host}:3478?transport=tcp`]
}

/** pair.ok/relay.alloc 下发的 turn 块形状（ArkTS 侧收窄用） */
export class TurnBlock {
  public uris: string[] = []
  public username: string = ''
  public credential: string = ''
  public ttl: number = TURN_TTL_SECONDS
}
