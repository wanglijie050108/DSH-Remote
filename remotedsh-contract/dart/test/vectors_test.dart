// G2 向量测试：四套向量（frames/hello-signature/qr-pair/fingerprint-normalize）
// 数据源：remotedsh-contract/vectors/*.json（与 Node/Go/Kotlin 共用同一批字节级向量）
// 运行：dart test（在 dart/ 包根目录；向量取 ../vectors）
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:remotedsh_contract/contract/ec_key.dart';
import 'package:remotedsh_contract/contract/frames.dart';
import 'package:remotedsh_contract/contract/fingerprint.dart';
import 'package:remotedsh_contract/contract/hello.dart';
import 'package:remotedsh_contract/contract/qr_pair.dart';
import 'package:remotedsh_contract/contract/turn.dart';

const vectorsDir = '../vectors';

Map<String, dynamic> load(String name) =>
    json.decode(File('$vectorsDir/$name').readAsStringSync()) as Map<String, dynamic>;

Uint8List hexToBytes(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String bytesToHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void _expectDecode(Map<String, dynamic> c, Uint8List bytes) {
  final exp = c['decode'] as Map<String, dynamic>?;
  if (exp == null) {
    // 错误用例：decode_error 标注期望错误码
    final code = c['decode_error'] as String;
    expect(() => decodeFrame(bytes),
        throwsA(predicate((e) => e is FrameError && e.code == code)),
        reason: c['name']);
    return;
  }
  final f = decodeFrame(bytes);
  expect(f.ver, exp['ver'], reason: c['name']);
  // type 名或 type_code 二选一
  if (exp['type'] != null) {
    expect(FrameType.name(f.type), exp['type'], reason: c['name']);
  }
  if (exp['type_code'] != null) {
    expect(f.type, exp['type_code'], reason: c['name']);
  }
  // flags：无特殊标注时恒 0；flags_read_as 表示接收方读到非 0 仍按消息解码
  final flagsExp = exp['flags_read_as'] ?? exp['flags'] ?? 0;
  expect(f.flags, flagsExp, reason: c['name']);
  final sidExp = exp['stream_id_read_as'] ?? exp['stream_id'];
  if (sidExp != null) expect(f.streamId, sidExp, reason: c['name']);
  // 载荷：payload_hex / payload_utf8 / payload_len / credit 任一形态
  if (exp['payload_hex'] != null) {
    expect(bytesToHex(f.payload), exp['payload_hex'], reason: c['name']);
  }
  if (exp['payload_utf8'] != null) {
    expect(utf8.decode(f.payload), exp['payload_utf8'], reason: c['name']);
  }
  if (exp['payload_len'] != null) {
    expect(f.payload.length, exp['payload_len'], reason: c['name']);
  }
  if (exp['credit'] != null) {
    expect(f.payload.length, 4, reason: c['name']); // WINDOW credit = u32 BE
    final dv = ByteData.sublistView(f.payload);
    expect(dv.getUint32(0, Endian.big), exp['credit'], reason: c['name']);
  }
}

void main() {
  test('G2 frames: 14 cases', () {
    final v = load('frames.json');
    for (final c in v['cases']) {
      final Uint8List bytes;
      if (c['frame_hex'] != null) {
        bytes = hexToBytes(c['frame_hex'] as String);
      } else {
        // construct 用例：手工拼 11B 头 + 超限载荷（不发载荷，只拼声明长度的头即可触发 LEN_OVERFLOW）
        final cons = c['construct'] as Map<String, dynamic>;
        final hdr = Uint8List(11);
        final dv = ByteData.sublistView(hdr);
        dv.setUint8(0, cons['ver'] as int);
        dv.setUint8(1, const {
          'OPEN': 1, 'DATA': 2, 'FIN': 3, 'RST': 4,
          'WINDOW': 5, 'PING': 6, 'PONG': 7,
        }[cons['type'] as String]!);
        dv.setUint8(2, cons['flags'] as int);
        dv.setUint32(3, cons['stream_id'] as int, Endian.big);
        dv.setUint32(7, cons['payload_len'] as int, Endian.big);
        bytes = hdr;
      }
      _expectDecode(c, bytes);
    }
  });

  test('G2 frames: encode 往返（含边界 len=16373）', () {
    // encode(decode(x)) == x 对全部合法用例成立
    final v = load('frames.json');
    for (final c in v['cases']) {
      if (c['decode'] == null) continue;
      final bytes = hexToBytes(c['frame_hex'] as String);
      final f = decodeFrame(bytes);
      final re = encodeFrame(f.type, f.streamId, f.payload);
      // flags 读侧容忍非 0，但编码恒置 0 → 与原帧仅在 flags 非 0 用例可能不同
      if (f.flags == 0) {
        expect(bytesToHex(re), bytesToHex(bytes), reason: c['name']);
      }
    }
    // LEN_OVERFLOW 发送侧防线
    expect(() => encodeFrame(FrameType.data, 1, List.filled(16374, 0)),
        throwsA(predicate((e) => e is FrameError && e.code == 'LEN_OVERFLOW')));
  });

  test('G2 hello-signature: 6 cases（canonicalBytes 逐字节 + 验签 + DER 形态）', () {
    final v = load('hello-signature.json');
    for (final c in v['cases']) {
      final ts = c['ts'] as int;
      final nonce = c['nonce'] as String;
      final pub = b64urlDecode(c['pub'] as String);
      if (c['expected_msg_hex'] != null) {
        final msg = hexToBytes(c['expected_msg_hex'] as String);
        expect(bytesToHex(canonicalBytes(ts, nonce)), bytesToHex(msg),
            reason: '${c['name']} canonical bytes');
      }
      final ok = verifyHello(pub, ts, nonce, c['expected_sig_base64url'] as String);
      expect(ok, c['expect_verify'] as bool, reason: c['name']);
      final sig = b64urlDecode(c['expected_sig_base64url'] as String);
      expect(sig[0], 0x30, reason: '${c['name']} DER SEQUENCE');
    }
  });

  test('hello: 本地身份 sign/verify 往返 + PKCS8 导入导出往返 + RFC6979 确定性', () {
    final id = generateEcIdentity();
    const ts = 1770000000;
    final nonce = randomNonce();
    final sig = signHello(id, ts, nonce);
    expect(verifyHello(id.spkiDer(), ts, nonce, sig), isTrue);
    // 篡改 nonce → 必须失败
    expect(verifyHello(id.spkiDer(), ts, '${nonce}x', sig), isFalse);
    // PKCS8 往返：私钥一致、SPKI 一致
    final restored = importPkcs8Pem(id.pkcs8Pem());
    expect(bytesToHex(restored.spkiDer()), bytesToHex(id.spkiDer()));
    // RFC 6979 确定性：同输入两次签名逐字节一致
    expect(signHelloDeterministic(id, ts, nonce),
        signHelloDeterministic(id, ts, nonce));
    // RFC 6979 签名也能通过验签
    expect(verifyHello(id.spkiDer(), ts, nonce,
        signHelloDeterministic(id, ts, nonce)), isTrue);
  });

  test('G2 qr-pair: 5 cases', () {
    final v = load('qr-pair.json');
    for (final c in v['cases']) {
      final r = parsePairQr(c['uri'] as String);
      final exp = c['expect'] as Map<String, dynamic>?;
      if (exp != null) {
        expect(r.ok, isTrue, reason: c['name']);
        expect(r.v, exp['v'], reason: c['name']);
        expect(r.s, exp['s'], reason: c['name']);
        expect(r.pt, exp['pt'], reason: c['name']);
        expect(r.fp, exp['fp'], reason: c['name']);
        expect(r.a, exp['a'], reason: c['name']);
      } else {
        expect(r.ok, isFalse, reason: c['name']);
      }
    }
  });

  test('G2 fingerprint-normalize: 7 cases', () {
    final v = load('fingerprint-normalize.json');
    for (final c in v['cases']) {
      final lines = (c['offer_lines'] as List).cast<String>();
      final got = extractPinnedFingerprint(lines);
      final exp = c['expect'] as String?;
      expect(got, exp, reason: c['name']);
    }
  });

  test('turn: username/credential 固定向量（与 js/turn.mjs 对拍）', () {
    final u = turnUsername('p1', 3600, 1700000000);
    expect(u, '1700003600:p1');
    final c1 = turnCredential('s3cr3t', u);
    final c2 = turnCredential('s3cr3t', u);
    expect(c1, c2); // 确定性
    expect(c1.length, 28); // HMAC-SHA1 20B → base64 28 字符（含 padding）
    // node 实测对拍值（js/turn.mjs 同算法）
    expect(c1, 'j9uW1dRkpmogBUOlB9gxYYE37zk=');
  });
}
