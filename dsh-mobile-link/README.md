# dsh-mobile-link

DSH bundle：把本机 DSH 的完整 HTTP + WebSocket 面经 WebRTC 隧道呈现给手机。
方案依据 `new_docs/01-DSH端插件实施方案(2).md` v1.2（契约 `new_docs/00-接口契约(2).md` v1.0.5）。

## 安装

```sh
dsh plugin --profile web add dsh-mobile-link
```

前置条件：PATH 上必须有 pnpm（该命令把参数转发给 profile 目录下的 pnpm；无 pnpm → exit 127）。
**不要手改 `cordis.patch.yml`**——由 `reconcilePlugins` 写入 `dsh.profile.bundles`。

## 配置（环境变量）

| 变量 | 必填 | 说明 |
|---|---|---|
| `DSML_SIGNAL_URL` | ✅ | **主机名**（如 `bridge.example.com`），不是完整端点；插件拼成 `wss://<值>/v1/signal` |
| `DSML_AUTHORITY` | — | 手机侧 authority，**恒为 `127.0.0.1:13080`**；设成其他值会在装配期 fail-fast（破坏性变更，v1 禁止调整） |
| `DSML_FORWARD_TARGET` | — | 默认 `127.0.0.1:<ctx.webServer.port>`；兜底 `127.0.0.1:3080` |
| `DSML_LAUNCH_TOKEN` | — | 仅兜底（正常路径经 `ctx.connection.authenticatedUrl()` 程序化取得） |
| `DSML_LOG_LEVEL` | — | `debug`/`info`/`warn`/`error`，默认 `info` |

## 使用

DSH 启动后控制台会打印**配对二维码**（`dshlink://pair?...`，5 分钟有效）；
手机 App 扫码即完成配对。配对存续期间不会重印；DSH 重启（进程更换）后需重新扫码。

## 装配失败自救

DSH 会因本插件装配失败而拒绝启动（已接受耦合，01 §2.1）。每条 fail-fast 报错都附带指引，核心是：

```
修复方式：在 $DSH_HOME/profiles/web/cordis.patch.yml 加入
  - id: mobile-link
    disabled: true
后重启 dsh；修好配置再去掉这段。
```

常见原因：
- `DSML_SIGNAL_URL` 未设置或写成了完整端点（应是纯主机名）；
- `DSML_AUTHORITY` 被改成非契约值；
- 身份文件损坏：删除 `$DSH_HOME/mobile-link/identity.json` 重启 → 自动生成新钥，**所有手机需重新扫码**。

## 文件与密钥

`$DSH_HOME/mobile-link/identity.json`：身份密钥（P-256）+ DTLS 证书（整证书持久化——重新派生会使指纹变化、手机 pin 全部失效，契约 §6）。私钥永不进入日志。

## 行为要点

- **热重载安全**：web profile 的 `patchReload: live` 会 dispose 本插件 fiber，但**不发 `bye`**、`boot_id` 进程级不变 → 手机无感恢复（E10⑥）。
- **进程退出**：SIGINT/SIGTERM 路径尽力发送 `bye{shutdown}`（≤2s 等待 `bye.ok`），对端立即解除配对。
- **隧道重建**：ICE `disconnected/failed` 主触发 + 15s 无帧兜底（契约 §3.5）；重建后 `stream_id` 从 1 重启。
