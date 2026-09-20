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

import {
  AbilityAware,
  AbilityPluginBinding,
  BinaryMessenger,
  EventChannel,
  FlutterPlugin,
  FlutterPluginBinding,
  Log,
  MethodCall,
  MethodChannel,
  MethodCallHandler,
  MethodResult,
  TextureRegistry
} from '@ohos/flutter_ohos';
import { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import AudioSwitchManager from './audio/AudioSwitchManager';
import MethodCallHandlerImpl from './MethodCallHandlerImpl';
import { VideoRenderFactory } from './components/VideoRenderFactory';
import { common } from '@kit.AbilityKit';
import LifeCycleObserver from './LifeCycleObserver';
import { PermissionsManager } from './utils/PermissionsManager';
import { isNotEmpty } from './utils/Utils';
import { DataMap, MethodChannelValue } from './utils/ObjectType';

const TAG: string = 'FlutterWebRTCPlugin';
const CHANNEL_NAME: string = 'flutter.webrtc.ohos/RTCVideoRender';

export class FlutterWebRTCPlugin implements FlutterPlugin, AbilityAware, StreamHandler, MethodCallHandler {
  private context: common.Context | null = null;
  private methodChannel: MethodChannel | null = null;
  private methodCallHandler: MethodCallHandlerImpl | null = null;
  private observer: LifeCycleObserver = new LifeCycleObserver();
  private eventChannel: EventChannel | null = null;
  private eventSink: EventSink | null = null;
  private callbackId?: number;

  constructor() {
  }

  /**
   * 引擎附加时：缓存上下文、注册视频渲染 PlatformView 工厂并启动
   * MethodChannel/EventChannel 监听。
   * @param binding Flutter 插件绑定
   */
  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.context = binding.getApplicationContext();
    binding.getPlatformViewRegistry()
      .registerViewFactory(CHANNEL_NAME, new VideoRenderFactory(binding.getBinaryMessenger()));
    this.startListening(this.context, binding.getBinaryMessenger(), binding.getTextureRegistry());
  }

  /**
   * 引擎分离时：停止监听并释放插件持有的全部资源。
   * @param binding Flutter 插件绑定
   */
  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    this.stopListening().catch((error: Error): void => {
      Log.e(TAG, `Failed to release plugin resources: ${error.message}`);
    });
  }

  /**
   * Ability 附加时：注入 Ability、注册生命周期监听并初始化权限管理器。
   * @param binding Ability 插件绑定
   */
  onAttachedToAbility(binding: AbilityPluginBinding): void {
    this.methodCallHandler?.setAbility(binding.getAbility());
    this.callbackId = this.context?.getApplicationContext().on('abilityLifecycle', this.observer);
    PermissionsManager.getInstance().init(binding.getAbility().context);
  }

  /**
   * 配置变更期间 Ability 分离回调：清除 Ability 引用并取消生命周期监听，
   * 避免回调通过已置空的 ability 异常。
   */
  onDetachedFromAbilityForConfigChanges(): void {
    this.methodCallHandler?.setAbility(null);
    this.detachAbilityResources();
  }

  /**
   * Ability 分离回调：清除 Ability 引用并取消 abilityLifecycle 监听，
   * 释放与 Ability 绑定的资源。
   */
  onDetachedFromAbility(): void {
    this.methodCallHandler?.setAbility(null);
    this.detachAbilityResources();
  }

  /**
   * 取消 Ability 生命周期订阅并清除权限管理器持有的 Ability Context。
   * 该方法幂等，可安全地被配置变更、Ability 分离和 Engine 分离路径重复调用。
   */
  private detachAbilityResources(): void {
    if (isNotEmpty(this.callbackId)) {
      this.context?.getApplicationContext().off('abilityLifecycle', this.callbackId);
      this.callbackId = undefined;
    }
    PermissionsManager.getInstance().clearContext();
  }

  /**
   * 返回插件唯一标识类名，供 Flutter 框架区分插件实例。
   * @returns 插件 TAG 常量字符串
   */
  getUniqueClassName(): string {
    return TAG;
  }

  private startListening(context: common.Context, messenger: BinaryMessenger, textureRegistry: TextureRegistry): void {
    AudioSwitchManager.getInstance().setContext(context);
    this.methodCallHandler = new MethodCallHandlerImpl(context, messenger, textureRegistry);
    this.methodChannel = new MethodChannel(messenger, 'FlutterWebRTC.Method');
    // 由插件本身代理 MethodCall，保证 handler 尚未就绪或已经释放时也始终回复 Flutter。
    this.methodChannel.setMethodCallHandler(this);
    this.eventChannel = new EventChannel(messenger, 'FlutterWebRTC.Event');
    this.eventChannel.setStreamHandler(this);
    this.observer.setMethodCallHandler(this.methodCallHandler);
  }

  /**
   * 停止监听并释放插件持有的全部资源（渲染器/流/轨道/PeerConnection/工厂/相机），
   * 同时清理静态单例，确保引擎重新附加时不携带过期状态。
   */
  private async stopListening(): Promise<void> {
    this.detachAbilityResources();
    // 1. 释放 MethodCallHandler 持有的全部资源
    await this.methodCallHandler?.dispose();
    this.methodCallHandler = null;
    // 2. 取消 MethodChannel / EventChannel 处理器并置空引用，缩短 GC 回收周期
    this.methodChannel?.setMethodCallHandler(null);
    this.methodChannel = null;
    this.eventChannel?.setStreamHandler(null);
    this.eventChannel = null;
    this.eventSink = null;
    this.observer.setMethodCallHandler(null);
    // 3. 完整释放 AudioSwitchManager 单例（事件订阅 off、release、置空）
    AudioSwitchManager.destroy();
    // 4. 销毁 PermissionsManager 单例（清理 context 引用并置空静态实例），
    // 避免插件卸载后单例持续驻留
    PermissionsManager.getInstance().destroy();
    // 5. 置空 context 引用，避免 Ability 分离后持有已销毁的 ApplicationContext
    this.context = null;
  }

  /**
   * MethodChannel 调用代理。无可用业务处理器时显式返回错误，避免 Dart Future 永久悬挂。
   * @param call Flutter 方法调用
   * @param result 必须且仅能完成一次的调用结果
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    let handler: MethodCallHandlerImpl | null = this.methodCallHandler;
    if (!handler) {
      Log.w(TAG, `MethodCall handler is not ready: ${call.method}`);
      result.error('handler_not_ready', 'FlutterWebRTC method handler is not ready', null);
      return;
    }
    handler.onMethodCall(call, result);
  }

  /**
   * EventChannel 注册回调：缓存 EventSink 以便后续向 Flutter 推送事件。
   * @param args 事件通道参数
   * @param events 事件下沉句柄
   */
  onListen(args: MethodChannelValue, events: EventSink): void {
    this.eventSink = events;
  }

  /**
   * EventChannel 注销回调：清除 EventSink 引用以停止事件推送。
   * @param args 事件通道参数
   */
  onCancel(args: MethodChannelValue): void {
    this.eventSink = null;
  }

  /**
   * 向 Flutter 层推送一个事件。事件统一为 MethodChannel 数据 Map，故用 DataMap 标注。
   * @param event 事件数据 Map
   */
  sendEvent(event: DataMap): void {
    this.eventSink?.success(event);
  }
}
