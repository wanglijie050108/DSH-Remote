# 当前问题台账

> 动态维护文件；最后核对：2026-09-20，分支 `qc_relay_anchor`。
>
> `未解决` 与 `验证中` 始终放在前面；只有代码、测试和适用的真机/线上验证全部完成后，才能移入文末的 `已解决`。历史事实仍由编号 changelog 追加记录，本文件只维护当前状态。

## 未解决

| ID | 优先级 | 状态 | 问题 | 引入原因 | 当前证据 | 关闭条件 |
|---|---|---|---|---|---|---|
| ISS-004 | P0 | 验证中 | Flutter 信令断线不会自动重连 | `SignalClient` 关闭时只停心跳，没有向 Harness 回调；初连失败反而进入 `needPair` | 已增加主动/被动关闭区分、generation 隔离和 500ms→30s 抖动退避；测试已写，当前 Mac 无 Flutter 3.7/OHOS SDK，待执行 | 500ms→30s 抖动退避；断网恢复无需重新扫码 |
| ISS-005 | P0 | 验证中 | Flutter 免扫码恢复在 `hello.ok{pair:null}` 时崩溃或发送旧 token | 扫码与恢复共用 `pairing` 状态，未区分 fresh `ptok`；`_pendingPt!` 强制解包且成功配对后不清理 | 改为 `OneShotPairToken.take()`；resume 明确清空 fresh token，无 token 时进入 NEED_PAIR；测试已写待 Flutter 环境执行 | 无 fresh token 时进入 NEED_PAIR；token 用后即弃；覆盖冷启动恢复测试 |
| ISS-006 | P0 | 验证中 | Flutter WINDOW 信用提前回填 | socket 部分写入或尚在 pending 时，按完整 payload 计为“实际写入” | 首写和 flush 均只累计 `RawSocket.write()` 返回值；脚本化部分写回归已写待 Flutter 环境执行 | 仅按每次 `RawSocket.write()` 返回值累计；部分写入测试通过 |
| ISS-007 | P0 | 验证中 | Flutter 收到 FIN 后过早关闭双向 socket | `_maybeClose` 只检查 `finRecv` 和待写队列，未等待本地发送方向结束 | 已延迟 send shutdown 至 pending 清空，并等待双向 FIN；loopback 半关闭回归已写待 Flutter 环境执行 | 收到 FIN 后继续读取并转发，直到双向终态；半关闭集成测试通过 |
| ISS-008 | P1 | 未解决 | Flutter 隧道中断超过 10s 后没有主动 reload WebView | Flutter 迁移只实现 ModuleLoader queue 探针，没有记录中断时长或隧道恢复通知 | `RemoteDSH-flutter/lib/` 无对应恢复路径；`new_docs/03` §4 要求 | 恢复回调按中断时长触发一次 reload；短/长中断测试通过 |
| ISS-009 | P1 | 验证中 | 双端 relay-only 是否能消除周期断线尚未验证 | P2P 路径不稳定；此前 TURN 配置缺陷使中继路径从未完整工作 | changelog 028/029；当前分支仅完成代码和 Node 测试 | offer/answer 仅 relay、getStats 选中 coturn，真机连续稳定至少 10 分钟并完成业务验收 |
| ISS-010 | P1 | 未解决 | Flutter 将私钥、TURN 凭证和 launch token 明文落盘，并把 token 写入日志 | harness 从验证代码直接迁移，未接入平台安全存储和日志脱敏 | `harness.dart:85-108`、`dsh_web_page.dart:56-58` | 私钥进系统密钥设施，敏感状态加密或不持久化，日志不含 token/credential |
| ISS-011 | P1 | 未解决 | Flutter WebView 未限制非 loopback 导航，也未处理主页面 401 | Flutter WebView 只配置完成/资源错误回调，未移植 App 方案的安全清单 | `dsh_web_page.dart:31-45`；`new_docs/03` §3.4 | 拦截非 loopback、新窗口和下载；主框架 401 给出重新配对提示 |
| ISS-012 | P1 | 未解决 | Flutter 错误矩阵只写了文案，部分动作未实现 | `RATE_LIMITED/INTERNAL` 没有实际退避；主动换绑时 `PAIR_REPLACED` 仍无条件清新状态 | `signal_client.dart:67-86`、`harness.dart:277-293` | 每个错误码有对应状态迁移和自动化测试 |
| ISS-013 | P1 | 未解决 | Flutter 没有处理 DataChannel 参数错误/未知通道 | 迁移时只按 label 收集，未知 label 仅记日志，不断开；未核对 ordered/reliable 参数 | `rtc_link.dart:28-35`、`harness.dart:383-397` | data/ctl 参数逐项校验；未知、重复、不完整通道均关闭连接 |
| ISS-014 | P1 | 未解决 | 周期断线根因尚未定案 | 028 将“P2P 中间设备掐 UDP”从假设写成结论，但尚无双端 relay 对照长稳 | changelog 028 与 029 修正 | relay-only 对照实验形成可重复证据；失败时继续 consent/系统网络层调查 |
| ISS-015 | P1 | 未解决 | 断线会打断 HTTP 子资源并导致 SPA 白屏 | WebView 不重试失败子资源，ModuleLoader 停在 queue；根因依赖隧道稳定性 | changelog 026/028 | 稳定链路下四功能页面无白屏；故障注入后可自动恢复 |
| ISS-016 | P2 | 未解决 | ctl 小帧在断线窗口疑似丢失 | 观测到 PING/PONG 消失而大流量仍可通过，尚无完整收发对拍 | changelog 028 §五 #4 | 双端带序号日志确认丢失层级并修复或排除 |
| ISS-017 | P2 | 未解决 | 关闭 VPN 后 ICE 直接 Failed | 网络路径变化后 15s 协商超时，尚未在有效 relay-only 下复测 | changelog 028 §五 #5 | relay-only 与自动择路分别复测并给出候选/错误证据 |
| ISS-018 | P2 | 未解决 | OHOS WebView `runJavaScriptReturningResult` 疑似挂起 | vendor 实现/回调链不稳定；现有页面探针仍调用该接口 | `dsh_web_page.dart:64-91`、changelog 028 §五 #6 | vendor 修复或完全移除依赖；重复探针无挂起 |
| ISS-019 | P2 | 未解决 | Flutter UI 没有真正扫码能力 | B1 首版仅提供粘贴 URI 的验证入口，README/changelog 将其概括为扫码 | `main.dart:132-153` | 接入相机扫码并完成权限、取消、错误路径验证 |
| ISS-020 | P2 | 未解决 | 四项业务功能尚未验收 | 周期断线和白屏阻断了列会话、历史、发消息、审批作答 | changelog 026/028 | 四项在真机 relay 与自动择路路径分别完成验收 |
| ISS-021 | P2 | 未解决 | 部署安全组 8080/TCP 对全网开放 | 开发期为绕过出口 IP 变化临时使用 `0.0.0.0/0` | changelog 021 | 收窄到明确来源或迁移到有认证加密的正式入口 |
| ISS-022 | P2 | 未解决 | changelog 引用的方案、NOTICE 和工具链文件缺失，Skill 校验锚点仍旧 | 015–028 从另一工作树补录时只带入部分产物 | 缺 `new_docs/06`、`new_docs/07`、`RemoteDSH-flutter/NOTICE.md`、`b1-recon/env.sh`；020 所述 Skill/脚本修改未落地 | 找回原产物或新增纠正记录明确废弃；校验脚本在当前 DSH 安装上通过 |
| ISS-023 | P2 | 未解决 | Android 真机门禁仍未执行 | 当前只有鸿蒙设备，Android org.webrtc/明文 loopback/ABI 未实测 | Skill §9、`new_docs/03` §1 | Android 真机完成 G1/E4、DataChannel 和 ABI 验证 |
| ISS-024 | P2 | 未解决 | 原生 Hmos 路线仍有周期断线、白屏和不可观测问题 | ArkWeb 承载 RTC 与复杂 SPA，平台限制无法在应用层稳定修复 | changelog 025/026/028 | 当前冻结；若恢复路线，须先完成 relay 长稳和四功能验收，否则正式标记废弃 |
| ISS-025 | P2 | 未解决 | `dsh exit 1` 是否存在独立崩溃路径未定 | 只在 RATE_LIMITED 僵尸风暴期间出现，源头修复后的长期证据未归档到仓库 | changelog 023 §“dsh exit 1 判定” | 修复 ISS-002 后长稳验证；若复现，保留退出追踪和堆栈 |

## 已解决

| ID | 状态 | 问题 | 引入原因 | 解决方式 | 验证证据 | 解决日期 / 记录 |
|---|---|---|---|---|---|---|
| FIX-001 | 已解决 | 鸿蒙 hello 签名格式错误 | 错把 cryptoFramework 的 DER 输出当成裸 `r‖s` 再编码 | 原生 DER 直接透传并校验 `0x30` | 设备 G2 40/40 | 2026-09-19 / 023 |
| FIX-002 | 已解决 | 鸿蒙恢复私钥后缺失公钥 | `convertKey` 只提供 PKCS8，平台返回的 KeyPair 没有 pubKey | 同时持久化 PKCS8 与 SPKI，并双材料恢复 | 旧数据迁移实测 | 2026-09-19 / 023 |
| FIX-003 | 已解决 | 畸形 QR 百分号编码导致 UI 崩溃 | `decodeURIComponent` 异常未捕获 | 参数解码捕获并返回 `BAD_ENCODING` | `QrPair.ets` 错误路径 | 2026-09-19 / 023 |
| FIX-004 | 已解决 | 鸿蒙 DSH 页面因丢失 launch token 返回 401 | QR 解析后未把 `t` 带入页面 URL | PairState 持久化 token，页面首次加载携带 token | 模拟器页面渲染 | 2026-09-19 / 023 |
| FIX-005 | 已解决 | Flutter OHOS 丢弃列表形式 ICE URLs | vendor 只按字符串取 `url/urls`，上层曾整列表下发 | 每个 URI 拆为单独 ICE server，并保留 TURN 凭证 | answer `host=12/srflx=2/relay=4`；coturn ALLOCATE/CREATE_PERMISSION 成功 | 2026-09-20 / 027–028 |
| FIX-006 | 已解决 | AdGuard 向 DSH HTML 注入脚本造成白屏 | AdGuard 按 `node.exe` 进程过滤 loopback 响应 | 暂停过滤/加入 loopback 与进程白名单 | 暂停后页面立即出现内容 | 2026-09-19 / 024 |
| ISS-001 | 已解决 | 仓库版 fake-bridge 下发的 TURN 地址写死 `127.0.0.1` | 018 的修复只落在外部工作树/ECS，合入 015–028 时未带入源码 | 恢复 `TURN_HOST`/`--turn-host`，复用共享 `allocTurn` | 黑盒测试收到 `198.51.100.7` 三元 URI；契约测试 15/15 | 2026-09-20 / 031 |
| ISS-002 | 已解决 | fake-bridge 限流计数器不清零 | “2s 窗口”只有注释和上限，没有窗口起点及复位代码；023 的 v2 补丁未随源码合入 | 每个连接记录 `windowStartedAt`，满 2s 原子复位计数 | 黑盒测试前 40 条通过，跨窗口第 41 条仍返回 pong | 2026-09-20 / 031 |
| ISS-003 | 已解决 | 插件 gather/rebuild 可能永久挂死 | werift 非 trickle gather 无超时，`rebuilding` 是无超时布尔锁；022 补丁未随源码合入 | 20s gather 超时关闭 peer；30s generation 看门狗强制解锁并隔离迟到结果 | 挂起 Promise 回归测试；插件测试 18/18；fallback E2E PASS | 2026-09-20 / 031 |
