/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

// 1. 系统/Kit 导入
import {
  MethodCall,
  MethodCallHandler,
  MethodResult,
  PlatformView,
  MethodChannel,
  BinaryMessenger,
  StandardMethodCodec,
  Log,
} from '@ohos/flutter_ohos';
import { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import { common } from '@kit.AbilityKit';
// 2. 第三方库导入
// 3. 本地模块导入
import { VideoRender } from './VideoRender';

const TAG: string = 'FlutterWebRTCPlugin-[VideoRenderHandler]';
const CHANNEL_NAME: string = 'flutter.webrtc.ohos/RTCVideoRender';

/**
 * 视频缩放模式枚举。
 * FILL：拉伸填充，ASPECT_FILL：等比裁剪，ASPECT_FIT：等比适配。
 */
export enum ScalingMode { FILL, ASPECT_FILL, ASPECT_FIT }

/**
 * 视频渲染处理组件，负责视频渲染视图的生命周期管理
 * 及与 Dart 层的 SurfaceId 传递。
 */
@Observed
export class VideoRenderHandler extends PlatformView implements MethodCallHandler {
  private methodChannel: MethodChannel | null;
  private disposed: boolean = false;
  private messenger: BinaryMessenger;
  private viewId: number;

  /**
   * 构造函数，初始化渲染通道并注册方法调用处理器。
   * @param context 应用上下文
   * @param message 二进制信使，用于跨平台通信
   * @param viewId 平台视图唯一标识
   * @param args 创建参数
   */
  constructor(context: common.Context, message: BinaryMessenger, viewId: number, args: Object) {
    super();
    this.messenger = message;
    this.viewId = viewId;
    this.methodChannel =
      new MethodChannel(message, `${CHANNEL_NAME}${viewId}`, StandardMethodCodec.INSTANCE);
    this.methodChannel.setMethodCallHandler(this);
  }

  /**
   * 视频渲染通道方法分发入口。
   * 当前渲染控制通道由 Dart 侧主动调用 sendMessage 下发 surfaceId，
   * Native 侧暂无需要处理的方法（保留分发骨架便于后续扩展）。
   * @param call 方法调用
   * @param result 回调句柄
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    let method: string = call.method;
    Log.d(TAG, 'VideoRenderHandler method  :' + method);
    switch (method) {
      default:
        result.notImplemented();
        break;
    }
  }

  /**
   * 向 Dart 层下发当前渲染 SurfaceTexture 的 surfaceId，供其绑定到视频轨道。
   * @param surfaceId，由原生渲染层分配，用于 Dart 侧与原生视频渲染纹理的绑定
   */
  public sendMessage: (surfaceId: string) => void = (surfaceId: string): void => {
    Log.d(TAG, 'VideoRenderHandler sendMessage: ' + surfaceId);
    if (this.disposed) {
      // 屏幕旋转/配置变更会销毁并重建 SurfaceTexture。dispose() 在 onSurfaceDestroyed
      // 中被调用，但 XComponent 随后用同一 VideoRenderHandler 实例重建 SurfaceTexture 并
      // 触发 onLoad。此处用 invokeMethod 直接发送（绕过 methodChannel null 检查），
      // 确保 Dart 侧能收到新的 surfaceId 并重新绑定视频轨道。
      this.sendMessageDirect(surfaceId);
      return;
    }
    this.methodChannel?.invokeMethod('putSurfaceId', { surfaceId: surfaceId });
  };

  /**
   * 在 methodChannel 已释放（disposed）后仍尝试下发 surfaceId。
   * 利用构造时缓存的 channel name 和 messenger 构建临时 channel 发送。
   * @param surfaceId 新的 SurfaceTexture 标识符
   */
  private sendMessageDirect(surfaceId: string): void {
    try {
      let channel: MethodChannel = new MethodChannel(
        this.messenger, `${CHANNEL_NAME}${this.viewId}`,
        StandardMethodCodec.INSTANCE);
      channel.invokeMethod('putSurfaceId', { surfaceId: surfaceId });
      Log.d(TAG, 'sendMessageDirect sent surfaceId after dispose: ' + surfaceId);
    } catch (e) {
      Log.e(TAG, 'sendMessageDirect failed: ' + JSON.stringify(e));
    }
  }

  /**
   * 获取视频渲染视图的 WrappedBuilder，用于 PlatformView 框架创建原生组件。
   * @returns 渲染视图构建器
   */
  getView(): WrappedBuilder<[Params]> {
    return new WrappedBuilder(RenderBuilder);
  }

  /**
   * 释放资源，清除方法调用处理器，避免内存泄漏。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
  }
}

@Builder
function RenderBuilder(params: Params): void {
  VideoRender({ params: params });
}
