// 配对（01 §4.3）：pair_token / ptok_hash / QR 渲染与重印纪律
// 重印纪律（契约 §4.4）：
//   必须等 pair.ready.ok 才出 QR；pair 存续期（收到 pair.ok 且未被 §4.3 条件①–⑤销毁）MUST NOT 重印；
//   pair 销毁后恢复轮印（触发：bye / bye.ok / PAIR_REPLACED / PAIR_NOT_FOUND / hello.ok{pair:null}）；
//   收到 pair.ok 后 token 用后即弃。
import { createHash, randomBytes } from 'node:crypto'

export function newPairToken() {
  return randomBytes(32).toString('base64url') // 32B → base64url 无填充（契约 §2）
}

export function ptokHash(pairToken) {
  return createHash('sha256').update(pairToken).digest('base64url') // pair.ready 携带，Bridge 只存 hash（§4.1）
}

/**
 * 组装 QR 载荷（契约 §2）。
 * launch token 由 ctx.connection.authenticatedUrl() 程序化取得（01 §6），不落盘、不进 pair.ready、不写日志。
 */
export function buildPairUri({ sigUrlHost, ptok, fp, authority, launchToken, sigScheme = 'wss://' }) {
  const s = `${sigScheme}${sigUrlHost}/v1/signal` // 完整端点，不是主机名（§2/01 §7；ws:// 仅开发期，05 §0.1）
  const params = new URLSearchParams({ v: '1', s, pt: ptok, fp, a: authority })
  if (launchToken) params.set('t', launchToken)
  return `dshlink://pair?${params.toString()}`
}

/** 终端渲染（插件无 UI；qrcode 由调用方动态 import 注入，便于单测） */
export async function renderQr(uri, qrcodeModule) {
  const text = await qrcodeModule.toString(uri, { type: 'terminal', small: true })
  return `DSH Mobile Link 配对二维码（5 分钟内有效）：\n${uri}\n${text}`
}
