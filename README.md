# DSH-Remote-Hmos

RemoteDSH 的 HarmonyOS（鸿蒙）客户端仓库，验证并实现「手机远程使用 PC 上的 DSH」：经 WebRTC DataChannel 端到端隧道，把 PC 本机 `127.0.0.1:3080` 的 DSH 完整 HTTP + WebSocket 面呈现到手机（本地代理 `127.0.0.1:13080` + WebView 加载官方 GUI）。协议依据 RemoteDSH 接口契约 v1.0.5（帧格式 / 信令 / 配对 / TURN / DTLS pin 等，见主仓库 `new_docs/00`）。

## 仓库内容

| 目录 | 说明 | 状态 |
|---|---|---|
| `RemoteDSH-flutter/` | **现役路线**：Flutter + flutter_webrtc-ohos（底层 `libohos_webrtc.so` 原生 libwebrtc）。契约层 Dart 实现、信令、隧道泵、本地代理、RtcLink、扫码/状态/日志 UI | 开发中（真机 UI 已跑通，详见 changelog 028 问题清单） |
| `RemoteDSH-hmos/` | **原生路线（已冻结）**：纯 ArkTS + ArkWeb（隐藏页面承载 `RTCPeerConnection`）。协议栈完整（G2 向量 40/40、全链路配对→READY→DSH 页渲染），被 ArkWeb 平台缺陷阻塞后留档，可作协议参考实现 | 冻结留档 |
| `remotedsh-contract/dart/` | 契约 v1.0.5 的 Dart 参考实现（帧 / hello 签名 / QR / 指纹归一 / TURN，含 G2 共享向量测试），`RemoteDSH-flutter` 以 path 依赖引用（与主仓库 go/js/kotlin 平级） | 随 Flutter 应用维护 |
| `changelog/` | 本阶段的协作文档：双应用路线复盘、原生路线放弃原因、Flutter 迁移动机与当前问题 | 持续更新 |

> **为什么有两套应用、原生路线为何冻结、为什么迁移 Flutter、Flutter 当前卡在什么问题**——完整复盘见 [`changelog/2026-09-20-028-鸿蒙双应用路线复盘与Flutter迁移总结.md`](changelog/2026-09-20-028-鸿蒙双应用路线复盘与Flutter迁移总结.md)。

## 构建

两个应用共用 bundle 名 `com.remotedsh.app`，安装其一前先卸载另一个：

```sh
hdc uninstall com.remotedsh.app
```

### RemoteDSH-flutter（API 24+，arm64 真机）

依赖 Flutter OHOS 工具链（OpenHarmony-SIG flutter_flutter `dev` 分支，如 3.7.12-ohos）。三方包已 vendor 进 `third_party/packages/`（path 依赖，绕开 ohpm 跨盘与 LFS 问题），无需额外拉取：

```sh
flutter pub get
flutter build hap --debug --target-platform ohos-arm64
hdc install -r RemoteDSH-flutter/ohos/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.remotedsh.app
```

`flutter build hap` 会自动再生 `ohos/har/*.har`、`entry/src/main/resources/rawfile/flutter_assets/` 与 `entry/libs/` 下的引擎产物（这些不入库）。

### RemoteDSH-hmos（API 24+）

DevEco Studio 打开工程，或在项目目录：

```sh
hvigorw assembleHap
```

签名在本地 DevEco 中配置（仓库内的 `signingConfigs` 已清空，不含任何签名材料）。

## 目录约定

- 构建产物（`build/`、`oh_modules/`、`*.har`、`flutter_assets/`、`*.hap`）、签名材料、`local.properties` 一律不入库；
- 两应用的 `.gitignore` 沿用各自工程模板约定。
