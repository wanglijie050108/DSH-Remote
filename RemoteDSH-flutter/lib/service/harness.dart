// 总控状态机 —— 自 tools/fake-phone.mjs + ArkTS HarnessService 移植（App 角色）
// 状态流：IDLE → PAIRING → PAIRED → PUNCHING → CONNECTING → READY（→ REBUILDING 循环）
// 红线：pin 校验 fail-closed（每次 setRemoteDescription 前）；punch 25s×6 重试；
//       TURN 凭证 TTL<300s 视为无效（契约 §5）；错误文案矩阵不静默（03 §3.3）
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:remotedsh_contract/contract/ec_key.dart';
import 'package:remotedsh_contract/contract/fingerprint.dart';
import 'package:remotedsh_contract/contract/qr_pair.dart';

import 'package:remotedsh_flutter/rtc/rtc_link.dart';
import 'package:remotedsh_flutter/service/signal_client.dart';
import 'package:remotedsh_flutter/service/tunnel.dart';

enum HarnessPhase { idle, pairing, paired, punching, connecting, ready, needPair }

class OneShotPairToken {
  String? _value;

  void replace(String? value) => _value = value;

  String? take() {
    final value = _value;
    _value = null;
    return value;
  }
}

class Harness extends ChangeNotifier {
  Harness._();

  static final Harness instance = Harness._();

  HarnessPhase phase = HarnessPhase.idle;
  final List<String> logLines = [];

  EcIdentity? id;
  SignalClient? signal;
  RtcLink? rtc;
  TunnelEndpoint? endpoint;
  LocalProxy? proxy;

  // 配对持久化字段（03 §3.3 存储清单）
  String? sigURL;
  String? authority; // 恒 127.0.0.1:13080
  String? pinnedFp;
  String? agentId;
  String? pairId;
  String launchToken = ''; // QR t= 参数：DSH web 首页鉴权 token（dsh 重启后随新 QR 更新）
  Map<String, dynamic>? turn; // uris/username/credential/ttl + expireAt(ms)

  bool tunnelReady = false;
  bool offerInFlight = false;
  bool get proxyOn => proxy != null;
  int punchAttempt = 0;
  Timer? punchRetryTimer;
  DateTime lastOfferAt = DateTime.fromMillisecondsSinceEpoch(0);
  Completer<void>? pendingRelayAlloc;
  RtcChannel? pendingDataCh;
  RtcChannel? pendingCtlCh;
  Timer? _signalReconnectTimer;
  int _signalReconnectAttempt = 0;
  int _signalGeneration = 0;
  bool _signalConnecting = false;
  bool _signalWanted = false;
  final OneShotPairToken _pairToken = OneShotPairToken();

  static const int punchRetryMs = 25000;
  static const int punchMaxAttempts = 6;
  static const bool relayOnly =
      String.fromEnvironment('DSML_RELAY_ONLY', defaultValue: '1') != '0';

  void log(String s) {
    final now = DateTime.now();
    final ts = now.toIso8601String().substring(11, 23);
    logLines.add('[$ts] $s');
    if (logLines.length > 300) {
      logLines.removeRange(0, logLines.length - 300);
    }
    notifyListeners();
  }

  void _setPhase(HarnessPhase p) {
    phase = p;
    notifyListeners();
  }

  // ---------- 身份与持久化 ----------

  Future<File> _stateFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/remotedsh_state.json');
  }

  Future<File> _keyFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/dsh_phone_key.pem');
  }

  Future<void> ensureIdentity() async {
    if (id != null) return;
    final f = await _keyFile();
    if (await f.exists()) {
      id = importPkcs8Pem(await f.readAsString());
      log('身份已恢复（PKCS8 持久化，指纹全生命周期稳定）');
    } else {
      id = generateEcIdentity();
      await f.writeAsString(id!.pkcs8Pem());
      log('新身份已生成并持久化 phone_id=${id!.id()}');
    }
  }

  Future<void> saveState() async {
    try {
      final f = await _stateFile();
      await f.writeAsString(json.encode({
        'sigURL': sigURL,
        'authority': authority,
        'fp': pinnedFp,
        'agentId': agentId,
        'pairId': pairId,
        'launchToken': launchToken,
        'turn': turn,
      }));
    } catch (e) {
      log('saveState 失败: $e');
    }
  }

  Future<void> loadState() async {
    try {
      final f = await _stateFile();
      if (await f.exists()) {
        final m = json.decode(await f.readAsString()) as Map<String, dynamic>;
        sigURL = m['sigURL'] as String?;
        authority = m['authority'] as String?;
        pinnedFp = m['fp'] as String?;
        agentId = m['agentId'] as String?;
        pairId = m['pairId'] as String?;
        launchToken = (m['launchToken'] as String?) ?? '';
        turn = m['turn'] as Map<String, dynamic>?;
        if (sigURL != null && pinnedFp != null) {
          _setPhase(HarnessPhase.paired);
          log('已恢复配对信息（可免扫码 resume）');
        }
      }
    } catch (e) {
      log('loadState 失败: $e');
    }
  }

  Future<void> clearState() async {
    _signalWanted = false;
    _signalReconnectTimer?.cancel();
    _signalReconnectTimer = null;
    _signalReconnectAttempt = 0;
    _signalGeneration++;
    _pairToken.replace(null);
    await signal?.close();
    signal = null;
    sigURL = null;
    authority = null;
    pinnedFp = null;
    agentId = null;
    pairId = null;
    launchToken = '';
    turn = null;
    tunnelReady = false;
    await saveState();
    _setPhase(HarnessPhase.needPair);
  }

  // ---------- 扫码配对 ----------

  Future<void> scan(String uri) async {
    final qr = parsePairQr(uri.trim());
    if (!qr.ok) {
      log('QR 解析失败: ${qr.error}');
      _setPhase(HarnessPhase.idle);
      return;
    }
    log('QR 解析成功 sig=${qr.s} a=${qr.a} t?=${qr.t != null}');
    _signalWanted = true;
    _signalGeneration++;
    _signalReconnectAttempt = 0;
    _signalReconnectTimer?.cancel();
    _pairToken.replace(qr.pt);
    sigURL = qr.s;
    authority = qr.a;
    pinnedFp = qr.fp;
    launchToken = qr.t ?? '';
    pairId = null;
    agentId = null;
    await teardownTunnel(true);
    await saveState();
    _setPhase(HarnessPhase.pairing);
    await connectSignal();
    // hello.ok 后：服务端有 pair 走 resume，否则 pair.bind（§4.4）
  }

  Future<void> resume() async {
    if (sigURL == null || pinnedFp == null) {
      log('无配对信息，请先扫码');
      return;
    }
    _pairToken.replace(null);
    _signalWanted = true;
    _signalGeneration++;
    _signalReconnectAttempt = 0;
    _signalReconnectTimer?.cancel();
    await teardownTunnel(true);
    _setPhase(HarnessPhase.pairing);
    await connectSignal();
  }

  Future<void> connectSignal() async {
    if (_signalConnecting || !_signalWanted || sigURL == null) return;
    _signalConnecting = true;
    final generation = _signalGeneration;
    final url = sigURL!;
    _signalReconnectTimer?.cancel();
    _signalReconnectTimer = null;
    SignalClient? next;
    var failed = false;
    var superseded = false;
    try {
      await ensureIdentity();
      await signal?.close();
      late final SignalClient sig;
      sig = SignalClient(
        log: log,
        onMessage: (msg) => _onSignalMessage(sig, generation, msg),
        onDisconnected: () => _onSignalDisconnected(sig, generation),
      );
      next = sig;
      signal = sig;
      await sig.connect(url, id!);
      if (!_signalWanted ||
          generation != _signalGeneration ||
          !identical(signal, sig)) {
        superseded = true;
        await sig.close();
      } else {
        log('signal 已连接 → hello(app)');
      }
    } catch (e) {
      failed = true;
      log('signal 连接失败: $e');
    } finally {
      _signalConnecting = false;
    }
    if (failed && (next == null || identical(signal, next))) {
      _scheduleSignalReconnect();
    } else if (superseded && _signalWanted) {
      connectSignal();
    }
  }

  Future<void> _onSignalMessage(
    SignalClient source,
    int generation,
    Map<String, dynamic> msg,
  ) async {
    if (!identical(signal, source) || generation != _signalGeneration) return;
    await onSignalMessage(msg);
  }

  void _onSignalDisconnected(SignalClient source, int generation) {
    if (!identical(signal, source) || generation != _signalGeneration) return;
    log('signal 断开，保留配对状态并准备重连');
    _scheduleSignalReconnect();
  }

  void _scheduleSignalReconnect() {
    if (!_signalWanted ||
        sigURL == null ||
        _signalConnecting ||
        _signalReconnectTimer?.isActive == true) {
      return;
    }
    final delay = signalReconnectDelay(_signalReconnectAttempt++);
    log('signal 将在 ${delay.inMilliseconds}ms 后重连');
    _signalReconnectTimer = Timer(delay, () {
      _signalReconnectTimer = null;
      connectSignal();
    });
  }

  Future<void> onSignalMessage(Map<String, dynamic> msg) async {
    _signalReconnectAttempt = 0;
    switch (msg['t'] as String?) {
      case 'hello.ok':
        if (msg['pair'] != null) {
          // 免扫码恢复（resume）：pair 仍在
          log('hello.ok 免扫码恢复 pair=${(msg['pair'] as Map)['pair_id']}');
          if (pairId == null) {
            pairId = (msg['pair'] as Map)['pair_id'] as String?;
            await saveState();
          }
          _setPhase(HarnessPhase.paired);
          await ensureTurnAndPunch();
        } else {
          final ptok = _pairToken.take();
          if (ptok != null) {
            log('hello.ok 无 pair → pair.bind');
            signal!.send({'t': 'pair.bind', 'ptok': ptok});
          } else {
            log('hello.ok 无 pair → NEED_PAIR（请重新扫码）');
            await clearState();
          }
        }
        return;
      case 'pair.ok':
        _pairToken.replace(null);
        pairId = msg['pair_id'] as String?;
        agentId = msg['agent_id'] as String?;
        final t = msg['turn'] as Map<String, dynamic>;
        turn = {
          ...t,
          'expireAt':
              DateTime.now().millisecondsSinceEpoch + (t['ttl'] as num) * 1000,
        };
        await saveState();
        log('pair.ok → pair=$pairId agent=$agentId（TURN 凭证已收）');
        _setPhase(HarnessPhase.paired);
        await ensureTurnAndPunch();
        return;
      case 'punch.offer':
        await handleOffer(msg['sdp'] as String);
        return;
      case 'relay.alloc':
        turn = {
          ...(msg['turn'] as Map<String, dynamic>),
          'expireAt': DateTime.now().millisecondsSinceEpoch +
              ((msg['turn'] as Map<String, dynamic>)['ttl'] as num) * 1000,
        };
        await saveState();
        log('relay.alloc → 凭证就绪');
        pendingRelayAlloc?.complete();
        pendingRelayAlloc = null;
        return;
      case 'presence':
        final online = msg['peer_online'] == true;
        log('presence peer_online=$online');
        if (online && !tunnelReady) {
          await ensureTurnAndPunch(); // PEER_OFFLINE 恢复后自动重试（03 §3.3）
        }
        return;
      case 'bye':
        log('对端已主动解除配对，请重新扫码（NEED_PAIR + 拆本地隧道）');
        await teardownTunnel(true);
        await clearState();
        return;
      case 'bye.ok':
        log('bye.ok → 清本地 → IDLE');
        await teardownTunnel(true);
        await clearState();
        return;
      case 'pong':
        return;
      case 'error':
        _handleSignalError(msg);
        return;
      default:
        log('signal unknown t: ${msg['t']}');
        return;
    }
  }

  void _handleSignalError(Map<String, dynamic> msg) {
    final action = signalErrorAction(msg);
    log('error ${msg['code']}: $action');
    switch (msg['code'] as String?) {
      case 'PAIR_NOT_FOUND':
      case 'AGENT_RESTARTED':
      case 'PAIR_EXPIRED':
      case 'PAIR_REPLACED':
        teardownTunnel(true).then((_) => clearState());
        return;
      case 'PROTO_VER_UNSUPPORTED':
        _setPhase(HarnessPhase.needPair); // 不重试不重扫
        return;
      default:
        return; // RATE_LIMITED/INTERNAL/PEER_OFFLINE → 保连接等退避/重试
    }
  }

  // ---------- punch（含 25s×6 重试） ----------

  bool turnValid() {
    if (turn == null) return false;
    final expireAt = turn!['expireAt'] as num?;
    return expireAt != null &&
        expireAt > DateTime.now().millisecondsSinceEpoch + 300 * 1000; // TTL<300s 无效（§5）
  }

  bool _punching = false;
  DateTime _lastPunchAt = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> ensureTurnAndPunch() async {
    if (pairId == null && pinnedFp == null) {
      log('no pairing info; nothing to punch');
      return;
    }
    // 重入保护：3s 内只允许一轮（failed/disconnected 可能连发）
    if (_punching) return;
    if (DateTime.now().difference(_lastPunchAt).inMilliseconds < 3000) return;
    _punching = true;
    _lastPunchAt = DateTime.now();
    try {
      await _ensureTurnAndPunchInner();
    } finally {
      _punching = false;
    }
  }

  Future<void> _ensureTurnAndPunchInner() async {
    punchRetryTimer?.cancel();
    punchAttempt = 0;
    _setPhase(HarnessPhase.punching);
    if (!turnValid()) {
      log('no valid TURN creds (TTL<300s) → relay.request（任何新 gather 前必做，契约 §5）');
      signal!.send({'t': 'relay.request'});
      pendingRelayAlloc = Completer<void>();
      try {
        await pendingRelayAlloc!.future
            .timeout(const Duration(milliseconds: 3000));
      } on TimeoutException {
        log('relay.alloc 3s 未达（继续用已有凭证 punch）');
        pendingRelayAlloc = null;
      }
    }
    _sendPunch();
  }

  void _sendPunch() {
    if (pairId == null || signal == null || !signal!.connected) return;
    punchAttempt++;
    signal!.send({'t': 'punch.request', 'pair_id': pairId});
    log('punch.request #$punchAttempt sent');
    if (punchAttempt < punchMaxAttempts && !tunnelReady) {
      punchRetryTimer?.cancel();
      punchRetryTimer =
          Timer(const Duration(milliseconds: punchRetryMs), _sendPunch);
    }
  }

  // ---------- offer/answer 与隧道建立 ----------

  Future<void> handleOffer(String sdp) async {
    final now = DateTime.now();
    if (offerInFlight && now.difference(lastOfferAt).inMilliseconds < 6000) {
      log('duplicate offer in flight window → ignore'); // 03 §3.3 重复 offer 容忍
      return;
    }
    lastOfferAt = now;
    offerInFlight = true;
    punchRetryTimer?.cancel();
    await teardownTunnel(false);

    // ★ pin 红线：每一次 setRemoteDescription 之前执行（03 §3.1；§6.1 fail-closed）
    final lines = sdp.split(RegExp(r'\r?\n'));
    if (!verifyPin(pinnedFp, lines)) {
      log('PIN FAIL: 对端身份校验失败 → 中止（MUST NOT setRemoteDescription）');
      return;
    }
    log('pin ok（与持久化 fp 逐字节一致）');
    _setPhase(HarnessPhase.connecting);

    final rtcLink = await RtcLink.create(
      iceServerConfigs(),
      iceTransportPolicy: relayOnly ? 'relay' : 'all',
    );
    rtc = rtcLink;
    pendingDataCh = null;
    pendingCtlCh = null;

    final both = Completer<void>();
    rtcLink.onChannel = (label, ch) {
      log('onDataChannel: $label');
      if (label == 'data') {
        pendingDataCh = ch;
      } else if (label == 'ctl') {
        pendingCtlCh = ch;
      } else {
        log('unknown channel label → 协议错误，断开（§3 通道识别）');
      }
      if (pendingDataCh != null && pendingCtlCh != null && !both.isCompleted) {
        both.complete();
      }
    };
    rtcLink.onConnectionState = (s) {
      log('rtc conn: $s');
      // native 回调为枚举全名（如 RTCPeerConnectionStateFailed），用包含匹配
      final lower = s.toLowerCase();
      // closed 是我们自己 teardown 时触发的（native 只经 close() 进入 closed），不算失败
      if (lower.contains('failed') || lower.contains('disconnected')) {
        tunnelReady = false;
        _setPhase(HarnessPhase.punching);
        ensureTurnAndPunch().catchError((Object e) { log('rebuild err: $e'); });
      }
    };

    _startStatsPoll(rtcLink); // 协商阶段即采样（Failed 时刻最有诊断价值）
    final answerSdp = await rtcLink.createFullAnswer(sdp);
    log('OFFER 候选: ${_candSummary(sdp)}');
    log('ANSWER 候选: ${_candSummary(answerSdp)}');
    signal!.send({'t': 'punch.answer', 'pair_id': pairId, 'sdp': answerSdp});
    log('punch.answer 已发送（等待 data+ctl 两条通道）');

    try {
      await both.future.timeout(const Duration(seconds: 20), onTimeout: () {
        throw TimeoutException('channels timeout');
      });
    } on TimeoutException {
      log('等待 data/ctl 通道超时（20s）');
      offerInFlight = false;
      return;
    }

    endpoint?.close();
    final ep = TunnelEndpoint(
      mode: 'initiator',
      log: log,
      onDead: (reason) {
        tunnelReady = false;
        _setPhase(HarnessPhase.punching);
        ensureTurnAndPunch().catchError((Object e) { log('rebuild err: $e'); });
      },
    );
    endpoint = ep;
    ep.bind(pendingDataCh!, pendingCtlCh!);
    tunnelReady = true; // endpoint 就绪后才算 READY（消除日志与赋值间竞态窗口）
    offerInFlight = false;
    log('TUNNEL READY (P2P or TURN)');
    _setPhase(HarnessPhase.ready);
    await startProxy();
  }

  /// SDP 候选摘要：数量 + 类型分布 + relay 地址（跨网络排障核心证据）
  String _candSummary(String sdp) {
    final types = <String, int>{};
    String? relayAddr;
    for (final m in RegExp(r'a=candidate:\S+ \d+ \S+ \d+ ([^ ]+) (\d+) typ (\S+)')
        .allMatches(sdp)) {
      final t = m.group(3)!;
      types[t] = (types[t] ?? 0) + 1;
      if (t == 'relay') relayAddr = '${m.group(1)}:${m.group(2)}';
    }
    return '${types.toString()}${relayAddr != null ? ' relay=$relayAddr' : ''}';
  }

  Timer? _statsTimer;

  /// 每 5s 采样选中 candidate-pair：路径类型(P2P/relay)/字节增量/rtt——断线定性用数据说话
  void _startStatsPoll(RtcLink link) {
    _statsTimer?.cancel();
    int lastSent = 0, lastRecv = 0;
    var tick = 0;
    _statsTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      tick++;
      if (tick % 6 != 1) return; // 30s 一条，避免刷屏淹没 console 日志
      try {
        final stats = await link.pc.getStats();
        String? pairInfo;
        final cands = <String, String>{};
        final typeCount = <String, int>{};
        for (final rep in stats) {
          typeCount[rep.type] = (typeCount[rep.type] ?? 0) + 1;
          final v = rep.values;
          if (rep.type == 'local-candidate' || rep.type == 'remote-candidate') {
            cands[rep.id] =
                '${v['candidateType']}@${v['ip'] ?? v['address']}:${v['port']}';
          }
        }
        log('STATS types=$typeCount');
        for (final rep in stats) {
          final v = rep.values;
          final isPair = rep.type == 'candidate-pair' ||
              rep.type == 'googCandidatePair';
          final state = v['state'] ?? v['googActive'];
          final succeeded = state == 'succeeded' ||
              state == 'true' ||
              v['selected'] == true ||
              v['nominated'] == true;
          if (isPair && succeeded) {
            final sent = (v['bytesSent'] as num?)?.toInt() ?? 0;
            final recv = (v['bytesReceived'] as num?)?.toInt() ?? 0;
            final rtt = v['currentRoundTripTime'];
            final lc = cands[v['localCandidateId']] ?? '?';
            final rc = cands[v['remoteCandidateId']] ?? '?';
            pairInfo =
                'pair $lc <-> $rc bytes=$sent/$recv(delta ${sent - lastSent}/${recv - lastRecv}) rtt=$rtt state=$state';
            lastSent = sent;
            lastRecv = recv;
          }
        }
        if (pairInfo != null) log('STATS $pairInfo');
      } catch (_) {}
    });
  }

  List<Map<String, dynamic>> iceServerConfigs() {
    final uris = (turn?['uris'] as List?)?.cast<String>() ?? const <String>[];
    final username = turn?['username'] as String?;
    final credential = turn?['credential'] as String?;
    // ohos 插件 getString('urls') 不认列表 → 每条 server 单独下发 url（字符串）
    return [
      for (final u in uris)
        if (u.startsWith('turn:'))
          {
            'url': u,
            if (username != null) 'username': username,
            if (credential != null) 'credential': credential,
          }
        else
          {'url': u},
    ];
  }

  // ---------- 本地代理 ----------

  Future<void> startProxy() async {
    if (proxy != null) return; // 重建隧道时代理常驻，勿重复 bind（否则 EADDRINUSE）
    final p = LocalProxy(
      port: 13080,
      log: log,
      endpointOf: () => tunnelReady ? endpoint : null,
      tunnelReady: () => tunnelReady,
    );
    try {
      await p.start();
      proxy = p;
    } catch (e) {
      log('本地端口 13080 启动失败: $e（请关闭占用它的应用并重试，不做端口回退，03 §3.2）');
    }
  }

  Future<void> teardownTunnel(bool destroyProxy) async {
    tunnelReady = false;
    offerInFlight = false;
    punchRetryTimer?.cancel();
    _statsTimer?.cancel();
    _statsTimer = null;
    endpoint?.close();
    endpoint = null;
    await rtc?.close();
    rtc = null;
    pendingDataCh = null;
    pendingCtlCh = null;
    if (destroyProxy) {
      await proxy?.stop();
      proxy = null;
    }
    _setPhase(pairId != null && sigURL != null
        ? HarnessPhase.paired
        : HarnessPhase.needPair);
  }

  Future<void> unpair() async {
    if (signal == null || !signal!.connected) {
      await teardownTunnel(true);
      await clearState();
      return;
    }
    signal!.send({'t': 'bye', 'reason': 'user'});
    // bye.ok 消息路径负责清理；2s 超时兜底仍拆本地
    Timer(const Duration(seconds: 2), () async {
      if (pairId != null) {
        log('bye.ok 超时(2s) → 仍拆本地');
        await teardownTunnel(true);
        await clearState();
      }
    });
  }

  String get dshUrl => launchToken.isNotEmpty
      ? 'http://127.0.0.1:13080/?token=$launchToken'
      : 'http://127.0.0.1:13080';
}
