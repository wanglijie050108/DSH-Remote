// dshlink://pair QR 载荷解析（契约 §2，语义对齐 remotedsh-contract/js/qr-pair.mjs 的 URL 解析）
// ArkTS 无 DOM URL/URLSearchParams，手工解析并保持与 URLSearchParams 相同的 '+'→空格、%XX 解码语义。
// §2 生产为 wss://；开发期（05 §0.1，W1–W7）允许 ws:// 过渡。
export class PairQr {
  public v: number = 0
  public s: string = ''
  public pt: string = ''
  public fp: string = ''
  public a: string = ''
  public t: string | null = null
}

/** 「resolve 结果对象」模式：ok=false 时看 error；ArkTS 不用裸 union 返回 */
export class PairQrResult {
  public ok: boolean = false
  public error: string = ''
  public qr: PairQr | null = null
}

function decodeQueryComponent(s: string): string {
  return decodeURIComponent(s.replace(/\+/g, ' '))
}

export function parsePairQr(uri: string): PairQrResult {
  const res = new PairQrResult()
  if (!uri.startsWith('dshlink://')) {
    res.error = 'NOT_A_URL'
    return res
  }
  const rest = uri.substring('dshlink://'.length)
  const qIdx = rest.indexOf('?')
  const host = qIdx >= 0 ? rest.substring(0, qIdx) : rest
  if (host !== 'pair') {
    res.error = 'NOT_PAIR_URI'
    return res
  }
  const query = qIdx >= 0 ? rest.substring(qIdx + 1) : ''
  const raw: Map<string, string> = new Map()
  if (query.length > 0) {
    const parts = query.split('&')
    for (const p of parts) {
      if (p.length === 0) { continue }
      const eq = p.indexOf('=')
      try {
        if (eq < 0) {
          raw.set(decodeQueryComponent(p), '')
        } else {
          raw.set(decodeQueryComponent(p.substring(0, eq)), decodeQueryComponent(p.substring(eq + 1)))
        }
      } catch (err) {
        // 畸形百分号编码（如粘贴内容残缺拼接出 `127.0.0.1%dshlink://…`）——按解析失败处理，禁止崩 UI
        res.error = 'BAD_ENCODING'
        return res
      }
    }
  }
  // Number(null)===0 → v 缺失同样落 UNSUPPORTED_VERSION（与参考实现 Number(q.get('v')) 语义一致）
  const rawV = raw.get('v')
  const v = rawV === undefined ? NaN : Number(rawV)
  if (v !== 1) {
    res.error = 'UNSUPPORTED_VERSION'
    return res
  }
  const s = raw.get('s')
  const pt = raw.get('pt')
  const fp = raw.get('fp')
  const a = raw.get('a')
  if (s === undefined || pt === undefined || fp === undefined || a === undefined) {
    res.error = 'MISSING_FIELD'
    return res
  }
  if (!/^wss:\/\//.test(s) && !/^ws:\/\//.test(s)) {
    res.error = 'BAD_SIGNAL_URL'
    return res
  }
  const qr = new PairQr()
  qr.v = v
  qr.s = s
  qr.pt = pt
  qr.fp = fp
  qr.a = a
  const t = raw.get('t')
  qr.t = t === undefined ? null : t
  res.ok = true
  res.qr = qr
  return res
}
