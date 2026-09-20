// 信令客户端（契约 §4）—— 自 tools/fake-phone.mjs 信令部分移植
// hello（role=app）+ 心跳 25s ping + 消息分发；错误文案矩阵不静默失败（03 §3.3）
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:remotedsh_contract/contract/ec_key.dart';
import 'package:remotedsh_contract/contract/hello.dart';

class SignalClient {
  WebSocket? _ws;
  Timer? _heartbeat;
  bool _closing = false;
  bool _disconnectNotified = false;
  final void Function(String) log;
  final Future<void> Function(Map<String, dynamic> msg) onMessage;
  final void Function()? onDisconnected;
  SignalClient({
    required this.log,
    required this.onMessage,
    this.onDisconnected,
  });

  bool get connected => _ws != null && _ws!.readyState == WebSocket.open;

  Future<void> connect(String sigUrl, EcIdentity id) async {
    final ws = await WebSocket.connect(sigUrl.replaceFirst('http', 'ws'));
    _closing = false;
    _disconnectNotified = false;
    _ws = ws;
    ws.listen((data) {
      if (data is String) {
        try {
          final msg = json.decode(data) as Map<String, dynamic>;
          onMessage(msg).catchError((Object e) {
            log('signal handler error: $e');
          });
        } catch (e) {
          log('signal bad json: $e');
        }
      }
    }, onDone: () {
      log('signal closed');
      _handleDisconnect(ws);
    }, onError: (Object e) {
      log('signal error: $e');
      _handleDisconnect(ws);
    });
    ws.add(json.encode(buildHello(role: 'app', id: id)));
    // 心跳义务：每 25s 发 ping（契约 §4；缺失会被 60s sweeper 判离线）
    stopHeartbeat();
    _heartbeat = Timer.periodic(const Duration(seconds: 25), (_) {
      if (connected) _ws!.add(json.encode({'t': 'ping'}));
    });
  }

  void stopHeartbeat() {
    _heartbeat?.cancel();
    _heartbeat = null;
  }

  void send(Map<String, dynamic> obj) {
    if (connected) _ws!.add(json.encode(obj));
  }

  Future<void> close() async {
    _closing = true;
    stopHeartbeat();
    final ws = _ws;
    _ws = null;
    try {
      await ws?.close();
    } catch (_) {}
  }

  void _handleDisconnect(WebSocket ws) {
    if (!identical(_ws, ws)) return;
    _ws = null;
    stopHeartbeat();
    unawaited(_closeSocket(ws));
    if (!_closing && !_disconnectNotified) {
      _disconnectNotified = true;
      onDisconnected?.call();
    }
  }

  Future<void> _closeSocket(WebSocket ws) async {
    try {
      await ws.close();
    } catch (_) {}
  }
}

Duration signalReconnectDelay(int attempt, {Random? random}) {
  final cappedAttempt = attempt.clamp(0, 6) as int;
  final baseMs = min(24000, 500 * (1 << cappedAttempt));
  final jitterMs = ((random ?? Random()).nextDouble() * baseMs * 0.25).round();
  return Duration(milliseconds: min(30000, baseMs + jitterMs));
}

/// 03 §3.3 错误文案矩阵（不静默失败）；返回用户可读处置，或 null（无需处置）
String? signalErrorAction(Map<String, dynamic> msg) {
  switch (msg['code'] as String?) {
    case 'PEER_OFFLINE':
      return 'PEER_OFFLINE：保持连接，等 presence 恢复后自动重试';
    case 'PAIR_NOT_FOUND':
    case 'AGENT_RESTARTED':
    case 'PAIR_EXPIRED':
      return '请重新扫码（NEED_PAIR + 拆本地隧道）';
    case 'PAIR_REPLACED':
      return '已在另一台手机完成配对（被动方 → 清配对 + 拆隧道）';
    case 'PROTO_VER_UNSUPPORTED':
      return '版本过旧（expect $protoVer），请升级 App。不重试、不提示重新扫码';
    case 'PAIR_LIMIT':
      return '服务繁忙，不自动重试';
    case 'RATE_LIMITED':
    case 'INTERNAL':
      return '${msg['code']} → 指数退避';
    default:
      return 'error: ${msg['code']} ${msg['msg'] ?? ''}';
  }
}
