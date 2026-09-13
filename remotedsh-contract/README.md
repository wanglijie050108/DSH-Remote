# remotedsh-contract

三件套（`dsh-mobile-link` 插件 / `remotedsh-bridge` 服务端 / `remotedsh-android` App）共同依赖的契约仓库。
依据 `new_docs/00-接口契约(2).md` **v1.0.5** 与 `docs/05-开发计划.md` §2（S2/G2）。

## 内容

| 目录 | 内容 | 依据 |
|---|---|---|
| `vectors/` | 共享测试向量：帧编解码（14 例）、`hello` 签名（6 例含 3 负例）、`a=fingerprint` 归一（7 例）、QR 解析（5 例） | 契约 §3/§4.2/§6.1/§2 |
| `js/` | Node 参考实现：`frames` / `hello` / `fingerprint` / `qr-pair` / `turn` | 同上 |
| `go/` | Go 参考实现（Bridge 直接依赖）：同 js | 同上 |
| `kotlin/` | Kotlin 源码（App `core-contract` 以源码方式引入）：同 js | 03 §3 |
| `tools/` | `fake-bridge`（§4 可执行规格）/ `fake-phone`（03 可执行规格）/ `fake-agent`（01 可执行规格）+ `lib/tunnel-pump`（§3 可执行规格） | 01 §9 交付物 2 |
| `scripts/` | `generate-vectors.mjs`（向量生成，勿重复运行覆盖）、`poc-werift-loopback.mjs`（W1 PoC）、`e1-byte-fidelity.mjs`、`e3-header-fidelity.mjs` | 01 §8 / 05 §6 |

## 运行测试

```sh
# JS 侧（node --test）
node --test "test/*.test.mjs"

# Go 侧
cd go && go test ./...
```

Kotlin 侧由 `remotedsh-android` 的 JVM 单测执行（`android.util` 依赖部分归 androidTest）。

**G2 门禁**：JS / Go / Kotlin 对同一份向量逐字节一致。hello 的期望签名为 RFC 6979 确定性签名——JS（@noble）断言复现；Go / Java（随机化 ECDSA）断言「验证通过」+「被签字节串逐字节一致」+「自产签名 DER ≤72B」。

## W1 实测结论（2026-09-13，已固化到代码注释）

1. **werift `RTCCertificate` 第三参必须是 `{hash, signature}` 枚举对象**（`HashAlgorithm.sha256_4` = 4、`SignatureAlgorithm.ecdsa_3` = 3）。传字符串 `'sha-256'` 时证书注入后 **DTLS 握手必败**（werift↔werift 同样失败）——01 §3 与 skill §3 的 `RTCCertificate(privateKeyPem, certPem, signatureHash)` 事实按此细化。
2. werift 事件用 DOM 风格属性（`pc.ondatachannel` / `ch.onopen` / `ch.onmessage`）或 `Event.subscribe()`；把函数赋给 Event 属性（`pc.onDataChannel = fn`）会运行时报错。
3. 非 trickle（`setLocalDescription` 返回后 SDP 已含全部候选）与双 DataChannel（label `data`/`ctl`）、16373B 边界帧均验证通过（`scripts/poc-werift-loopback.mjs`）。
4. werift↔werift 回环下 ICE 建立约 5–10s；`org.webrtc`（真机）互通仍是 G1 待验项。

## 集成冒烟（已验证通过）

```sh
# 终端 1：echo 目标
node -e "require('net').createServer(s=>{s.on('data',d=>s.write(d))}).listen(19999,'127.0.0.1')"
# 终端 2：信令
node tools/fake-bridge.mjs --port 18080
# 终端 3：插件角色（打印 QR）
node tools/fake-agent.mjs --sig ws://127.0.0.1:18080/v1/signal --forward 127.0.0.1:19999
# 终端 4：手机角色（扫上一步打印的 dshlink:// URI）
node tools/fake-phone.mjs scan --qr "<dshlink://pair?...>" --proxy 13080
# 终端 5：经隧道回环（≥100KB 已验证）
node -e "require('net').connect(13080,'127.0.0.1').end('ping').on('data',d=>console.log(d.toString()))"
```

免扫码重连：`node tools/fake-phone.mjs resume --proxy 13080`（依赖 `--state`/`--key` 落盘文件，对应 03 §3.3 存储清单）。

## 版本

契约 v1.0.5（`proto_ver` = `"1.0.5"`、帧 `ver` = 1、QR `v` = 1）。契约升级时：向量随 §7 变更日志同步升版，三端单测引用同一文件。
