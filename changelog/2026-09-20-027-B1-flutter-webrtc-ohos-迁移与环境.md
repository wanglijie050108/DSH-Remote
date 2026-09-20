# 2026-09-20-027 · B1 迁移启动：flutter_webrtc-ohos 原生栈 + Dart 契约层 + 真机首跑

| 项 | 内容 |
|---|---|
| 类型 | 架构迁移（B1）+ 契约层新增 |
| 触发来源 | 用户拍板「可以尝试B1-flutter_webrtc-ohos」（026 结论：四功能验收被 ArkWeb 平台缺陷阻塞） |
| 影响版本 | 契约 v1.0.5（新增 Dart 参考实现，无协议变更） |

## B1 侦察结论（为什么 B1 值得做）

- `fluttertpc_flutter_webrtc`（OpenHarmony-SIG，Gitee 已归档 → 真身 gitcode）**底层是 11MB `libohos_webrtc.so` 原生 libwebrtc（NAPI 模块）**，ArkTS 层 `import { RTCPeerConnection } from 'libohos_webrtc.so'`——与 ArkWeb 完全两套栈，26s ICE 闪断（ArkWeb 特有，025/026 定性）理论上不再适用。
- 插件成熟度超预期：CHANGELOG 0.9.48_hotfix.1-ohos-1.0.0（质量加固版）完成 278 个 Dart 接口单测、DataChannel 二进制收发（`dataChannelSend isBinary`）、`bufferedAmount`/`onBufferedAmountLow`（隧道流控依赖）、ICE servers username/credential（TURN）、`onIceGatheringState`（非 trickle）全部具备；本 harness 只用 DataChannel（不用摄像头/音频/渲染——恰好绕开插件最脆弱部分）。
- 宿主要求：Flutter OHOS SDK（flutter_flutter **dev** 分支 = 3.7.12-ohos，Dart 2.19.6；3.22.1-ohos 分支实为纯上游无 ohos 工具链）。

## 本次交付

1. **契约层 Dart 参考实现**（`remotedsh-contract/dart/`，与 go/js/kotlin 平级）：
   - `frames.dart`（11B 帧头 + FrameSplitter）/ `qr_pair.dart` / `fingerprint.dart` / `turn.dart` / `hello.dart`（pointycastle，RFC6979 确定性签名 + 随机签名）/ `ec_key.dart`（自带最小 DER 读写，PKCS8/SPKI 往返）。
   - **G2 向量测试全绿**（`dart test`）：frames 14 例（含 construct 超限/flags 容忍/stream_id 读侧语义）、hello-signature 6 例（canonicalBytes 逐字节 + 验签 + DER 形态；RFC6979 与 @noble 同源）、qr-pair 5 例、fingerprint-normalize 7 例；TURN HMAC 与 node 对拍 `j9uW1dRkpmogBUOlB9gxYYE37zk=`。
   - App 经 path 依赖引用，消除双份实现漂移。
2. **Flutter OHOS 工具链落地**（D:\flutter-ohos + b1-recon/env.sh）：doctor HarmonyOS toolchain ✓；三个 flutter_tools 补丁（ohpm.bat 解析 / FLUTTER_SKIP_TAG_FETCH / wrapper OS 覆写根因修复）；本地版本 tag `3.7.12-ohos-1.0.4-local`。
3. **RemoteDSH-flutter App**（真机已跑通 UI）：契约层（path 依赖）+ 信令客户端（hello/心跳/错误文案矩阵）+ 隧道泵（RawSocket 半关闭语义，initiator）+ 本地代理（127.0.0.1:13080 loopback-only）+ RtcLink（answer 方 onDataChannel 识别 data/ctl、非 trickle 20s 看门狗、pin fail-closed 在 setRemoteDescription 之前）+ UI（扫码配对/免扫码重连/解除/打开 DSH/实时日志）。
4. **vendor 三方**（`third_party/`，跨盘 + LFS + Dart 2.19 三重原因）：flutter_webrtc（gitcode 6f4bce6）、path_provider 三件套、webview_flutter 四件套（SDK 约束降级 + switch break 补丁）；`PathProviderOhos.registerWith()` 手动注册（工具链 dartPluginClass 缺陷）。
5. 签名 HAP 构建 ✓ → 真机（HBN-AL80）安装 ✓ → **UI 首屏渲染 ✓**（截屏实证）。

## 26s 闪断的 B1 预期（待 E2E 验证）

flutter_webrtc 走原生 libwebrtc 的 SIP栈/ICE 实现，与 PC Chrome 同源；025 三方对照中 PC Chrome↔PC werift >100s 稳定——若 B1 真机同样 >100s，则白屏根因（bundle 执行被断）自然消除，四功能验收（列会话/看历史/发消息/审批作答）有望直接通过。

## 下一步

- 真机 E2E：等用户出 QR（配对须 QR 打印后立即做——fake-bridge 限流坑）→ 验证 hello 签名/pin/ICE/隧道 → 打开 DSH → 四功能验收。
- 若 26s 闪断在 B1 复现（原生栈也断）→ 问题在栈之上（网络/系统层），需重新定性。

## 踩坑沉淀

15 条新坑已入 NOTICE.md（wrapper OS 覆写 → ohpm.bat BATCH RECURSION 根因链、ohpm 跨盘 00618008、LFS smudge、dartPluginClass 不注册、模拟器 ABI 不匹配等）。
