// 帧编解码（契约 §3.1–§3.3）—— 自 remotedsh-contract/js/frames.mjs 逐字移植
// 11B 大端帧头：ver u8 / type u8 / flags u8 / stream_id u32 / len u32；len ≤ 16373（总帧 ≤ 16384）
import 'dart:convert';
import 'dart:typed_data';

const int frameHeaderSize = 11;
const int maxPayload = 16373;
const int maxFrameSize = 16384;
const int frameVer = 1;

class FrameType {
  static const int open = 0x01;
  static const int data = 0x02;
  static const int fin = 0x03;
  static const int rst = 0x04;
  static const int window = 0x05;
  static const int ping = 0x06;
  static const int pong = 0x07;

  static String name(int t) => const {
        open: 'OPEN', data: 'DATA', fin: 'FIN', rst: 'RST',
        window: 'WINDOW', ping: 'PING', pong: 'PONG',
      }[t] ?? 'UNKNOWN($t)';
}

class FrameError implements Exception {
  final String code; // 'BAD_VER' | 'LEN_OVERFLOW' | 'HEADER_INCOMPLETE'
  final String message;
  FrameError(this.code, this.message);
  @override
  String toString() => 'FrameError($code): $message';
}

class Frame {
  final int ver;
  final int type;
  final int flags;
  final int streamId;
  final Uint8List payload;
  Frame(this.ver, this.type, this.flags, this.streamId, this.payload);
}

/// 编码一帧。flags 由本库恒置 0（契约 §3.1：发送方 MUST 置 0）。
/// len > 16373 → 抛 FrameError('LEN_OVERFLOW')（发送侧防线；接收侧超限对流 RST）。
/// PING/PONG 调用方 MUST 传 streamId=0。
Uint8List encodeFrame(int type, int streamId, [List<int>? payload]) {
  final Uint8List buf;
  if (payload == null) {
    buf = Uint8List(0);
  } else if (payload is Uint8List) {
    buf = payload;
  } else {
    buf = Uint8List.fromList(payload);
  }
  if (buf.length > maxPayload) {
    throw FrameError('LEN_OVERFLOW', 'len=${buf.length} > $maxPayload');
  }
  final out = Uint8List(frameHeaderSize + buf.length);
  final dv = ByteData.sublistView(out);
  dv.setUint8(0, frameVer);
  dv.setUint8(1, type);
  dv.setUint8(2, 0); // flags 恒 0
  dv.setUint32(3, streamId, Endian.big);
  dv.setUint32(7, buf.length, Endian.big);
  out.setAll(frameHeaderSize, buf);
  return out;
}

/// 帧头不完整 → HEADER_INCOMPLETE（调用方应继续缓冲，等更多字节）
Frame decodeFrame(Uint8List bytes) {
  if (bytes.length < frameHeaderSize) {
    throw FrameError('HEADER_INCOMPLETE', 'only ${bytes.length}B');
  }
  final dv = ByteData.sublistView(bytes);
  final ver = dv.getUint8(0);
  if (ver != frameVer) throw FrameError('BAD_VER', 'ver=$ver'); // §3.1 非 1 → 立即断开
  final type = dv.getUint8(1);
  final flags = dv.getUint8(2); // 接收方 MUST 忽略非 0，不得据此拒帧
  final streamId = dv.getUint32(3, Endian.big);
  final len = dv.getUint32(7, Endian.big);
  if (len > maxPayload) throw FrameError('LEN_OVERFLOW', 'len=$len'); // §3.1 → 对流 RST
  if (bytes.length < frameHeaderSize + len) {
    throw FrameError('HEADER_INCOMPLETE', 'have ${bytes.length}, need ${frameHeaderSize + len}');
  }
  final payload = Uint8List.sublistView(bytes, frameHeaderSize, frameHeaderSize + len);
  return Frame(ver, type, flags, streamId, payload);
}

/// 逐字节流式拆帧器：跨 DataChannel 消息天然按消息分帧，但本拆帧器也容忍字节流
class FrameSplitter {
  Uint8List _buf = Uint8List(0);

  List<Frame> push(List<int> bytes) {
    final merged = Uint8List(_buf.length + bytes.length);
    merged.setAll(0, _buf);
    merged.setAll(_buf.length, bytes);
    _buf = merged;
    final out = <Frame>[];
    while (true) {
      if (_buf.length < frameHeaderSize) break;
      final dv = ByteData.sublistView(_buf);
      final len = dv.getUint32(7, Endian.big);
      if (_buf.length < frameHeaderSize + len) break;
      out.add(decodeFrame(
          Uint8List.sublistView(_buf, 0, frameHeaderSize + len)));
      _buf = Uint8List.sublistView(_buf, frameHeaderSize + len);
    }
    return out;
  }
}

/// 帧内 payload → utf8 字符串（OPEN authority 等文本负载用）
String payloadAsText(Uint8List p) => utf8.decode(p);
