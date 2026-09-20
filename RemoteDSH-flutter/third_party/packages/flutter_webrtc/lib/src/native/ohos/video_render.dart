import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef OnViewCreated = Function(OhosRTCVideoRenderController);

///自定义OhosView
class OhosRTCVideoRender extends StatefulWidget {

  const OhosRTCVideoRender(this.onViewCreated, {Key? key}) : super(key: key);
  final OnViewCreated onViewCreated;

  @override
  State<OhosRTCVideoRender> createState() => _OhosRTCVideoRender();
}

class _OhosRTCVideoRender extends State<OhosRTCVideoRender> {
  late MethodChannel _channel;

  @override
  Widget build(BuildContext context) {
    return _getPlatformFaceView();
  }

  Widget _getPlatformFaceView() {
    return OhosView(
      viewType: 'flutter.webrtc.ohos/RTCVideoRender',
      onPlatformViewCreated: _onOhosRTCVideoRenderCreated,
      creationParams: const <String, dynamic>{'initParams': 'hello world'},
      creationParamsCodec: const StandardMessageCodec(),
    );
  }

  void _onOhosRTCVideoRenderCreated(int id) {
    _channel = MethodChannel('flutter.webrtc.ohos/RTCVideoRender$id');
    final controller = OhosRTCVideoRenderController._(
      _channel,
    );
    widget.onViewCreated(controller);
  }
}

class OhosRTCVideoRenderController {

  OhosRTCVideoRenderController._(
    this._channel,
  ) {
    _channel.setMethodCallHandler(
      (call) async {
        print('OhosRTCVideoRender method : ${call.method}');
        switch (call.method) {
          case 'putSurfaceId':
            // 从native端获取数据
            final result = call.arguments;
            _controller.sink.add(result);
            break;
        }
      },
    );
  }
  final MethodChannel _channel;
  final StreamController<dynamic> _controller = StreamController<dynamic>();

  Stream<dynamic> get customDataStream => _controller.stream;

  // 发送数据给native
  Future<void> sendMessageToOhosView(String message) async {
    await _channel.invokeMethod(
      'getMessageFromFlutterView',
      message,
    );
  }
}
