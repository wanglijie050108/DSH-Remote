# remotedsh-bridge

presence-only 服务端：WSS 信令（Go）+ coturn（STUN/TURN 兜底）+ Caddy（TLS/WSS）。
方案依据 `new_docs/02-服务端实施方案(2).md` v1.2（契约 `new_docs/00-接口契约(2).md` v1.0.5）。

## 组件

```
cmd/signal/main.go     入口（env: SIGNAL_PORT / TURN_SECRET / TURN_HOST）
internal/hub/          连接管理、pair 表、boot_id 比对、宽限期计时器、双向唯一性、TTL sweeper、协议分发
internal/auth/         P-256 验签（复用 remotedsh-contract/go 与共享向量）、pair_token、TURN 凭证签发
internal/limit/        单 IP 连接数、消息速率、帧大小上限、hello 超时、pair_token 猜测锁定
deploy/                compose.yaml / Caddyfile / turnserver.conf / Dockerfile.signal / DEPLOY.md
```

## 关键行为（与契约逐条对应）

| 项 | 位置 | 依据 |
|---|---|---|
| `t` 封闭集合，未知类型 error+关闭；永不实现通用转发 | `hub/dispatch.go` | §4 |
| hello 门禁 10s / proto_ver 严格 / ±60s / nonce ≥120s / 规范化字节串验签 | `hub/dispatch.go` + `auth` | §4.1–4.2 |
| pair 销毁五条件全部主动推送对端 | `hub/lifecycle.go` | §4.3 |
| 踢旧连接不误删新 pair；过期代次 bye 忽略 | `hub/lifecycle.go`（Stale/Gen） | §4.3 / 02 §2.1 约束 1/2 |
| 宽限期 T=24h 每次断开重新起算 | `hub/lifecycle.go` | §4.3（用户决策） |
| pair 上限 256 超限 `PAIR_LIMIT` 不淘汰 | `hub/lifecycle.go` | §4.5（用户决策） |
| 每 agent / 每 phone 至多 1 pair（条件④⑤双向唯一性） | `hub/lifecycle.go` | §4.3 v1.0.5 |
| `punch.request` 离线回 `PEER_OFFLINE` 不静默丢弃 | `hub/dispatch.go` | §4.1 |
| 自发 punch.offer ≥2s 限流（request 触发不受限） | `hub/lifecycle.go` `OfferAllowed` | 02 §3.3 |
| pair_id 断言失败回 `PAIR_NOT_FOUND` 并告警，绝不跨 pair 路由 | `hub/dispatch.go` | §4.5 |
| TURN 凭证 `username=<expire>:<pair_id>` HMAC-SHA1；「续期」不重新 allocate | `internal/auth` | §5 |
| 无数据库、无业务字节 | 全部状态内存态 | §4/02 §1 |

## 测试

```sh
go test ./...
```

- `internal/auth`：直接消费 `remotedsh-contract/vectors/hello-signature.json` 共享向量（G2 门禁）+ TURN 凭证 + ts/nonce 门禁；
- `internal/hub`：pair 生命周期语义（手机断开保留 / 抖动免扫码 / DSH 重启销毁+推送 / bye 立即销毁+转发 / 宽限重新起算 / 条件④⑤ PAIR_REPLACED / 踢旧不误删 / 销毁清 ptok / PAIR_LIMIT 不淘汰）。

## 运行

见 `deploy/DEPLOY.md`（一页可复现：compose + 配置 + 防火墙清单 + ws→wss 切换时机）。
