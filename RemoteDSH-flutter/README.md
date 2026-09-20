# RemoteDSH-flutter

RemoteDSH 的 HarmonyOS 客户端（现役路线）：Flutter + flutter_webrtc-ohos（底层 `libohos_webrtc.so` 原生 libwebrtc NAPI 模块）。

## 架构

```
lib/
├─ main.dart                 入口 + 路由（扫码 / 状态日志 / DSH Web 三区）
├─ rtc/rtc_link.dart         answer 方：onDataChannel 识别 data/ctl 双通道、非 trickle 20s 看门狗、pin fail-closed 在 setRemoteDescription 之前
├─ service/
│  ├─ harness.dart           编排：配对状态机、免扫码重连、错误文案矩阵、iceServers 组装
│  ├─ signal_client.dart     信令 WSS 客户端（hello / 25s 心跳 / 封闭消息集）
│  └─ tunnel.dart            隧道泵：11B 帧 + FrameSplitter、WINDOW 信用记账、半关闭语义（RawSocket）
├─ ui/dsh_web_page.dart      WebView 加载 DSH 官方 GUI（token 换 cookie；console 直通日志）
└─ 契约层                     path 依赖 remotedsh-contract/dart（帧编解码 / hello 签名 / QR / 指纹归一 / TURN，G2 共享向量全绿）
```

三方包 vendor 于 `third_party/packages/`（flutter_webrtc / path_provider / webview_flutter，path 依赖——绕开 ohpm 跨盘与 LFS 问题，其中含我方补丁）。

## 构建

依赖 Flutter OHOS 工具链（OpenHarmony-SIG flutter_flutter `dev` 分支，如 3.7.12-ohos）：

```sh
flutter pub get
flutter build hap --debug --target-platform ohos-arm64
hdc install -r ohos/entry/build/default/outputs/default/entry-default-signed.hap
hdc shell aa start -a EntryAbility -b com.remotedsh.app
```

签名在本地 DevEco/flutter 工具链配置（仓库 `signingConfigs` 已清空，不含签名材料）。

## 当前状态

真机（arm64）UI 已跑通、DSH 真实数据可渲染、P2P 直连 rtt 11ms。当前问题清单与路线复盘见仓库根 `changelog/`。
