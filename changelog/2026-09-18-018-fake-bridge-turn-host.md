# 2026-09-18-018 · fake-bridge 的 TURN uris 写死 127.0.0.1 → 支持 TURN_HOST

| 项 | 内容 |
|---|---|
| 类型 | 代码 |
| 触发来源 | 缺陷发现（执行 new_docs/07 §B1-T0 A 路径部署前复核） |
| 影响版本 | 契约 v1.0.5（无契约变更）；`remotedsh-contract` 工作区 |
| 变更文件 | `remotedsh-contract/tools/fake-bridge.mjs`（3 处） |

## 改了什么

1. **顶部用法注释**：补 `[--turn-host 1.2.3.4]`。
2. **新增 `TURN_HOST` 配置**（`--turn-host` 参数 / `TURN_HOST` 环境变量，默认 `127.0.0.1`）：
   ```js
   const TURN_HOST = argOf('turn-host', process.env.TURN_HOST || '127.0.0.1')
   ```
3. **`allocTurn()` 改为复用契约共享实现**，删掉内联的 HMAC 与写死的 uris：
   ```js
   // 旧：uris: ['stun:127.0.0.1:3478', 'turn:127.0.0.1:3478?transport=udp', 'turn:127.0.0.1:3478?transport=tcp']
   // 新：
   import { allocTurn as allocTurnFor } from '../js/turn.mjs'
   function allocTurn(pairId, ttl = 3600) { return allocTurnFor(TURN_SECRET, pairId, TURN_HOST, ttl) }
   ```
   随之移除只服务于旧内联实现的 `createHmac` import。
4. `wss.on('listening')` 日志追加 `· turn_host=<值>`（运维可观测：一眼看出下发的地址对不对）。

## 为什么 / 依据

**缺陷**：`fake-bridge` 把 TURN uris 的 host 写成常量 `127.0.0.1`（旧第 40 行），而

- 契约 §5 定义的是 `turnUris(host)` —— `remotedsh-contract/js/turn.mjs` 第 16–18 行本就接收 host 形参；
- Go 版 bridge 有同名可配项：`remotedsh-bridge/README.md` 第 9 行 `env: SIGNAL_PORT / TURN_SECRET / TURN_HOST`，`internal/hub/hub.go` `TurnHost()`、`internal/hub/dispatch.go` 第 306 行 `auth.AllocTurn(..., d.Hub.TurnHost())`，其单测断言的正是 `turn:bridge.example.com:3478?transport=tcp`（`internal/auth/auth_test.go` 第 123 行）。
- new_docs/07 §F6 声明 fake-bridge 是 §4「可执行规格」、与 Go 版「行为一致性由契约测试保障」。

**后果（A 路径必然踩中）**：coturn 在 ECS（`114.55.114.12`，实测 `3478` 从本机可达），fake-bridge 也部署在 ECS；客户端是 PC 上的插件与模拟器内的 App。客户端拿到 `turn:127.0.0.1:3478` 后只会连自己的 loopback —— 插件侧 `lib/index.js` 第 126/139 行 `state.iceServers = msg.turn.uris.map((u) => ({ urls: u }))` **原样透传、不重写 host**，于是 relay 候选**静默缺失**，正好命中 SKILL.md §6 的陷阱行「Gathering before ensuring credentials → relay candidates silently absent」。T4（G1-H② 三类候选一次收齐）与 T7（relay-only 专项）在该部署下不可能通过。

**修法取向**：这是**工具向规格收敛**，不是改规格。默认值保持 `127.0.0.1`（向后兼容：coturn 与客户端同机的本机自测场景行为不变），A 路径显式传 `TURN_HOST=114.55.114.12`。新增配置项与 Go 版同名（`TURN_HOST`），两侧文档口径一致。

> 连带结论：new_docs/07 §B1-T0 A 路径第 3 步只写了 `TURN_SECRET`，缺 `TURN_HOST`；该文档已另立 changelog 019 修正。

## 验证

1. 语法：`node --check tools/fake-bridge.mjs` → exit 0。
2. 残留：`grep createHmac tools/fake-bridge.mjs` → 无输出（内联实现已删除）。
3. **活链路实证**（`TURN_HOST=1.2.3.4 node tools/fake-bridge.mjs --port 18080`，用一次性探针做 hello → `relay.request`）：
   ```
   <- {"t":"hello.ok","pair":null,"peer_online":false,"ts":1789731571106}
   <- {"t":"relay.alloc","turn":{"uris":["stun:1.2.3.4:3478",
        "turn:1.2.3.4:3478?transport=udp","turn:1.2.3.4:3478?transport=tcp"],
        "username":"1789735171:relay-bp02oUt5","credential":"3Kk0+7xVWSu3Z6bfXdiIfWELqoA=","ttl":3600}}
   URIS=["stun:1.2.3.4:3478","turn:1.2.3.4:3478?transport=udp","turn:1.2.3.4:3478?transport=tcp"]
   ```
   uris 随 `TURN_HOST` 变化 ✓；`username` 仍为 `<expire_epoch>:<pair_id>`、`credential` 仍为 base64 HMAC-SHA1、`ttl` 3600 ✓（契约 §5）。
   该探针同时复验了桥的 hello 验签与 `relay.request` 分发路径。
4. 全仓库检索确认无测试写死旧常量：`grep -r "127\.0\.0\.1:3478" test/ scripts/` → 无匹配。

## 回溯线索

- 前置：017（插件安装测试与联通链路排查方案，其 §F6 把 fake-bridge 定为 §4 可执行规格）
- 后续：019（new_docs/07 §A3-3 fp 判据纠正、§B1-T0 补 `TURN_HOST`、A2 装配验收实测）
- 关联：SKILL.md §6 陷阱表「Gathering before ensuring credentials」；契约 §5 第 250 行
- 未采纳的另一修法：在 ECS 上用 sed 就地改写、不改仓库 —— 会制造"线上行为与仓库源码不一致"的不可回溯状态，且 Go 版已有同名配置项，故不取。
