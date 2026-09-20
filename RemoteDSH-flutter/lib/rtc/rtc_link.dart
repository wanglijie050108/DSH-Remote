// RTC 链接层 —— flutter_webrtc（ohos 原生 libwebrtc）薄封装
// 手机 = answer 方：MUST NOT createDataChannel，两条通道（data/ctl）经 onDataChannel 识别（契约 §3）
// 非 trickle：setLocalDescription 后等 gathering complete 再取 SDP（20s 看门狗，对齐插件侧 rtc.js）
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;

/// 通道抽象：隔离 flutter_webrtc 类型，使隧道泵可独立测试
class RtcChannel {
  final webrtc.RTCDataChannel _ch;
  RtcChannel(this._ch);

  void Function(Uint8List bytes)? onMessage;

  int get bufferedAmount => _ch.bufferedAmount ?? 0;

  Future<void> send(Uint8List bytes) =>
      _ch.send(webrtc.RTCDataChannelMessage.fromBinary(bytes));
}

class RtcLink {
  final webrtc.RTCPeerConnection pc;
  void Function(String label, RtcChannel ch)? onChannel;
  void Function(String state)? onConnectionState;
  final List<RtcChannel> _channels = [];

  RtcLink(this.pc) {
    pc.onDataChannel = (ch) {
      final c = RtcChannel(ch);
      _wire(c);
      _channels.add(c);
      onChannel?.call(ch.label ?? '', c);
    };
    pc.onConnectionState = (s) => onConnectionState?.call(s.name);
  }

  void _wire(RtcChannel c) {
    c._ch.onMessage = (m) {
      if (m.isBinary) {
        c.onMessage?.call(m.binary);
      } else {
        c.onMessage?.call(Uint8List.fromList(m.text.codeUnits));
      }
    };
  }

  static Future<RtcLink> create(List<Map<String, dynamic>> iceServers) async {
    final config = <String, dynamic>{
      'iceServers': iceServers,
      'sdpSemantics': 'unified-plan',
    };
    final pc = await webrtc.createPeerConnection(config);
    return RtcLink(pc);
  }

  /// 手机侧：收 offer → pin 校验由上层负责 → 生成完整 answer（含候选）
  Future<String> createFullAnswer(String offerSdp) async {
    await pc.setRemoteDescription(
        webrtc.RTCSessionDescription(offerSdp, 'offer'));
    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    await _waitGatherComplete();
    final local = await pc.getLocalDescription();
    return local!.sdp ?? '';
  }

  Future<void> _waitGatherComplete() async {
    if (pc.iceGatheringState ==
        webrtc.RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return;
    }
    final done = Completer<void>();
    final prev = pc.onIceGatheringState;
    void check(webrtc.RTCIceGatheringState? s) {
      if (!done.isCompleted &&
          s == webrtc.RTCIceGatheringState.RTCIceGatheringStateComplete) {
        done.complete();
      }
    }

    pc.onIceGatheringState = (s) {
      prev?.call(s);
      check(s);
    };
    check(pc.iceGatheringState);
    try {
      await done.future.timeout(const Duration(milliseconds: 20000), onTimeout: () {
        // 看门狗：超时按当前已收集候选继续（对齐插件侧 GATHER_TIMEOUT_MS=20000）
      });
    } finally {
      pc.onIceGatheringState = prev;
    }
  }

  Future<void> setAnswer(String answerSdp) async {
    await pc.setRemoteDescription(
        webrtc.RTCSessionDescription(answerSdp, 'answer'));
  }

  Future<void> close() async {
    for (final c in _channels) {
      try {
        await c._ch.close();
      } catch (_) {}
    }
    _channels.clear();
    try {
      await pc.close();
    } catch (_) {}
  }
}
