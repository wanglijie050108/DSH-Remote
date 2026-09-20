# 改动索引（新记录在上）

| 编号 | 日期 | 类型 | 主题 | 影响文件 | 版本 |
|---|---|---|---|---|---|
| 028 | 2026-09-20 | 总结 / 复盘 | 鸿蒙阶段总结（015–027 + 027 后进展）：双应用路线复盘（原生 ArkWeb 冻结 = ArkWeb 平台缺陷锁死，非协议失败；Flutter 三理由保留）；**26s 闪断定性修正**——025「ArkWeb 特有」是错的，根因为 P2P 路径中间设备周期掐 UDP，换栈无效；Flutter 现状 7 项问题清单（relay 锚定待 DSH 重启终验等） | changelog/028、SYTKILLER/DSH-Remote-Hmos（新仓库：两应用代码 + README + LICENSE + 本 changelog） | 契约 v1.0.5（无契约变更） |
| 027 | 2026-09-20 | 架构迁移（B1）+ 契约层 | B1 启动：flutter_webrtc-ohos 确认为原生 libwebrtc（libohos_webrtc.so NAPI，绕开 ArkWeb 26s 闪断）；契约层 Dart 参考实现入契约仓库（与 go/js/kotlin 平级，G2 向量 dart test 全绿含 RFC6979）；Flutter OHOS 工具链落地（dev 分支 3.7.12-ohos + 3 处 flutter_tools 补丁）；RemoteDSH-flutter App 真机 UI 首跑 ✓（三方 vendor + 签名复用）；待 QR 做 E2E | remotedsh-contract/dart/*、RemoteDSH-flutter/*、D:\flutter-ohos（3 补丁）、changelog/027 | 契约 v1.0.5（新增 dart/ 实现） |
| 026 | 2026-09-20 | 实测+加固 | 真机 E2E：三类候选达成（host=1 srflx=1 relay=2）、getStats 证实 P2P 直连（rtt 11ms）；白屏机制全链定位——26s 闪断打断主 bundle 执行 → ModuleLoader 停 queue 无人 create → SPA 永不启动；交付 ModuleLoader kick（onPageEnd 后自动补 create）+ 引导自检日志；遗留：DOM 渲染但截屏仍白（ArkWeb 合成层问题，待用户肉眼核验） | RemoteDSH-hmos/pages/DshWebPage.ets、changelog/026 | 契约 v1.0.5（无契约变更） |
| 025 | 2026-09-20 | 实测（取证） | P2P/中继取证（getStats 选中对 192.168.1.88↔192.168.1.88 + coturn 零连接 = 走 P2P 未走服务器，架构符合规划）；26s 闪断三方对照定性：PC Chrome↔PC werift >100s 零闪断 → **werift 无罪，26s 为 ArkWeb↔外部互通特有**（模拟器/真机同源）；对策=App 容忍+上报华为；沉淀 consent 探针对脚本 | remotedsh-contract/scripts/{consent-probe,answer-probe}.mjs、changelog/025 | 契约 v1.0.5（无契约变更） |
| 024 | 2026-09-19 | 实测+加固 | 空白页双根因实锤：① AdGuard 按进程过滤 node.exe 响应并注入脚本（暂停后页面立即出内容）② 模拟器 ICE 恰好 26s 周期闪断（host-only 候选、与 AdGuard 无关、自动重建正常）——判定为模拟器环境限制，26s 是否随真机 srflx/relay 出现而消失 = G1-H 头号判定点；App 交付 punch 重试（25s×6）+ DSH 页全量诊断埋点 + ArkWeb 远程调试基建 | RemoteDSH-hmos/{service/HarnessService,pages/DshWebPage,entryability/EntryAbility}.ets、changelog/024 | 契约 v1.0.5（无契约变更） |
| 023 | 2026-09-19 | 代码（缺陷修复 ×4）+部署+实测 | 鸿蒙 E2E 四缺陷：hello DER 透传+双钥持久化（cryptoFramework sign/verify 仅 DER、convertKey 单材料、getEncodedDer 取值勘误）、parsePairQr 畸形输入崩 UI、DSH 页面 launchToken 401、fake-bridge 限流计数器永不清零（40 消息后连接僵尸化+连带 dsh exit 1，ECS 已部署）；模拟器全链路打通（自测 40/40、粘贴 QR→READY、DSH 页带 token 渲染） | RemoteDSH-hmos/{contract/Hello,QrPair,DerEcdsa,service/HarnessService,pages/DshWebPage}.ets、remotedsh-contract/tools/fake-bridge.mjs、ECS /opt/dsh-bridge、changelog/023 | 契约 v1.0.5（无契约变更） |
| 022 | 2026-09-19 | 代码（缺陷修复）+实测 | 插件 rebuild 挂死修复：werift 非 trickle gather 无超时→rebuilding 常驻 true 静默吞 punch.request（TCP 字节计数证据链）→rtc.js 20s gather 看门狗 + index.js 30s 强制解锁；模拟器 E2E 半程实测（RTC 就绪/hello/relay.alloc 3 uris/punch 阻塞定位） | dsh-mobile-link/lib/{rtc,index}.js、changelog/022 | 契约 v1.0.5（无契约变更） |
| 021 | 2026-09-18 | 部署 | ECS bridge 上线（018 补丁版 + turn.mjs + TURN_HOST=114.55.114.12）+ dsh-signal.service 常驻 + secret 与 coturn 核实一致 + 本机 WS 101 冒烟；安全组 8080 生效但授权对象为 0.0.0.0/0（纪律偏差，收窄待拍板）；019 交接①解除、②收录 | ECS /opt/dsh-bridge、dsh-signal.service、/etc/dsh-signal.env、changelog/021 | 契约 v1.0.5（无契约变更） |
| 020 | 2026-09-18 | 代码+方案 | 校验脚本锚点过期修正（F9/F10：`CONNECTION_DEFAULTS` 字面量在 0.1.5-rc.2 已内联进 Schema → 改锚点并补"重试无上限"否定断言）+ SKILL.md §3 安装路径更正（`D:\npm-global` 已不存在）+ 第 9 行"前端 12.75–25.5s 后放弃"前提更正（**reload 决定不撤销**，降级为待实测 T5b）；`docs/03` §4 只报告不改 | verify-dsh-facts.mjs、SKILL.md（3 处）、changelog/020 | 契约 v1.0.5（无契约变更） |
| 019 | 2026-09-18 | 方案+留档 | 插件安装/装配实测留档（A1 三步 + A2 四判据全绿 + A3-1/2 走通 QR 仅印一次 + 单实例约束）+ new_docs/07 六处修正（**§A3-3 fp 判据写错**按契约 §2 更正、§B1-T0 补必需的 `TURN_HOST` 与 `js/turn.mjs`、出口 IP 改为每次重查、先证实有人在听、新增 T5b 自愈实测） | new_docs/07（6 处）、changelog/019 | 契约 v1.0.5（无契约变更） |
| 018 | 2026-09-18 | 代码 | 缺陷修复：fake-bridge 的 TURN uris 写死 127.0.0.1（A 路径下 relay 候选静默缺失，T4/T7 不可能通过）→ 新增 `TURN_HOST`（与 Go 版同名）+ 复用契约 `js/turn.mjs`；活链路实证 uris 随配置变化 | remotedsh-contract/tools/fake-bridge.mjs（3 处）、changelog/018 | 契约 v1.0.5（无契约变更） |
| 017 | 2026-09-18 | 方案 | 插件安装测试与联通链路排查方案：git 同步确认 + 新发现（插件依赖未装、线上 bridge 未部署且 Go 版缺 main、出口 IP）+ link 安装方案 + T0–T7 阶梯与 12 条排查表 | new_docs/07（新建）、changelog/017 | 契约 v1.0.5（无契约变更） |
| 016 | 2026-09-18 | 代码 | 鸿蒙 harness 工程实现：契约/信令/RTC(ArkWeb)/隧道/代理/编排/UI 全层落地，G2 向量 PC 验证 14/14 + 双编译门禁 GREEN；真机待 H0 签名 | RemoteDSH-hmos/（新建工程）、changelog/016 | 契约 v1.0.5（无契约变更） |
| 015 | 2026-09-18 | 方案 | 鸿蒙真机验证方案（harness）：ArkWeb 承载 WebRTC + ArkTS 契约 port，H0–H5 门禁；不改 Android-first 路线 | new_docs/06（新建） | 契约 v1.0.5（无契约变更） |
| 014 | 2026-09-17 | 代码 | Android 接线完成：PairQR + RtcEngine 重写 + AppViewModel + MainActivity 扫码头；复核修复 6 bug | 7 新建/重写 + 3 修改（见详情） | 契约 v1.0.5 |
| 013 | 2026-09-17 | 代码 | Ponytail 审查：删除 hub.go 死常量 SweeperPeriod，统一命名 | hub.go、server.go | 契约 v1.0.5 |
| 012 | 2026-09-17 | 工具 + 代码 | 补充开发 Skill：新增 5 陷阱 + Android 已知占位符 §9 + 契约版本勘误；011 代码修复 | SKILL.md、verify-dsh-facts.mjs、server.go、bridge.js、SignalClient.kt、MainActivity.kt、Frames.kt | 契约 v1.0.5 |
| 011 | 2026-09-17 | 代码 | 代码质量修复：Go WebSocket 重复关闭、JS 回调覆盖、Android Thread.sleep 阻塞 / Compose state 不可观测 / Frames 有符号截断 | server.go、bridge.js、SignalClient.kt、MainActivity.kt、Frames.kt | 契约 v1.0.5（无契约变更） |
| 010 | 2026-09-14 | 部署 + 代码 | coturn 部署到 114.55.114.12 并三层客户端验证：werift 三类候选一次收齐（G1 判据②服务器侧达成）+ pion Allocate PASS | deploy/DEPLOY.md §8、scripts/verify-turn*.mjs | 契约 v1.0.5 |
| 009 | 2026-09-13 | 方案 | 回填 W1 发现：werift RTCCertificate 第三参须为 {hash,signature} 枚举（01 §3 + SKILL §3/§6 两行陷阱，用户批复） | new_docs/01、SKILL.md | 契约 v1.0.5（无契约变更） |
| 008 | 2026-09-13 | 代码（验证留档） | 用户质询驱动：Go 版 bridge 补做线上测试（hello.ok 9ms / 负例 AUTH_FAILED / 全链路 pair.ok + 隧道回环 50KB PASS，零修补） | 无文件改动 | 契约 v1.0.5 |
| 007 | 2026-09-13 | 代码 | S5 安卓源码树初建：core-contract/rtc/proxy/pairing/bridge + app 壳（无 SDK 仅源码） | remotedsh-android/（新建） | 契约 v1.0.5 |
| 006 | 2026-09-13 | 代码 | S4 服务端 Go 实现：hub 生命周期五条件/auth 共享向量/limit + deploy 全套，go test 全绿 | remotedsh-bridge/（新建） | 契约 v1.0.5 |
| 005 | 2026-09-13 | 代码 | S3 插件完整实现：装配/隧道/配对/信令七模块，16 单测 + 集成 E2E PASS（真实插件全链路回环） | dsh-mobile-link/（新建） | 契约 v1.0.5 |
| 004 | 2026-09-13 | 代码 | S2 契约仓库初建：向量+JS/Go/Kotlin 三端实现+fake-bridge/phone/agent+E1/E3 脚本；**W1 发现：werift RTCCertificate 第三参须为 {hash,signature} 枚举** | remotedsh-contract/（新建） | 契约 v1.0.5 |
| 003 | 2026-09-13 | 方案 | 终检修复：插件侧 PAIR_REPLACED 处理等 5 缺口 + 2 项边界钉死（15 处编辑） | new_docs/00、01、03 | 契约 v1.0.5（变更日志⑦补记） |
| 002 | 2026-09-13 | 方案 | 第五轮一致性修复：7 项遗留问题（10 处编辑） | new_docs/00、01、03 | 契约 v1.0.5（变更日志 v1.0.5 行补齐） |
| 001 | 2026-09-13 | 决策留档 | 方案基线回溯（契约 v1.0.0 → new_docs v1.0.5 正文，本目录建立前的全部演进） | —（无文件改动） | 契约 v1.0.0–1.0.5 |
