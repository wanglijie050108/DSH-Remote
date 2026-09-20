import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:webrtc_interface/webrtc_interface.dart';
import 'ohos/video_render.dart';
import 'rtc_video_renderer_impl.dart';

class RTCVideoView extends StatelessWidget {
  RTCVideoView(
    this._renderer, {
    Key? key,
    this.onRendererUpdated = null,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.mirror = false,
    this.filterQuality = FilterQuality.low,
    this.placeholderBuilder,
  }) : super(key: key);

  final RTCVideoRenderer _renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final FilterQuality filterQuality;
  final WidgetBuilder? placeholderBuilder;
  OhosRTCVideoRenderController? _controller;
  final Function(String)? onRendererUpdated; // 外部传入的回调

  RTCVideoRenderer get videoRenderer => _renderer;

  void updateRenderer(String id) {
    _renderer.surfaceId = id;
    onRendererUpdated?.call(id);
  }

  void _onOhosRTCVideoRenderCreated(OhosRTCVideoRenderController controller) {
    _controller = controller;
    _controller?.customDataStream.listen((data) {
      //接收到来自OHOS端的数据
      updateRenderer(data['surfaceId']!);
    });
  }

  Widget _buildOhosRTCVideoRender() {
    return Center(
      child: Container(
        color: Colors.blueAccent.withAlpha(60),
        child: OhosRTCVideoRender(_onOhosRTCVideoRenderCreated),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            _buildVideoView(context, constraints));
  }

  Widget _buildVideoView(BuildContext context, BoxConstraints constraints) {
    return Center(
      child: Container(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: FittedBox(
          clipBehavior: Clip.hardEdge,
          fit: objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
              ? BoxFit.contain
              : BoxFit.cover,
          child: Center(
            child: ValueListenableBuilder<RTCVideoValue>(
              valueListenable: videoRenderer,
              builder:
                  (BuildContext context, RTCVideoValue value, Widget? child) {
                return SizedBox(
                  width: constraints.maxHeight * value.aspectRatio,
                  height: constraints.maxHeight,
                  child: child,
                );
              },
              child: Transform(
                transform: Matrix4.identity()..rotateY(mirror ? -pi : 0.0),
                alignment: FractionalOffset.center,
                child: WebRTC.platformIsOhos
                    ? _buildOhosRTCVideoRender()
                    : (videoRenderer.renderVideo
                        ? Texture(
                            textureId: videoRenderer.textureId!,
                            filterQuality: filterQuality,
                          )
                        : placeholderBuilder?.call(context) ?? Container()),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
