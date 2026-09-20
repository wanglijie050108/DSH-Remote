# RemoteDSH-hmos（鸿蒙真机验证 harness）

> 定位红线：**这是验证平台（harness），不是鸿蒙客户端立项**——依据 `new_docs/06-鸿蒙真机验证方案.md`（契约 v1.0.5）。
> 手机端角色由本 App 承担：ArkWeb 内页面的标准 `RTCPeerConnection`（即 libwebrtc）替代 Android 原生 WebRTC。
> 兼容 API：24（`6.1.1(24)`，targetSdk = compatibleSdk）。bundle：`com.remotedsh.app`。

## 架构（与 Android 逐层对应，唯一替换点是 RTC 承载层）

```
EntryAbility（webview 预热 + HarnessService.init）
├─ contract/   契约层 ArkTS port（逐字节对齐 remotedsh-contract/js）
│   ├─ Codec.ets        base64/base64url/hex/utf8（纯 TS）
│   ├─ Digest.ets       SHA-256/SHA-1/HMAC-SHA1（纯 TS，RFC 向量本地可证）
│   ├─ DerEcdsa.ets     ECDSA DER ↔ 裸 r‖s（契约禁 P1363）
│   ├─ Frames.ets       11B 帧头编解码 + FrameSplitter（16373 边界）
│   ├─ Fingerprint.ets  a=fingerprint 归一 + pin 校验（fail-closed）
│   ├─ QrPair.ets       dshlink://pair 解析
│   ├─ Hello.ets        hello 规范化 + native cryptoFramework ECDSA 签名 + 身份类
│   ├─ Turn.ets         TURN 凭证语义（自测用；App 实际透传 bridge 下发的凭证）
│   ├─ Vectors.ets      G2 共享向量嵌入（生成自 remotedsh-contract/vectors）
│   └─ SelfTest.ets     设备侧自测套件（自测页调用）
├─ signal/     SignalClient：@ohos.net.webSocket + 25s 心跳 + SignalMsg 收窄
├─ rtc/        RtcEngine：隐藏 ArkWeb（rawfile/rtc.html）+ javaScriptProxy/runJavaScript 帧中继
│              · RTCCertificate 经 indexedDB 持久化（失败降级为内存证书）
│              · 非 trickle（gather complete 再出 SDP）· relay-only SDP 过滤（G3-H）
├─ tunnel/     TunnelEndpoint（initiator）：OPEN(authority)/DATA/FIN/RST/WINDOW + PING/PONG 保活
├─ proxy/      LocalProxy：TCPSocketServer @ 127.0.0.1:13080（未就绪立即 close；端口占用不回退）
├─ service/    HarnessService：状态机（IDLE→…→READY）+ preferences 持久化 + 03 §3.3 错误矩阵
└─ pages/      Index（主控 + 隐藏 RTC Web）+ 自测/探针/日志/DSH 四个 NavDestination
```

## 验证方案阶段映射

| 阶段 | 依赖 | 本工程内容 |
|---|---|---|
| H0 | 用户操作 | 自动签名 + Hello World 上真机（见下） |
| H1 探针 A | App | 「探针」页 → 运行探针 A（RTCPeerConnection/createDataChannel/generateCertificate 存在性） |
| H1 探针 B | App + PC Chrome | 「探针」页 → 生成 offer，与 chrome://webrtc-internals 手动换 SDP |
| H1 正赛 / G1-H | App + fake-agent | PC：`node tools/fake-agent.mjs --sig ws://<bridge>:8080/v1/signal --forward …`；App 粘贴其 QR；判据①指纹 pin②三类候选③16KiB 帧 |
| H2 | App 自测页 + 线上 bridge | 「自测」页全绿 + 真 bridge hello.ok/负例/pair 生命周期 |
| H3 | App + 真 DSH/插件 | 隧道回环 50KB、16373 边界帧、DSH Web 出画面（明文 loopback 实证） |
| H4 / G3-H | 全链路 | relay-only 开关 → 四功能判据 |

## H0 用户操作清单（真机安装前置）

1. 设备确认 HarmonyOS NEXT（`hdc shell param get const.product.software.version`）。
2. DevEco Studio → File → Project Structure → Signing Configs → 勾选 Automatically generate（华为账号实名 + 注册设备）。
3. 连真机 Run（或 `hdc install entry/build/default/outputs/default/entry-default-unsigned.hap` 的签名产物）。
4. 按上表依次推进 H1 → H4；日志看「日志」页或 `hdc shell hilog | grep -E "Harness|Signal|Tunnel|Proxy|RTC"`。

## 质量基线

- G2 向量：纯逻辑部分已在 PC 用 Node 直接验证 **14/14 全绿**（帧 14 例/指纹 7/QR 5/SHA/HMAC/DER/TURN）；crypto（hello 6 例）在设备自测页跑（随机化 ECDSA 断言「验证通过」+ 被签字节串逐字节一致，与 Go/Java 门禁同口径）。
- 编译门禁：`hvigorw assembleHap`（`entry@default` 与更严的 `entry@ohosTest`）双 GREEN；新增 .ets 后必跑 `--no-daemon`。
- 踩坑记录：`NOTICE.md`（项目专属）+ `D:\HarmonyOS_Develop\docs\`（跨项目）。
