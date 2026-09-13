// 配置（01 §7）——装配期 fail-fast；每条报错自带自救指引（§2.1：DSH 会因装配失败拒绝启动，用户进不了 UI）
export const AUTHORITY = '127.0.0.1:13080' // 契约 §1 固定值（v1 不存在备用值）
export const PROTO_VER = '1.0.5' // 契约 §7

export const SELF_RESCUE = `修复方式：在 $DSH_HOME/profiles/web/cordis.patch.yml 加入
  - id: mobile-link
    disabled: true
后重启 dsh；修好配置再去掉这段。`

export class ConfigError extends Error {}

export function loadConfig(env = process.env, webServerPort = null) {
  // DSML_SIGNAL_URL：主机名，不是完整端点（§7：拼错成 wss://…/v1/signal 会拼出 /v1/signal/v1/signal）。
  // 05 §0.1：开发期允许显式 ws:// 过渡（值含 scheme 时必须是 ws:// 或 wss://，且不再含路径）。
  let signalUrl = env.DSML_SIGNAL_URL
  if (!signalUrl) {
    throw new ConfigError(`DSML_SIGNAL_URL 未设置。期望：主机名（如 bridge.example.com），插件内部拼接为 wss://<值>/v1/signal。\n${SELF_RESCUE}`)
  }
  let explicitScheme = null
  if (signalUrl.startsWith('ws://') || signalUrl.startsWith('wss://')) {
    explicitScheme = signalUrl.slice(0, signalUrl.indexOf('://') + 3)
    const rest = signalUrl.slice(explicitScheme.length)
    if (rest.includes('/')) {
      throw new ConfigError(`DSML_SIGNAL_URL 形态错误："${signalUrl}"。scheme 后只能有 host[:port]，不能再带路径，否则会拼出 /v1/signal/v1/signal。\n${SELF_RESCUE}`)
    }
  } else if (signalUrl.includes('://') || signalUrl.includes('/')) {
    throw new ConfigError(`DSML_SIGNAL_URL 形态错误："${signalUrl}"。必须是纯主机名（可含端口），不能带 scheme 或路径，否则会拼出 /v1/signal/v1/signal。\n${SELF_RESCUE}`)
  }

  // DSML_AUTHORITY：不是可自由调整的运维参数（改它 = 全体 cookie 失效 + OPEN 断言失败，§1）
  const authority = env.DSML_AUTHORITY || AUTHORITY
  if (authority !== AUTHORITY) {
    throw new ConfigError(`DSML_AUTHORITY="${authority}" ≠ 契约固定值 "${AUTHORITY}"。authority 改动是破坏性变更（全体设备 cookie 失效），v1 禁止调整。\n${SELF_RESCUE}`)
  }

  // 转发目标：优先 ctx.webServer.port（真实监听端口；.host 是配置值可能为 0.0.0.0 —— 陷阱，skill §6）
  const forwardTarget = env.DSML_FORWARD_TARGET || `127.0.0.1:${webServerPort ?? 3080}`
  if (!/^\d{1,3}(\.\d{1,3}){3}:\d+$/.test(forwardTarget)) {
    throw new ConfigError(`DSML_FORWARD_TARGET="${forwardTarget}" 形态错误。期望 127.0.0.1:<端口>。\n${SELF_RESCUE}`)
  }

  return {
    signalUrl: signalUrl.replace(/^[a-z]+:\/\//, ''), // 纯主机名形态（供 QR/bridge.js 拼接）
    signalScheme: explicitScheme || 'wss://', // 显式 ws:// 仅开发期（05 §0.1）
    authority,
    forwardTarget,
    launchToken: env.DSML_LAUNCH_TOKEN || null, // 仅兜底（§6），正常路径经 ctx.connection.authenticatedUrl() 程序化取得
    logLevel: env.DSML_LOG_LEVEL || 'info',
  }
}
