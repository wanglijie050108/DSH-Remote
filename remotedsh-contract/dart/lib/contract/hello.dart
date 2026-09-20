// hello 规范化序列化与签名（契约 §4.2）—— 自 js/hello.mjs 移植，三端 MUST 逐字节一致
// 被签名串 = UTF-8 "hello|" + String(ts) + "|" + nonce；sig = ECDSA P-256/SHA-256 DER → base64url
// proto_ver 恒为 "1.0.5"（契约 §7）
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' hide Digest;
import 'package:pointycastle/export.dart';

import 'ec_key.dart';

const String protoVer = '1.0.5';

/// 被签名串。ts = epoch 秒十进制 ASCII，无小数/前导零/指数（§4.2）
Uint8List canonicalBytes(int ts, String nonce) {
  if (ts < 0) throw ArgumentError('ts must be a non-negative integer (epoch seconds)');
  return Uint8List.fromList(utf8.encode('hello|$ts|$nonce'));
}

/// RFC 6979 确定性签名（与 @noble 向量逐字节可比）：DER → base64url
String signHelloDeterministic(EcIdentity id, int ts, String nonce) {
  final signer = ECDSASigner(SHA256Digest(), HMac(SHA256Digest(), 64));
  signer.init(true, PrivateKeyParameter<ECPrivateKey>(id.priv));
  final sig = signer.generateSignature(canonicalBytes(ts, nonce)) as ECSignature;
  return b64urlEncode(derSequence([derInteger(sig.r), derInteger(sig.s)]));
}

/// 随机化 ECDSA（App 实际路径；契约允许，MUST 满足「验签通过」而非「与向量逐字节一致」）
String signHello(EcIdentity id, int ts, String nonce) {
  final signer = ECDSASigner(SHA256Digest());
  // pointycastle 随机签名需显式注入 SecureRandom（默认名未注册）
  signer.init(true,
      ParametersWithRandom(PrivateKeyParameter<ECPrivateKey>(id.priv), newSecureRandom()));
  final sig = signer.generateSignature(canonicalBytes(ts, nonce)) as ECSignature;
  return b64urlEncode(derSequence([derInteger(sig.r), derInteger(sig.s)]));
}

/// 验签（pub 可为 SPKI DER；sig 为 base64url DER）
bool verifyHello(Uint8List pubSpkiDer, int ts, String nonce, String sigB64url) {
  try {
    final pub = importSpkiDer(pubSpkiDer);
    final outer = _readSigTlv(b64urlDecode(sigB64url), 0);
    final children = _readSigChildren(outer.content);
    final r = _sigBytesToBig(children[0].content);
    final s = _sigBytesToBig(children[1].content);
    final verifier = ECDSASigner(SHA256Digest());
    verifier.init(false, PublicKeyParameter<ECPublicKey>(pub));
    return verifier.verifySignature(
        canonicalBytes(ts, nonce), ECSignature(r, s));
  } catch (_) {
    return false;
  }
}

// 本文件内复用 ec_key.dart 的最小 DER 读取（私有复制，避免公开导出）
_DerItem2 _readSigTlv(Uint8List b, int off) {
  var o = off;
  final tag = b[o++];
  var len = b[o];
  o++;
  if (len & 0x80 != 0) {
    final n = len & 0x7f;
    len = 0;
    for (var i = 0; i < n; i++) {
      len = (len << 8) | b[o++];
    }
  }
  return _DerItem2(tag, Uint8List.sublistView(b, o, o + len), o + len);
}

List<_DerItem2> _readSigChildren(Uint8List content) {
  final out = <_DerItem2>[];
  var off = 0;
  while (off < content.length) {
    final it = _readSigTlv(content, off);
    out.add(it);
    off = it.next;
  }
  return out;
}

BigInt _sigBytesToBig(List<int> b) {
  var start = 0;
  while (b.length - start > 1 && b[start] == 0) {
    start++;
  }
  var hex = '';
  for (var i = start; i < b.length; i++) {
    hex += b[i].toRadixString(16).padLeft(2, '0');
  }
  return hex.isEmpty ? BigInt.zero : BigInt.parse(hex, radix: 16);
}

class _DerItem2 {
  final int tag;
  final Uint8List content;
  final int next;
  _DerItem2(this.tag, this.content, this.next);
}

/// 组装 hello 消息（契约 §4.1：role/pub/boot_id/ts/nonce/sig/proto_ver）
Map<String, dynamic> buildHello({
  required String role,
  required EcIdentity id,
  String? bootId,
  int? ts,
  String? nonce,
}) {
  if (role == 'agent' && bootId == null) {
    throw ArgumentError('agent MUST carry boot_id (契约 §4.3)');
  }
  final t = ts ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final n = nonce ?? randomNonce();
  return {
    't': 'hello',
    'role': role,
    'boot_id': bootId,
    'pub': id.spkiBase64Url(),
    'ts': t,
    'nonce': n,
    'sig': signHello(id, t, n),
    'proto_ver': protoVer,
  };
}

final _rand = Random.secure();
String randomNonce() {
  final b = List<int>.generate(32, (_) => _rand.nextInt(256));
  return b64urlEncode(b);
}
