# 改动索引（新记录在上）

| 编号 | 日期 | 类型 | 主题 | 影响文件 | 版本 |
|---|---|---|---|---|---|
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
