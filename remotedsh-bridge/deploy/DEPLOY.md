# remotedsh-bridge 部署清单（02 §6，一页可复现）

> 境内阿里云 `114.55.114.12`（EIP）。开发期信令走 `ws://<IP>:8080`（安全组仅放行开发者出口 IP，05 §0.1）；
> 上线切换 `wss://<域名>/v1/signal`（Caddy 自动签 Let's Encrypt）。

## 1. 前置
1. 域名 + DNS A 记录；**境内需 ICP 备案**（W8 硬期限，05 §0.1）【开放决策，02 §10】；
2. 云主机规格 ≥ 2C4G；确认 EIP 为固定公网 IP。

## 2. 防火墙 / 安全组（入方向）
| 端口 | 协议 | 用途 | 来源 |
|---|---|---|---|
| 443 | TCP | WSS（Caddy） | 0.0.0.0/0（上线后） |
| 3478 | **UDP+TCP** | STUN/TURN（TCP 是 UDP 被封的兜底） | 0.0.0.0/0 |
| 49160–49999 | UDP | TURN relay 段 | 0.0.0.0/0 |
| 8080 | TCP | **仅开发期**明文信令 | 仅开发者出口 IP |
| 22 | TCP | SSH | 仅管理 IP |

> 80/443 未备案时对外网页访问会被拦截；不影响 TURN（3478/relay 走非 80/443）。

## 3. 部署步骤
```sh
git clone <repo> && cd remotedsh-bridge/deploy
printf 'TURN_SECRET=<64 位随机>\nTURN_HOST=<域名或公网IP>\n' > .env && chmod 600 .env
# 编辑 turnserver.conf：<S> 改为与 .env 相同的 TURN_SECRET；<domain>、<公网IP>/<内网IP> 按实际填写
docker compose up -d
# 冒烟：应在 10s 内收到 error（缺 hello / hello 超时）即通
npx wscat -c wss://<domain>/v1/signal
```

## 4. 真实 IP（必做，02 §5.1）
- **默认不配 `trusted_proxies`**：Caddy 丢弃入站 XFF 并写入客户端地址 → Signal 取 socket 对端地址即正确；
- 若将来 Caddy 前真有可信代理：按可信跳数从右往左取，且 MUST 用 Caddy 全局选项 `servers > trusted_proxies`；
- Signal 8080 仅 compose 内网 `expose`，不对公网（否则「单 IP ≤16 限流」退化为「全站 16 连接」）。

## 5. 重启预案
`docker compose restart` —— 两端信令 <3s 重连（典型值；最坏受客户端退避档位影响）；
**pair 随内存清空而消失**，手机收 `hello.ok{pair:null}` 提示重新扫码（状态丢失，属预期，非故障）。

## 6. coturn 验证要点
- `turnutils_uclient -e 49160 -u <expire>:<pair_id> -w <credential> <host>` 实测 allocation（`use-auth-secret` + `lt-cred-mech` 同时生效）；
- `max-bps`（单会话）与 `bps-capacity`（整机合计）必须能被分别观测（02 §1 DoD）；
- coturn session/bytes 日志按 username（含 pair_id）统计 → 每对 ≤200MB/天 告警（部署侧脚本）。

## 7. ws:// → wss:// 切换时机（05 §4.3）
域名已解析且 Caddy 成功签发证书 → 改 QR 的 `s` 字段为 `wss://` 并把 8080 规则从安全组移除。

## 8. G1 阶段实装记录（2026-09-14，114.55.114.12）

G1 前置只需 coturn，未走 compose（Signal/Caddy 上线时再整体迁移），实装路径：

```sh
apt install -y coturn                          # Ubuntu 24.04 → coturn 4.6.1
echo '<64位随机密钥>' > /root/.turn_secret     # chmod 600；与 Signal 侧同源
# /etc/turnserver.conf 按 02 §4 写入，两处修正见下
systemctl enable --now coturn
```

**实测踩坑（已写入部署配置）**：
1. `log-file=` 要的是**文件路径**（`/var/log/turn/turn.log`）而非目录——给目录会让 coturn 每次启动报
   `Cannot open log file` 且 verbose 全丢（02 §4 预警的"各版本行为不一"实锤）；
2. 不要手加 `listening-ip=0.0.0.0` / `relay-ip=`——按文档默认（全地址）即可，显式指定反而不必要；
3. 安全组：`3478/UDP+TCP`、`49160-49999/UDP`（控制台端口范围格式用英文短横线 `49160-49999`）。

**验证（脚本在 remotedsh-contract/scripts/，可复跑）**：
- `verify-turn.mjs`：STUN 绑定 PASS（自见出口地址）+ 401 挑战 PASS；
- `verify-turn-werift.mjs`（项目真实栈）：**host=4 / srflx=4 / relay=1，三类候选一次收齐** —— G1 判据②服务器侧达成；
- pion/turn（独立 Go 客户端）：ALLOCATE PASS（relay 114.55.114.12:49972）；
- `turnutils_uclient`（coturn 自带工具）对本机分配报 "unknown allocate response"——实测工具怪癖，以上述三类客户端为准。

排障期间曾误停服务导致客户端全部超时——**凡"所有客户端同时超时"，先查服务是否真的在监听**（`ss -lnup | grep 3478`）。

生产前待办：关闭 `verbose`（公网 TURN 开 verbose 会大量写日志）。
