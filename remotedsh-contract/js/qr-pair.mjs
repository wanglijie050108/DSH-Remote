// dshlink://pair QR 载荷解析（契约 §2）
export function parsePairQr(uri) {
  let u
  try { u = new URL(uri) } catch { return { error: 'NOT_A_URL' } }
  if (u.protocol !== 'dshlink:' || u.host !== 'pair') return { error: 'NOT_PAIR_URI' }
  const q = u.searchParams
  const v = Number(q.get('v'))
  if (v !== 1) return { error: 'UNSUPPORTED_VERSION' } // v1 只有 v=1
  const s = q.get('s')
  const pt = q.get('pt')
  const fp = q.get('fp')
  const a = q.get('a')
  if (!s || !pt || !fp || !a) return { error: 'MISSING_FIELD' }
  // §2 生产为 wss://；05 §0.1 开发期（W1–W7）允许 ws:// 过渡。App 侧发布构建 SHOULD 收紧为 wss-only。
  if (!/^wss:\/\//.test(s) && !/^ws:\/\//.test(s)) return { error: 'BAD_SIGNAL_URL' }
  return { v, s, pt, fp, a, t: q.get('t') } // t 可选；authority 恒为 127.0.0.1:13080（§1），由调用方断言
}
