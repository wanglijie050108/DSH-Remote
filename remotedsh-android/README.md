# remotedsh-android

Android 薄壳 App：扫码配对 → WebRTC 隧道（P2P 优先 / TURN 兜底，DTLS pin 插件）→
本地代理（127.0.0.1:13080，L4 字节透传）→ WebView 加载 DSH 官方 GUI。
方案依据 `new_docs/03-APP端实施方案(2).md` v1.2（契约 v1.0.5）。

## 模块（03 §3）
| 模块 | 职责 | 红线 |
|---|---|---|
| core-contract | 帧编解码 + hello 签名 + pin 归一（源码引入 remotedsh-contract/kotlin，共享向量单测） | 三端逐字节一致（G2） |
| core-rtc | PeerConnection 封装 + DTLS pin + 双 DataChannel 接收 | pin 在每次 setRemoteDescription 前；MUST NOT createDataChannel；无 sha-256 行 fail-closed |
| core-proxy | 127.0.0.1:13080 本地代理 | BindException 硬失败不回退；隧道未就绪立即 close 不排队；FIN 半关闭继续读 |
| core-pairing | QR 解析、Keystore 签名、配对状态存储 | 存储清单含 fp 与 TURN 凭证+到期（v1.1 缺三项教训） |
| core-bridge | 信令 WSS 客户端 | 25s 心跳义务；封闭集合；错误文案矩阵 |
| app | 三屏 + WebView 壳 + 状态机 | WebView 安全红线；中断 >10s 重建完成 MUST reload() |

## 构建
Android Studio 打开本目录（AGP 8.5 / Kotlin 2.0 / minSdk 26 / target 34）。
`io.getstream:stream-webrtc-android` 版本与证书注入点为 W1 待验证项（03 §2 风险 2）。

## 当前状态
本仓库在无 Android SDK 的工作区只交付源码与红线实现，编译与真机实验（E4/E6/E7/E9）
按 docs/05 计划在 CI / 真机环境完成。
