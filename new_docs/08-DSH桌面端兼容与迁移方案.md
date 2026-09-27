# 08 · DSH Desktop 兼容与迁移方案

> 状态：复审定案，待实现与打包态验收
> 依据：契约 v1.0.5、`docs/01` v1.2、DSH `dsh-v0.1.7-rc.2`
> 上游源码：`deepseek-ai/deepseek-harness@477b4f420553e8a52c2fbccc464d7561b239c443`

## 0. 结论

支持 DSH Desktop **不需要破坏性重构**。

Desktop 仍启动共享 Web Host 和 Web bundle，只把本机操作界面换成 Electron 壳。现有以下边界保持不变：

- 手机 authority 仍为 `127.0.0.1:13080`；
- 插件仍从 `ctx.webServer.port` 读取真实 Host 端口；
- Bridge 仍只传信令和在线状态，不传业务字节；
- WebRTC 双 DataChannel、帧格式、流控、DTLS pin、TURN 和 App 本地代理均不变；
- 插件仍是 offerer，手机仍是 answerer。

本次兼容工作只增加 **Desktop 展示、单活保护、安装恢复、版本门禁和安全加固**。在本文 D0–D8 全部通过前，只能说“源码评审兼容”，不能说“Desktop 已支持”。

## 1. 已核实的 Desktop 事实

| 事实 | 证据 | 对项目的含义 |
|---|---|---|
| Desktop Host 运行 `profile: desktop`，默认端口 `19387` | DSH `apps/desktop-host/src/index.ts:main` | 插件动态读端口即可，无需写死新端口 |
| Desktop profile 复用 `PROFILE_TEMPLATES.web.bundles` | DSH `apps/desktop/src/project-manager.ts` | `webServer`、`connection`、`approval` 和前端静态入口仍存在 |
| Electron 将 `dsh-app://app` 的请求转发到 Host，并附加 Host cookie | DSH `apps/desktop/src/web-document.ts` | 已认证 `/api` 扩展在 Desktop 中可用 |
| Desktop profile 只能由 Electron 管理 | DSH `apps/cli/src/args.ts:rejectElectronProfile` | 禁止把 `dsh plugin --profile desktop` 写进安装说明 |
| Desktop 插件页使用内置 pnpm 安装和启停 bundle | DSH plugin-manager / ui-plugin-manager | Desktop 安装入口应复用官方插件页 |
| 关闭 Desktop 主窗口只隐藏窗口，Host 继续运行 | DSH `apps/desktop/src/main.ts` | 普通关窗不应断开手机隧道 |
| 真正退出、更新重启会产生新进程 | DSH Desktop 生命周期 + 契约 §4.3 | `boot_id` 改变后配对销毁、需要重扫是 v1 已定语义 |

## 2. 033 评审遗漏与修正

### 2.1 二维码不只是“缺一个页面”

现有 `printQr()` 只写 stdout，Desktop GUI 用户看不到；同时当前 token 只注册一次，5 分钟过期后不会自动轮换。

所以完整修复必须同时具备：

1. Desktop 可见的配对区块；
2. 只在 `pair.ready.ok` 后展示；
3. 过期前清掉旧图并注册新 token；
4. `pair.ok` 后立即清掉二维码和 token；
5. 不把 URI、launch token 或 pair token 写入日志、localStorage、崩溃报告或遥测。

### 2.2 “不要同时运行”必须变成技术约束

Web 与 Desktop 共用 `$DSH_HOME/mobile-link/identity.json`。只写一句使用说明不够：误开第二实例会被 Bridge 当成同一 `agent_id` 的新进程，旧连接被踢且 `boot_id` 改变，已有配对随即销毁。

v1 明确采用 **每个 `DSH_HOME` 只允许一个 Mobile Link agent 活跃**。不支持手机在本机多个 DSH 实例间切换；后者需要新协议和新产品设计，仍属范围外。

### 2.3 Desktop 放大了已有私钥权限问题

当前 macOS 实测：

```text
$DSH_HOME/mobile-link       0755
identity.json               0644
```

身份私钥和 DTLS 私钥因此可能被同机其他账号读取。Desktop 支持不能建立在这个权限状态上，必须先完成 §6.1。

### 2.4 版本兼容不能依赖“看起来能跑”

`dsh-mobile-link/package.json` 当前没有 DSH peer 版本、Node engine、客户端 bundle 和发布产物约束。DSH API 仍是 pre-stable；Desktop 又会整体更新 Shell 与 Host。必须让不兼容版本在安装/启动前被拒绝，而不是运行后崩溃。

## 3. 目标架构

```text
Desktop 主窗口
  └─ Plugins / dsh-mobile-link 详情页
       ├─ GET /api/mobile-link/status   （短状态，不含秘密）
       └─ GET /api/mobile-link/qr       （仅 ready 时返回 PNG，no-store）
                    │
                    ▼
          dsh-mobile-link Host 插件
       配置 → 单活租约 → Bridge → WebRTC → 127.0.0.1:<ctx.webServer.port>
                    │
                    ▼
             Bridge / TURN / 手机 App
```

### 3.1 为什么用现有 `/api`，不新造 IPC

- `ctx.connection.fetch.register()` 是 DSH 已有扩展点；
- `/api` 外层已经执行 Host/Origin fence 和 cookie 鉴权；
- Desktop 的 `dsh-app://app` 转发会主动附加 Host cookie；
- 不需要修改 Electron 主进程，不需要新增 Desktop 私有 IPC；
- 不需要修改 Bridge、契约或手机 App。

### 3.2 为什么不用自定义 Typert Remote

状态读取只有两个无参数 GET，`connection.fetch` 已完整覆盖。使用 Typert 会额外引入生成器、Remote contribution 和客户端挂载代码，没有带来更强的安全或一致性保证。

## 4. Desktop 配对 UI

### 4.1 客户端挂载

在插件包增加 `dsh.client.platform = "web"` 和构建后的 `./client` 导出。客户端只向 `plugins.detail.section` 注册一个区块，并且同时满足以下条件才渲染：

1. `subject.kind === "bundle"`；
2. `subject.pkg.name === "dsh-mobile-link"`；
3. `location.protocol === "dsh-app:"`；
4. `globalThis.dshDesktop?.protocolVersion === 1`。

因此手机 WebView 和普通 Web profile 不显示“让手机扫码”的 Desktop 区块。Host 端 QR 路由再校验请求 `Host` 等于 `127.0.0.1:<ctx.webServer.port>`，避免经手机固定 authority `127.0.0.1:13080` 读取二维码。

### 4.2 状态接口

`GET /api/mobile-link/status` 只返回：

```json
{
  "phase": "needs-config | conflict | registering | ready | paired | connecting | connected | error",
  "generation": 7,
  "expiresAt": 1780000000000,
  "peerOnline": false,
  "messageCode": "optional-stable-code"
}
```

约束：

- 不返回 URI、pair token、launch token、TURN credential、私钥、SDP；
- `Cache-Control: no-store, private`；
- 客户端仅在详情区块挂载期间每 1 秒轮询，卸载立即停止；
- 文案由客户端按稳定 `phase/messageCode` 本地化，不把 Host 错误原文直接展示。

`GET /api/mobile-link/qr?generation=<n>`：

- 仅 `phase=ready` 且 generation 匹配时返回 PNG；
- 其他状态返回 `404`，过期 generation 返回 `410`；
- 响应使用 `Cache-Control: no-store, private` 和 `Referrer-Policy: no-referrer`；
- PNG 在 Host 内存生成，不落盘；URI 不进入 DOM、日志和剪贴板。

界面必须同时满足：

- 二维码有明确的可访问名称，倒计时和状态不只靠颜色表达；
- 状态变化使用非打断式 live region，不能每秒播报倒计时；
- 过期、冲突和错误状态不保留旧二维码；
- 提供“重新尝试”命令，但不提供默认复制秘密 URI 的按钮。

### 4.3 QR 轮换状态机

```text
hello.ok{pair:null}
  → 生成 token(g+1)
  → pair.ready
  → pair.ready.ok
  → 生成内存 PNG，phase=ready
  → 285s 到期：先清 PNG/token，再注册下一代

pair.ok / bye / PAIR_REPLACED / PAIR_NOT_FOUND / dispose
  → generation++
  → 清轮换 timer、PNG 和 token
  → 按现有契约进入 paired 或重新注册
```

使用 285 秒展示窗口，给 Bridge 的 300 秒 TTL 留 15 秒边界余量。任一异步二维码生成和迟到 ACK 都必须校验 generation，不能复活旧 token。

普通 Web profile 保留现有终端 QR 作为兼容路径；Desktop profile 不向 stdout 输出 QR 或明文 URI。

## 5. 单活保护

### 5.1 锁的范围和行为

锁路径：`$DSH_HOME/mobile-link/active-agent/`。同一个 DSH_HOME 下只允许一个进程连接 Bridge。

锁竞争不是装配失败：

- 获得锁：继续连接 Bridge；
- 锁已被活进程持有：插件保持加载，phase=`conflict`，不连接 Bridge、不注册 QR、不影响 DSH 启动；
- 持有者退出或释放：等待者可手动重试或有界轮询后接管；
- 接管新进程后 `boot_id` 不同，按契约要求旧配对失效并重新扫码。

### 5.2 原子性和崩溃恢复

- 用原子 `mkdir` 争抢目录，不使用“先检查再创建”的竞态写法；
- owner 文件以 `0600` 写入 `{pid, boot_id, profile, nonce, started_at}`；
- 活 PID 不允许被抢占；
- 死 PID 的目录先原子 rename 到唯一 stale 名，再重试 `mkdir`；
- 释放前核对 nonce，禁止旧 disposer 删除新持有者的锁；
- stale 清理失败只留垃圾目录，不允许双持有者。

启动顺序必须固定为：

1. 校验配置；
2. 安全创建或检查 `$DSH_HOME/mobile-link`；
3. 生成进程级 `boot_id` 并注册只读状态路由；
4. 取得单活租约；
5. **只有持有者**才能读取或生成 identity、创建 DTLS 证书并连接 Bridge。

锁必须先于 `loadIdentity()`，否则两个首次启动的进程仍可能同时生成不同私钥，并让其中一个进程使用未落盘的身份。

### 5.3 HMR 与禁用

租约管理器挂在 `globalThis`，与 `boot_id` 同为进程级：

- 热重载：新实例复用同一租约，不释放；
- 插件 disabled：延迟释放；同进程重新挂载可取消释放；
- 真实进程退出：同步尽力删除，异常退出由下一持有者按死 PID 回收；
- 释放延迟期间第二实例只显示 conflict，不连接 Bridge。

这里的简化上限是 PID 复用可能造成保守的“假冲突”，不会造成双实例或配对破坏。升级方向是平台原生文件锁，不在 v1 引入新依赖。

## 6. 安全与配置

### 6.1 身份文件

生成身份时必须：

- `$DSH_HOME/mobile-link` 创建为 `0700`；
- 临时文件使用 `wx + 0600`，写完并 flush 后原子 rename；
- 已有 `mobile-link` 路径必须是非符号链接目录；
- POSIX 读取已有 identity 时拒绝符号链接和非普通文件；发现 group/other 权限时先收紧到 `0600`，收紧失败才 fail-fast；
- Windows 依赖用户 profile ACL，文档明确 mode 不提供 ACL 保证；
- 解析前限制文件大小，错误中不回显内容。

### 6.2 Desktop 配置顺序

v1 不改变现有环境变量接口。安装前先在 `$DSH_HOME/.env` 写入普通配置：

```dotenv
DSML_SIGNAL_URL=bridge.example.com
```

`DSML_SIGNAL_URL` 不是 `DSH_*` 启动变量，可由 DSH `loadLayeredEnv()` 从 home `.env` 读取。

严格顺序：

1. 退出或停用 Web profile 的 Mobile Link；
2. 写入并检查 `$DSH_HOME/.env`；
3. 在 Desktop 的 Plugins 页面安装 bundle，安装完成先保持关闭；
4. 确认版本兼容和私钥权限迁移完成；
5. 启用 bundle；
6. 打开插件详情页扫码。

配置错误仍按既定 fail-fast 语义处理。Desktop 自救首选原生恢复对话框的“禁用第三方插件”；手工编辑 `$DSH_HOME/profiles/desktop/cordis.patch.yml` 只作为应用完全无法恢复时的离线后备。

## 7. 包与版本门禁

首个 Desktop 兼容版本必须补充：

- `engines.node`：匹配 DSH 0.1.7 的 Node 要求；
- `peerDependencies["@deepseek-ai/dsh"]`：先钉精确验证版本；
- 客户端实际导入的 DSH/Cordis 包列为 peer，不复制第二套框架运行时；
- `dsh.client.inject/external` 与 `./client` 构建产物；
- npm/tarball 中只包含运行产物、类型、locale、图标、README 和许可证；
- 禁止通过版本豁免绕过未测试的 DSH 版本。

DSH 升级流程：

1. 在候选版本执行 D0–D8；
2. 更新 peer 范围；
3. 先发布兼容插件，再允许 Desktop 更新；
4. 无兼容插件时让 DSH 拒绝激活，并通过原生恢复禁用，不能带病启动。

## 8. 实施顺序

| 阶段 | 内容 | 退出条件 |
|---|---|---|
| P0 | 私钥权限与原子持久化；QR 285s 轮换 | 单测覆盖权限、旧图失效、迟到回调 |
| P1 | 抽出只读状态投影；注册两个已认证 GET | 状态响应无秘密，错误状态稳定 |
| P2 | 增加 `dsh.client` 和 Desktop 插件详情区块 | Desktop 显示 QR；Web/手机不显示 |
| P3 | 增加进程级单活租约 | 双进程、崩溃、HMR、disabled 场景通过 |
| P4 | 补 package peer/engine、构建与发布产物 | Desktop 插件页可安装、启用、卸载 |
| P5 | 更新安装、自救与升级文档 | 新用户不依赖终端即可完成配对 |

## 9. 验收门禁

| 门禁 | 必须通过的检查 |
|---|---|
| D0 源码契约 | Desktop 仍复用 Web bundles；Host `/api` 仍有 fence + cookie；真实端口仍来自 `ctx.webServer.port` |
| D1 安装 | macOS arm64/x64、Windows x64 的打包应用从 Plugins 页安装、保持关闭、启用、卸载 |
| D2 配对 UI | ACK 前无 QR；ready 后显示；285s 自动换代；pair.ok 后立即消失 |
| D3 安全 | 未认证 401、恶意 Host/Origin 403、手机 authority 不能取 QR、响应 no-store、日志和磁盘无 token |
| D4 单活 | Web→Desktop 与 Desktop→Web 均不踢旧连接；冲突方不连接 Bridge；原配对保持 |
| D5 生命周期 | Desktop 隐藏窗口不断线；HMR 不换 boot_id/不丢锁/不发 bye；退出或更新重启按契约要求重扫 |
| D6 隧道 | E1 大响应保真、E3 头部、relay-only、FIN/WINDOW、15s 重建回归全绿 |
| D7 业务 | 手机端列会话、看历史、发消息、审批作答四项通过 |
| D8 恢复 | 缺配置、坏身份文件、不兼容版本、插件启动失败都能通过 Desktop 原生恢复回到可启动状态 |

发布判据：D0–D8 全绿，且真机 relay-only 连续稳定至少 30 分钟。任何一项缺失都保留“验证中”，不得宣称 Desktop 支持完成。

## 10. 明确不做

- 不修改契约 v1.0.5；
- 不修改固定 authority `127.0.0.1:13080`；
- 不让手机同时连接本机多个 DSH；
- 不新增 Bridge 数据库或业务转发；
- 不把配对秘密放入 Electron IPC、URL query、localStorage、日志或遥测；
- 不为了 Desktop 重写 Flutter/Android 网络层；
- 不绕过 DSH 插件版本兼容检查。
