# 2026-09-20-026 · 真机 E2E：白屏机制全链定位 + ModuleLoader kick 修复 + 渲染层遗留

| 项 | 内容 |
|---|---|
| 类型 | 联调实测 + App 加固 |
| 触发来源 | 用户授权由本会话直接驱动真机验证页面 |
| 影响版本 | 契约 v1.0.5（无契约变更） |

## 真机 E2E 结果（HBN-AL80，HarmonyOS 6.1.0.135，Wi-Fi）

| 环节 | 结果 |
|---|---|
| 配对（pair-6，新 QR） | ✅ hello→pair.ok→punch 一次即中→READY（~500ms） |
| **三类候选** | ✅ `answer ready（host=1 srflx=1 relay=2）`（G1-H 判据②真机达成） |
| getStats 选中路径 | ✅ `prflx@192.168.1.13:47790 ↔ host@192.168.1.88:58411`，rtt 11ms，字节双向（**P2P 直连**，未走 relay） |
| 26s 闪断 | ❌ 复现：01:33:01 / 01:33:53（周期 ~52s≈2×26s），与模拟器同源（025 三方对照已定性 ArkWeb 特有） |
| DSH 页 DOM 层 | ✅ `readyState=complete`、AdGuard 无注入、小资源全 200、主 bundle 传输成功（49KB st=200） |
| DSH 页 UI 启动 | ❌ ModuleLoader 卡 queue：主模块 `@deepseek-ai/dsh-client-modules` 入队后**无人调 create**（断线打断主 bundle 执行所致）→ SPA 永不启动 |
| 截屏画面 | ❌ 即使 DOM 层文本渲染出来（131 字符），真机截屏仍白屏 |

## 白屏完整机制链（真机实锤）

1. 26s ICE 闪断（ArkWeb WebRTC 特有，025 已定性）；
2. 断线打断 `index-BKQ_L1z6.js`（主 bundle，49KB）的**执行**（传输已 200）——DSH 引导约定：主 bundle 末尾应调 `__ModuleLoader__.create({boot, recovery})` 启动模块系统；
3. create 未被调用 → `mode` 停在 `"queue"` → SPA 永不挂载 → 白屏；
4. 下一次断线 → App punch 重试自动重建隧道 → Web 组件条件重挂载 → 新页面再次卡在同一位置，循环。

## 本次交付

- **ModuleLoader kick（DshWebPage）**：`onPageEnd` 后 3s 探测 `__ModuleLoader__`，卡队列或 mode=queue 且 UI 未挂载时补调 `create({boot: __DSH_BOOT__, recovery: __DSH_CONNECTION_RECOVERY__})`。手动验证过该调用可让模块系统启动、队列消化、UI 文本渲染（btn=1, txt=131）。
- 引导自检日志：每次 onPageEnd 后回读引导状态进 hilog（`引导自检：...`），真机排障不再需要 CDP。

## 遗留（超出当前修复面，定性记录）

1. **【用户肉眼核验=空白，B 定性】** DOM 层有内容（whale widget 挂件独立脚本渲染，`__dshWhaleWidget` 全局存在）但屏幕全白 → **主 UI 未挂载 + 渲染层双重问题**。深挖结论：主 bundle 的 `create` 调用从未发生（mode 停 queue、q=1）；手动 create 因 options 不完整在 factory 内抛 TypeError（half-dead）；DSH 前端 boot 依赖 `__DSH_CONNECTION_RECOVERY__` 的 generationReady 流程（15s 超时）——在 26s 断线周期内永远走不完。**根因仍是 26s ICE 闪断**：它使「主 bundle 执行 → create → SPA 挂载」这条需要稳定网络的首次启动流程永远无法完成；whale widget 因独立脚本而幸存。
2. **26s 闪断本体（025）**——ArkWeb WebRTC consent/keepalive 缺陷，与上面互为因果。
3. **四功能验收搁置**：UI 承载不稳定，验收无意义；此为 ArkWeb 平台缺陷阻塞，非契约/协议实现缺陷。

## 对 ArkWeb 缺陷的证据包（上报华为用）

| 缺陷 | 证据 |
|---|---|
| ① WebRTC ICE 每 ~26s 断开 | 三方对照（025）：PC Chrome↔PC werift >100s 稳定；模拟器/真机 ArkWeb↔PC werift 均 ~26s 周期 disconnected；真机三类候选齐备仍断（host=1 srflx=1 relay=2）；werift consent 实现已核（CONSENT_TIMEOUT=30s 仅由有效响应刷新） |
| ② 复杂 SPA 经慢速/断续网络首次启动失败后无法自愈 | ModuleLoader mode=queue 卡死（q=1）、create 永不调用、generationReady 流程超时；whale widget（独立脚本）正常渲染 vs 主 UI 永不挂载；DOM complete 但视觉白屏 |

## 对迁移结论的影响（06 §6 回填）

- **契约/信令/隧道/TURN 结论 → 直接迁移 Android**（端无关）✅
- **G1 三判据 → 强证据成立**：①pin 双向 ✅ ②三类候选一次收齐 ✅（真机 host=1 srflx=1 relay=2）③16KiB 有序帧（模拟器/PC 侧已验，真机复验待 UI 层解锁）
- **26s ICE 与白屏 → 不可迁移**：Android 用原生 org.webrtc + WebView 加载，不经过 ArkWeb——这两个缺陷是 ArkWeb 平台特有，恰好落在 06 §6 迁移表的「不可迁移」侧

## R1 分支决策（06 §5，需用户拍板）

- **B-维持**：冻结当前 G1-H 证据，缺陷包上报华为，等平台修复后补四功能验收（成本最低）
- **B1-flutter_webrtc-ohos**：harness RTC 承载层换 flutter_webrtc 的 OpenHarmony 适配（06 §5 R1-B1 预案；绕开 ArkWeb 两个缺陷，G1 判据不变；架构改动 = RTC 回原生侧，JSBridge 帧中继废除）
- **B2-降级**：鸿蒙验证收敛为「信令+网络+隧道层」（已完成），G1 留待安卓设备（本方案已基本达成此状态）

## 回溯线索

- 前置：024（punch 重试/诊断埋点）、025（26s 三方定性）
- 后置：用户肉眼核验真机屏幕 → 决定「截屏路径问题」或「上报华为」；四功能验收顺延
