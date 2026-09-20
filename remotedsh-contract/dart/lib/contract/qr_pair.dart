// dshlink://pair QR 载荷解析（契约 §2）—— 自 js/qr-pair.mjs 逐字移植
class PairQr {
  final String error;
  final int? v;
  final String? s; // 信令 URL
  final String? pt; // 配对 token
  final String? fp; // 期望指纹（64 hex 小写或带冒号原文）
  final String? a; // authority，恒 127.0.0.1:13080
  final String? t; // 可选
  PairQr.errorOnly(this.error)
      : v = null,
        s = null,
        pt = null,
        fp = null,
        a = null,
        t = null;
  PairQr(this.v, this.s, this.pt, this.fp, this.a, this.t) : error = '';
  bool get ok => error.isEmpty;
}

PairQr parsePairQr(String uri) {
  Uri u;
  try {
    u = Uri.parse(uri);
  } catch (_) {
    return PairQr.errorOnly('NOT_A_URL');
  }
  if (u.scheme != 'dshlink' || u.host != 'pair') {
    return PairQr.errorOnly('NOT_PAIR_URI');
  }
  final q = u.queryParameters;
  final v = int.tryParse(q['v'] ?? '');
  if (v != 1) return PairQr.errorOnly('UNSUPPORTED_VERSION'); // v1 只有 v=1
  final s = q['s'];
  final pt = q['pt'];
  final fp = q['fp'];
  final a = q['a'];
  if (s == null || s.isEmpty || pt == null || pt.isEmpty ||
      fp == null || fp.isEmpty || a == null || a.isEmpty) {
    return PairQr.errorOnly('MISSING_FIELD');
  }
  // §2 生产为 wss://；05 §0.1 开发期（W1–W7）允许 ws:// 过渡。App 侧发布构建 SHOULD 收紧为 wss-only。
  if (!s.startsWith('wss://') && !s.startsWith('ws://')) {
    return PairQr.errorOnly('BAD_SIGNAL_URL');
  }
  return PairQr(v, s, pt, fp, a, q['t']);
}
