import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:remotedsh_contract/contract/frames.dart';
import 'package:remotedsh_flutter/rtc/rtc_link.dart';
import 'package:remotedsh_flutter/service/harness.dart';
import 'package:remotedsh_flutter/service/signal_client.dart';
import 'package:remotedsh_flutter/service/tunnel.dart';

class _MemoryChannel implements TunnelChannel {
  @override
  void Function(Uint8List bytes)? onMessage;

  final List<Uint8List> sent = [];

  @override
  int get bufferedAmount => 0;

  @override
  Future<void> send(Uint8List bytes) async {
    sent.add(Uint8List.fromList(bytes));
  }

  void receive(Uint8List bytes) => onMessage?.call(bytes);
}

class _ScriptedRawSocket implements RawSocket {
  _ScriptedRawSocket(this.writeResults);

  final List<int> writeResults;
  final StreamController<RawSocketEvent> _events =
      StreamController<RawSocketEvent>();

  @override
  bool readEventsEnabled = true;

  @override
  bool writeEventsEnabled = false;

  @override
  int write(List<int> buffer, [int offset = 0, int? count]) {
    final requested = count ?? buffer.length - offset;
    return min(requested, writeResults.removeAt(0));
  }

  void emit(RawSocketEvent event) => _events.add(event);

  @override
  StreamSubscription<RawSocketEvent> listen(
    void Function(RawSocketEvent)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _events.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Uint8List? read([int? len]) => null;

  @override
  void shutdown(SocketDirection direction) {}

  @override
  Future<RawSocket> close() async {
    await _events.close();
    return this;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Future<void> _waitUntil(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue);
}

void main() {
  test('signal reconnect delay grows from 500ms and caps at 30s', () {
    const bases = [500, 1000, 2000, 4000, 8000, 16000, 24000];
    for (var attempt = 0; attempt < bases.length + 3; attempt++) {
      final delay =
          signalReconnectDelay(attempt, random: Random(attempt)).inMilliseconds;
      final base = bases[min(attempt, bases.length - 1)];
      expect(delay, greaterThanOrEqualTo(base));
      expect(delay, lessThanOrEqualTo(min(30000, base + base ~/ 4)));
    }
  });

  test('pair token is fresh and single-use', () {
    final token = OneShotPairToken()..replace('fresh');
    expect(token.take(), 'fresh');
    expect(token.take(), isNull);
    token.replace('stale');
    token.replace(null);
    expect(token.take(), isNull);
  });

  test('WINDOW credits only bytes accepted by RawSocket.write', () async {
    final socket = _ScriptedRawSocket([1000, 1000000]);
    final data = _MemoryChannel();
    final ctl = _MemoryChannel();
    final endpoint = TunnelEndpoint(mode: 'initiator', log: (_) {});
    addTearDown(endpoint.close);
    endpoint.bind(data, ctl);
    final streamId = endpoint.openStream(socket)!;
    final payload = Uint8List(16000);

    for (var i = 0; i < 5; i++) {
      data.receive(encodeFrame(FrameType.data, streamId, payload));
    }
    expect(
      ctl.sent.where((bytes) => decodeFrame(bytes).type == FrameType.window),
      isEmpty,
    );

    socket.emit(RawSocketEvent.readClosed);
    socket.emit(RawSocketEvent.write);
    await _waitUntil(() => ctl.sent.any(
          (bytes) => decodeFrame(bytes).type == FrameType.window,
        ));
    final window = decodeFrame(
      ctl.sent.firstWhere(
        (bytes) => decodeFrame(bytes).type == FrameType.window,
      ),
    );
    expect(ByteData.sublistView(window.payload).getUint32(0, Endian.big), 80000);
  });

  test('remote FIN preserves reverse traffic until local FIN', () async {
    final server = await RawServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = Completer<RawSocket>();
    server.listen(accepted.complete);
    final local = await RawSocket.connect(
      InternetAddress.loopbackIPv4,
      server.port,
    );
    final peer = await accepted.future;
    final data = _MemoryChannel();
    final ctl = _MemoryChannel();
    final endpoint = TunnelEndpoint(mode: 'initiator', log: (_) {});
    addTearDown(() {
      endpoint.close();
      peer.close();
      server.close();
    });
    endpoint.bind(data, ctl);
    final streamId = endpoint.openStream(local)!;

    final peerReadClosed = Completer<void>();
    peer.listen((event) {
      if (event == RawSocketEvent.readClosed && !peerReadClosed.isCompleted) {
        peerReadClosed.complete();
      }
    });
    data.receive(encodeFrame(FrameType.fin, streamId));
    await peerReadClosed.future.timeout(const Duration(seconds: 1));

    peer.write(Uint8List.fromList('response after request FIN'.codeUnits));
    await _waitUntil(() => data.sent.any((bytes) {
          final frame = decodeFrame(bytes);
          return frame.type == FrameType.data &&
              frame.streamId == streamId &&
              String.fromCharCodes(frame.payload) ==
                  'response after request FIN';
        }));
    expect(endpoint.streams.containsKey(streamId), isTrue);

    peer.shutdown(SocketDirection.send);
    await _waitUntil(() => !endpoint.streams.containsKey(streamId));
    expect(
      data.sent.any((bytes) {
        final frame = decodeFrame(bytes);
        return frame.type == FrameType.fin && frame.streamId == streamId;
      }),
      isTrue,
    );
  });
}
