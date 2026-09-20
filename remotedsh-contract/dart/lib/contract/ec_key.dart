// P-256 身份密钥工具 —— 对应 ArkTS DerEcdsa/cryptoFramework 的 Dart 等价实现
// 最小 DER 读写器（只需 SEQUENCE/INTEGER/OID/OCTET STRING/BIT STRING/[1] 几种形态），
// 不引入 asn1lib 以保证字节级确定性。PKCS8/SPKI 按 RFC 5959/5480 标准结构。
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';

// ---------- 最小 DER ----------

/// 编码 DER length（短/长形）
Uint8List _derLen(int n) {
  if (n < 0x80) return Uint8List.fromList([n]);
  final bytes = <int>[];
  var v = n;
  while (v > 0) {
    bytes.insert(0, v & 0xff);
    v >>= 8;
  }
  return Uint8List.fromList([0x80 | bytes.length, ...bytes]);
}

Uint8List _tlv(int tag, List<int> content) {
  final l = _derLen(content.length);
  return Uint8List.fromList([tag, ...l, ...content]);
}

Uint8List derSequence(List<List<int>> children) {
  final content = <int>[];
  for (final c in children) {
    content.addAll(c);
  }
  return _tlv(0x30, content);
}

Uint8List derInteger(BigInt v) {
  var bytes = _bigToBytes(v);
  if (bytes.isEmpty) {
    bytes = Uint8List.fromList([0]);
  }
  if (bytes[0] & 0x80 != 0) {
    // 正数且最高位为 1 → 前置 0x00（DER 有符号整数规则）
    return _tlv(0x02, [0, ...bytes]);
  }
  // 去多余前导 0（保留一个用于 0 值）
  var start = 0;
  while (bytes.length - start > 1 && bytes[start] == 0) {
    start++;
  }
  return _tlv(0x02, bytes.sublist(start));
}

Uint8List derOid(String dotted) {
  final parts = dotted.split('.').map(int.parse).toList();
  final body = <int>[parts[0] * 40 + parts[1]];
  for (var i = 2; i < parts.length; i++) {
    var v = parts[i];
    final tmp = <int>[v & 0x7f];
    v >>= 7;
    while (v > 0) {
      tmp.insert(0, (v & 0x7f) | 0x80);
      v >>= 7;
    }
    body.addAll(tmp);
  }
  return _tlv(0x06, body);
}

Uint8List derOctetString(List<int> content) => _tlv(0x04, content);
Uint8List derBitString(List<int> content, {int unusedBits = 0}) =>
    _tlv(0x03, [unusedBits, ...content]);
Uint8List derExplicit1(List<int> childEncoded) => _tlv(0xa1, childEncoded);

// 读取器：返回 (tag, content, nextOffset)
class _DerItem {
  final int tag;
  final Uint8List content;
  final int next;
  _DerItem(this.tag, this.content, this.next);
}

_DerItem _readTlv(Uint8List b, int off) {
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
  return _DerItem(tag, Uint8List.sublistView(b, o, o + len), o + len);
}

List<_DerItem> _readChildren(Uint8List content) {
  final out = <_DerItem>[];
  var off = 0;
  while (off < content.length) {
    final it = _readTlv(content, off);
    out.add(it);
    off = it.next;
  }
  return out;
}

// ---------- BigInt ↔ bytes ----------

Uint8List _bigToBytes(BigInt v) {
  if (v == BigInt.zero) return Uint8List(0);
  var hex = v.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

BigInt _bytesToBig(List<int> b) {
  if (b.isEmpty) return BigInt.zero;
  var hex = '';
  for (final x in b) {
    hex += x.toRadixString(16).padLeft(2, '0');
  }
  return BigInt.parse(hex, radix: 16);
}

// ---------- 常量 ----------

const String _oidEcPublicKey = '1.2.840.10045.2.1';
const String _oidPrime256v1 = '1.2.840.10045.3.1.7';

class EcIdentity {
  final ECPrivateKey priv;
  final ECPublicKey pub;
  EcIdentity(this.priv, this.pub);

  /// SPKI DER（契约 hello.pub = SPKI DER → base64url）
  Uint8List spkiDer() {
    final q = pub.Q!;
    final point = Uint8List(65);
    point[0] = 4; // uncompressed
    final xb = _bigToBytes(q.x!.toBigInteger()!);
    final yb = _bigToBytes(q.y!.toBigInteger()!);
    point.setAll(1 + (32 - xb.length), xb);
    point.setAll(33 + (32 - yb.length), yb);
    return derSequence([
      derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
      derBitString(point),
    ]);
  }

  /// PKCS8 DER（本地持久化用，对齐 fake-phone/fake-agent 的 PKCS8 PEM 形态）
  Uint8List pkcs8Der() {
    final d = priv.d!;
    final q = pub.Q!;
    final point = Uint8List(65);
    point[0] = 4;
    final xb = _bigToBytes(q.x!.toBigInteger()!);
    final yb = _bigToBytes(q.y!.toBigInteger()!);
    point.setAll(1 + (32 - xb.length), xb);
    point.setAll(33 + (32 - yb.length), yb);
    final ecPriv = derSequence([
      derInteger(BigInt.one), // version 1
      derOctetString(_bigToBytes(d).length == 32
          ? _bigToBytes(d)
          : Uint8List(32)..setAll(32 - _bigToBytes(d).length, _bigToBytes(d))),
      derExplicit1(derBitString(point)),
    ]);
    return derSequence([
      derInteger(BigInt.zero), // PKCS8 version 0
      derSequence([derOid(_oidEcPublicKey), derOid(_oidPrime256v1)]),
      derOctetString(ecPriv),
    ]);
  }

  String pkcs8Pem() => pemEncode(pkcs8Der(), 'PRIVATE KEY');
  String spkiBase64Url() => b64urlEncode(spkiDer());

  /// agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1）
  String id() => sha256PubBase64url(spkiDer());
}

// ---------- 生成 / 导入 ----------

SecureRandom newSecureRandom() {
  final rnd = FortunaRandom();
  final seedSource = Random.secure();
  final seeds = Uint8List(32);
  for (var i = 0; i < 32; i++) {
    seeds[i] = seedSource.nextInt(256);
  }
  rnd.seed(KeyParameter(seeds));
  return rnd;
}

EcIdentity generateEcIdentity() {
  final params = ECDomainParameters('prime256v1');
  final gen = ECKeyGenerator()
    ..init(ParametersWithRandom(ECKeyGeneratorParameters(params), newSecureRandom()));
  final pair = gen.generateKeyPair();
  return EcIdentity(pair.privateKey as ECPrivateKey, pair.publicKey as ECPublicKey);
}

/// 从 PKCS8 PEM 导入（App 重启后恢复身份，指纹全生命周期稳定）
EcIdentity importPkcs8Pem(String pem) {
  final der = pemDecode(pem);
  final top = _readTlv(der, 0); // SEQUENCE
  final children = _readChildren(top.content);
  // [0]=INTEGER 0, [1]=AlgId SEQUENCE, [2]=OCTET STRING(ecPriv)
  final ecPrivBytes = children[2].content;
  final ecTop = _readTlv(ecPrivBytes, 0);
  final ecChildren = _readChildren(ecTop.content);
  // [0]=INTEGER 1, [1]=OCTET STRING d, [2]=A1 BIT STRING pubkey
  final d = _bytesToBig(ecChildren[1].content);
  // A1 content = BIT STRING TLV；BIT STRING content 首字节为 unusedBits(0)，其后 04||X||Y
  final inner = _readTlv(ecChildren[2].content, 0);
  final pubBytes = Uint8List.sublistView(inner.content, 1); // 去 unusedBits 字节
  final params = ECDomainParameters('prime256v1');
  final q = params.curve.decodePoint(pubBytes)!;
  return EcIdentity(
    ECPrivateKey(d, params),
    ECPublicKey(q, params),
  );
}

/// 从 SPKI DER/base64url 导入公钥（hello 校验、测试向量用）
ECPublicKey importSpkiDer(Uint8List der) {
  final top = _readTlv(der, 0);
  final children = _readChildren(top.content);
  final bit = children[1]; // BIT STRING
  var pointBytes = bit.content;
  if (pointBytes.isNotEmpty && pointBytes[0] == 0) {
    pointBytes = Uint8List.sublistView(pointBytes, 1); // 去 unusedBits 字节
  }
  final params = ECDomainParameters('prime256v1');
  return ECPublicKey(params.curve.decodePoint(pointBytes)!, params);
}

// ---------- base64url / PEM / hash 工具（契约统一无填充 base64url） ----------

String b64urlEncode(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List b64urlDecode(String s) {
  final norm = s.replaceAll('-', '+').replaceAll('_', '/');
  final pad = (4 - norm.length % 4) % 4;
  return base64.decode(norm + '=' * pad);
}

String pemEncode(List<int> der, String label) {
  final b64 = base64.encode(der);
  final lines = <String>[];
  for (var i = 0; i < b64.length; i += 64) {
    lines.add(b64.substring(i, i + 64 > b64.length ? b64.length : i + 64));
  }
  return '-----BEGIN $label-----\n${lines.join('\n')}\n-----END $label-----';
}

Uint8List pemDecode(String pem) {
  final b64 = pem
      .replaceAll(RegExp('-----[A-Z ]+-----'), '')
      .replaceAll(RegExp(r'\s'), '');
  return base64.decode(b64);
}

/// agent_id / phone_id = sha256(SPKI DER) → base64url（契约 §4.1）
String sha256PubBase64url(List<int> spkiDer) =>
    b64urlEncode(sha256.convert(spkiDer).bytes);
