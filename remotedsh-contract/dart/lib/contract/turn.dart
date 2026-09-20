// TURN 凭证算法（契约 §5）—— 自 js/turn.mjs 移植（App 侧用于本地校验与测试；签发方为 Bridge）
import 'dart:convert';
import 'package:crypto/crypto.dart';

const int turnTtlSeconds = 3600; // 契约 §5

String turnUsername(String pairId,
    [int ttlSeconds = turnTtlSeconds, int? nowSec]) {
  final now = nowSec ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return '${now + ttlSeconds}:$pairId';
}

/// credential = base64(HMAC-SHA1(S, username))
String turnCredential(String secret, String username) {
  final h = Hmac(sha1, utf8.encode(secret));
  return base64.encode(h.convert(utf8.encode(username)).bytes);
}

/// uris 按 §5 固定三元：STUN + TURN/UDP + TURN/TCP（UDP 被封网络的兜底）
List<String> turnUris(String host) => [
      'stun:$host:3478',
      'turn:$host:3478?transport=udp',
      'turn:$host:3478?transport=tcp',
    ];
