// 隧道泵（契约 §3.1–§3.5）—— 自 tools/lib/tunnel-pump.mjs 移植；手机侧用 initiator 模式
// 关键红线（skill §6 / 契约 §3.3）：
//   FIN 半关闭（RawSocket.shutdown(send)）继续读；终态迟到帧静默忽略（不回 RST，防风暴）；
//   收到 RST 一律不回；重复/无效 OPEN 静默忽略并计错；WINDOW.credit = 实际写入 socket 的增量；
//   未发送队列 单流 ≤256KiB 全局 ≤512KiB（bufferedAmount）；信用 0 停读 socket；
//   PING/PONG 走 ctl（stream_id=0）；保活 5s / 15s 无帧判死。
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:remotedsh_contract/contract/frames.dart';
import 'package:remotedsh_flutter/rtc/rtc_link.dart';

const String authority = '127.0.0.1:13080'; // 契约 §1 固定值
const int creditInitial = 256 * 1024;
const int windowThreshold = 64 * 1024;
const int perStreamQueueMax = 256 * 1024;
const int globalQueueMax = 512 * 1024;
const int maxStreams = 128;
const int keepaliveMs = 5000;
const int deadMs = 15000;

class _Stream {
  final RawSocket socket;
  int credit;
  int writtenSinceWindow = 0;
  bool finSent = false;
  bool finRecv = false;
  bool rst = false;
  bool readingPaused = false;
  _Stream(this.socket) : credit = creditInitial;
}

class TunnelEndpoint {
  final String mode; // 'initiator'（手机）| 'acceptor'（插件；移植保真用）
  final void Function(String) log;
  final Future<RawSocket?> Function()? connectFactory; // acceptor 专用
  final void Function(String reason)? onDead;

  RtcChannel? dataCh;
  RtcChannel? ctlCh;
  final Map<int, _Stream> streams = {};
  int nextStreamId = 1;
  int errors = 0;
  DateTime lastFrameAt = DateTime.now();
  bool _deadFired = false;

  Timer? _pingTimer;
  Timer? _deadTimer;

  TunnelEndpoint({
    required this.mode,
    required this.log,
    this.connectFactory,
    this.onDead,
  }) {
    _pingTimer = Timer.periodic(const Duration(milliseconds: keepaliveMs), (_) {
      try {
        ctlCh?.send(encodeFrame(FrameType.ping, 0, _pingRand()));
        log('KA: PING sent (ctlCh=${ctlCh != null})');
      } catch (e) {
        log('KA: PING send failed: $e');
      }
    });
    _deadTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_deadFired &&
          DateTime.now().difference(lastFrameAt).inMilliseconds > deadMs) {
        _deadFired = true;
        log('tunnel dead: no frame for 15s (兜底触发器, 契约 §3.5)');
        onDead?.call('no frame 15s');
      }
    });
  }

  /// 通道就绪后回填（RTC 侧 onDataChannel / createDataChannel 完成后调用）
  void bind(RtcChannel data, RtcChannel ctl) {
    dataCh = data;
    ctlCh = ctl;
    data.onMessage = (Uint8List bytes) => _onChannel(bytes, isCtl: false);
    ctl.onMessage = (Uint8List bytes) => _onChannel(bytes, isCtl: true);
  }

  void close() {
    _pingTimer?.cancel();
    _deadTimer?.cancel();
    _teardownAll('endpoint closed');
  }

  void _teardownAll(String reason) {
    for (final st in streams.values) {
      try {
        st.socket.shutdown(SocketDirection.both);
      } catch (_) {}
      try {
        st.socket.close();
      } catch (_) {}
    }
    streams.clear();
    log('tunnel teardown: $reason');
  }

  // ---- 发起方：为一条已 accept 的本地 RawSocket 开流 ----
  int? openStream(RawSocket socket) {
    if (streams.length >= maxStreams) {
      try {
        socket.close();
      } catch (_) {}
      return null; // §3.4 上限（发起方自觉）
    }
    final id = nextStreamId++;
    final st = _Stream(socket);
    streams[id] = st;
    final open = encodeFrame(
        FrameType.open,
        id,
        Uint8List.fromList(
            '{"authority":"$authority"}'.codeUnits)); // §1 authority 一致性断言
    _sendData(open, st);
    _pumpSocketToChannel(id, st);
    return id;
  }

  void _pumpSocketToChannel(int id, _Stream st) {
    RawSocketEvent? handle(RawSocketEvent ev) {
      if (st.rst || st.finSent) return null;
      switch (ev) {
        case RawSocketEvent.read:
          // 信用控制：信用 0 → 停读（§3.4.5 发送方信用为 0 即暂停读）
          if (st.credit <= 0) {
            st.readingPaused = true;
            st.socket.readEventsEnabled = false; // 停读，等 WINDOW 恢复（防 level-triggered 忙转）
            return null;
          }
          while (true) {
            if (st.credit <= 0) {
              st.readingPaused = true;
              st.socket.readEventsEnabled = false;
              return null;
            }
            final want = st.credit < 16373 * 4 ? st.credit : 16373 * 4;
            final chunk = st.socket.read(want);
            if (chunk == null || chunk.isEmpty) break;
            if (!_emitData(id, st, chunk)) return null; // 队列超限 → 暂停
          }
          return null;
        case RawSocketEvent.readClosed:
          // 本地 socket 半关闭（对端关写）→ FIN（走 data，§3.2/§3.4.8）+ 信用补齐
          finalize(id);
          if (!st.finSent && !st.rst) {
            st.finSent = true;
            try {
              _sendData(encodeFrame(FrameType.fin, id), st);
            } catch (_) {}
          }
          return null;
        case RawSocketEvent.closed:
          finalize(id);
          streams.remove(id);
          return null;
        case RawSocketEvent.write:
          _flushPending(id, st);
          return null;
        default:
          return null;
      }
    }

    st.socket.listen(handle);
    // listen 内部消费事件；无需显式 read 循环 —— RawSocket 事件驱动
  }

  /// 返回 false = 队列超限需暂停（调用方须关读事件）
  bool _emitData(int id, _Stream st, Uint8List chunk) {
    // 未发送队列约束（§3.4.7）：单流 256KiB / 全局 512KiB
    final buffered = dataCh?.bufferedAmount ?? 0;
    if (buffered >= perStreamQueueMax || _globalBuffered() >= globalQueueMax) {
      st.readingPaused = true;
      st.socket.readEventsEnabled = false;
      return false;
    }
    st.credit -= chunk.length;
    for (var off = 0; off < chunk.length; off += maxPayload) {
      final end = (off + maxPayload < chunk.length) ? off + maxPayload : chunk.length;
      final slice = Uint8List.sublistView(chunk, off, end);
      final frame = encodeFrame(FrameType.data, id, slice);
      _sendData(frame, st);
    }
    return true;
  }

  void _sendData(Uint8List frame, _Stream st) {
    try {
      dataCh?.send(frame);
    } catch (_) {}
  }

  void _sendCtl(Uint8List frame) {
    try {
      ctlCh?.send(frame);
    } catch (_) {}
  }

  int _globalBuffered() {
    // Dart 侧统一以 data 通道 bufferedAmount 度量（事件驱动更新）
    return dataCh?.bufferedAmount ?? 0;
  }

  /// 通道 → 本地 socket（两个角色同一份状态机，契约 §3.3 逐行实现）
  void _onChannel(Uint8List bytes, {required bool isCtl}) {
    lastFrameAt = DateTime.now();
    Frame frame;
    try {
      frame = decodeFrame(bytes);
    } on FrameError catch (e) {
      if (e.code == 'BAD_VER') {
        log('FATAL: frame ver != 1 → disconnect (§3.1)');
        if (!_deadFired) {
          _deadFired = true;
          onDead?.call('BAD_VER');
        }
        return;
      }
      if (e.code == 'LEN_OVERFLOW') {
        // stream_id 可解析（≥11B 且 ver 合法）→ 对该流 RST；否则丢弃整帧计错
        if (bytes.length >= 11 && bytes[0] == 1) {
          final dv = ByteData.sublistView(bytes);
          final id = dv.getUint32(3, Endian.big);
          _sendCtl(encodeFrame(FrameType.rst, id,
              Uint8List.fromList('frame too large'.codeUnits)));
        }
        errors++;
      } else {
        errors++; // HEADER_INCOMPLETE / truncated：丢弃计错
      }
      return;
    }
    final id = frame.streamId;
    switch (frame.type) {
      case FrameType.open:
        if (mode != 'acceptor') {
          errors++; // 手机不会收到 OPEN（手机是发起方）
          return;
        }
        if (id == 0 || streams.containsKey(id)) {
          errors++; // 无效/重复 OPEN：静默忽略计错，不回 RST（§3.3 v1.0.5）
          return;
        }
        String? a;
        try {
          a = String.fromCharCodes(frame.payload);
          a = a.startsWith('{"authority":"') ? a.substring(14, a.length - 2) : null;
        } catch (_) {}
        if (a != authority) {
          errors++;
          log('OPEN authority mismatch: $a');
          return;
        }
        if (streams.length >= maxStreams) {
          // 白名单①：超限新 OPEN → RST
          _sendCtl(encodeFrame(
              FrameType.rst, id, Uint8List.fromList('stream limit'.codeUnits)));
          return;
        }
        _acceptConnect(id);
        return;
      case FrameType.data:
        final st = streams[id];
        if (st == null || st.rst) return; // 终态/未知流迟到帧：静默忽略（§3.3 v1.0.4）
        _writeToSocket(id, st, frame.payload);
        return;
      case FrameType.fin:
        final st = streams[id];
        if (st == null || st.rst) return;
        if (st.finRecv) return; // 幂等（§3.3）
        st.finRecv = true;
        try {
          st.socket.shutdown(SocketDirection.send); // 半关闭：只关本端写方向，继续读（红线）
        } catch (_) {}
        _maybeClose(id, st);
        return;
      case FrameType.rst:
        final st = streams[id];
        if (st != null) {
          st.rst = true;
          try {
            st.socket.shutdown(SocketDirection.both);
          } catch (_) {}
          try {
            st.socket.close();
          } catch (_) {}
          streams.remove(id);
        }
        return; // 收到 RST 一律不回 RST（§3.3 防风暴）
      case FrameType.window:
        final st = streams[id];
        if (st == null || st.rst) return;
        if (frame.payload.length >= 4) {
          final dv = ByteData.sublistView(frame.payload);
          final delta = dv.getUint32(0, Endian.big);
          st.credit += delta;
          if (st.readingPaused && st.credit > 0) {
            st.readingPaused = false;
            st.socket.readEventsEnabled = true; // 恢复读
          }
        }
        return;
      case FrameType.ping:
        log('KA: PING recv -> PONG');
        _sendCtl(encodeFrame(FrameType.pong, 0, frame.payload)); // 回显随机数，stream_id=0
        return;
      case FrameType.pong:
        log('KA: PONG recv');
        return;
      default:
        errors++; // 未知 type：静默忽略计错，不关隧道（§3.3）
        return;
    }
  }

  Future<void> _acceptConnect(int id) async {
    final raw = await (connectFactory?.call() ?? Future<RawSocket?>.value(null));
    if (raw == null) return;
    final st = _Stream(raw);
    streams[id] = st;
    _pumpSocketToChannel(id, st);
  }

  void _writeToSocket(int id, _Stream st, Uint8List payload) {
    // 已有积压（内核缓冲满）→ 严格按序追加，禁止直写造成流错乱
    final pending = _pendingWrites[id];
    if (pending != null) {
      final merged = Uint8List(pending.length + payload.length);
      merged.setAll(0, pending);
      merged.setAll(pending.length, payload);
      _pendingWrites[id] = merged;
      st.writtenSinceWindow += payload.length;
      if (st.writtenSinceWindow >= windowThreshold) _sendWindow(id, st);
      st.socket.writeEventsEnabled = true;
      return;
    }
    final n = st.socket.write(payload);
    if (n < payload.length) {
      _pendingWrites[id] = Uint8List.sublistView(payload, n);
      st.socket.writeEventsEnabled = true;
    }
    st.writtenSinceWindow += payload.length;
    if (st.writtenSinceWindow >= windowThreshold) _sendWindow(id, st);
  }

  final Map<int, Uint8List> _pendingWrites = {};

  void _flushPending(int id, _Stream st) {
    final pending = _pendingWrites[id];
    if (pending == null) return;
    final n = st.socket.write(pending);
    if (n < pending.length) {
      _pendingWrites[id] = Uint8List.sublistView(pending, n);
      st.socket.writeEventsEnabled = true;
    } else {
      _pendingWrites.remove(id);
      st.socket.writeEventsEnabled = false;
      _maybeClose(id, st);
    }
  }

  void _maybeClose(int id, _Stream st) {
    if (st.finRecv && _pendingWrites[id] == null) {
      // 双向都关了 → 资源清理
      try {
        st.socket.close();
      } catch (_) {}
    }
  }

  void _sendWindow(int id, _Stream st) {
    if (st.writtenSinceWindow <= 0) return;
    final delta = st.writtenSinceWindow;
    st.writtenSinceWindow = 0;
    final b = Uint8List(4);
    ByteData.sublistView(b).setUint32(0, delta > 0xFFFFFFFF ? 0xFFFFFFFF : delta, Endian.big);
    _sendCtl(encodeFrame(FrameType.window, id, b)); // 增量语义（§3.4.5）
  }

  /// 流关闭前的最终补齐通告（§3.4.5：流关闭前 MUST 把已写入字节数补齐通告）
  void finalize(int id) {
    final st = streams[id];
    if (st == null) return;
    _sendWindow(id, st);
  }
}

/// 本地代理（契约 §3.2）：固定 authority，仅 loopback；隧道未就绪立即 close，不排队
class LocalProxy {
  final int port;
  final void Function(String) log;
  final TunnelEndpoint? Function() endpointOf;
  final bool Function() tunnelReady;

  RawServerSocket? _server;

  LocalProxy({
    required this.port,
    required this.log,
    required this.endpointOf,
    required this.tunnelReady,
  });

  Future<void> start() async {
    if (_server != null) return;
    _server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, port);
    log('local proxy on 127.0.0.1:$port (authority 固定，Host=127.0.0.1:13080)');
    _server!.listen((socket) {
      final remote = socket.remoteAddress;
      if (!remote.isLoopback) {
        try {
          socket.shutdown(SocketDirection.both);
        } catch (_) {}
        try {
          socket.close();
        } catch (_) {}
        return;
      }
      final ep = endpointOf();
      if (!tunnelReady() || ep == null) {
        try {
          socket.shutdown(SocketDirection.both);
        } catch (_) {}
        try {
          socket.close();
        } catch (_) {}
        return; // 立即 close，不排队不缓冲
      }
      final id = ep.openStream(socket);
      if (id == null) {
        try {
          socket.shutdown(SocketDirection.both);
        } catch (_) {}
        try {
          socket.close();
        } catch (_) {}
      }
    }, onError: (Object e) {
      log('proxy error: $e');
    });
  }

  Future<void> stop() async {
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
  }
}

final _pingRand = _SecureRandom8();

class _SecureRandom8 {
  final _r = DateTime.now().microsecondsSinceEpoch;
  int _c = 0;
  Uint8List call() {
    final b = Uint8List(8);
    // PING nonce 仅要求「回显一致性」；避免每帧开 SecureRandom 的开销
    final v = _r + _c++ * 7919;
    for (var i = 0; i < 8; i++) {
      b[i] = (v >> (i * 8)) & 0xff;
    }
    return b;
  }
}
