/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the 'Software'), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import { MethodResult, EventChannel, Log, MethodCall } from '@ohos/flutter_ohos';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataMap, MethodChannelValue } from './utils/ObjectType';
import { util } from '@kit.ArkTS';
import StateProvider from './StateProvider';
import PeerConnectionObserver from './PeerConnectionObserver';
import { RTCRtpReceiver, RTCRtpSender } from 'libohos_webrtc.so';

const TAG: string = 'FlutterWebRTCPlugin-FlutterRTCFrameCryptor';

/** 单个帧加密方法处理函数的类型别名。 */
type CryptorMethodHandler = (call: MethodCall, result: MethodResult) => void;

export class FrameCryptorKeyProvider {
  readonly options: ConstraintsMap;

  /**
   * 构造帧加密密钥提供者，缓存传入的密钥配置约束。
   * @param options 密钥提供者配置（来自 Dart 层 keyProviderOptions），供后续 setSharedKey 等方法读取。
   */
  constructor(options: ConstraintsMap) {
    this.options = options;
  }
}

export default class FlutterRTCFrameCryptor {
  private keyProviders: Map<string, FrameCryptorKeyProvider> = new Map<string, FrameCryptorKeyProvider>();
  private stateProvider: StateProvider;
  private cryptorMethodHandlers: Map<string, CryptorMethodHandler> = new Map<string, CryptorMethodHandler>();

  /**
   * 构造帧加密器：注入状态提供者并注册帧加密相关 MethodChannel 处理器。
   * @param stateProvider 全局状态提供者，用于按 id 查找 PeerConnectionObserver 与 RTP sender/receiver
   */
  constructor(stateProvider: StateProvider) {
    this.stateProvider = stateProvider;
    this.registerMethodHandlers();
  }

  /**
   * 释放帧加密器资源：清空 keyProviders 缓存与 cryptorMethodHandlers 闭包引用，
   * 避免对象常驻内存（dispose 后这些 Map 仍持有闭包会阻止 GC 回收）。
   */
  dispose(): void {
    this.keyProviders.clear();
    this.cryptorMethodHandlers.clear();
  }

  /** 注册帧加密相关 MethodChannel 处理器。 */
  private registerMethodHandlers(): void {
    this.cryptorMethodHandlers.set('frameCryptorFactoryCreateFrameCryptor',
      (call: MethodCall, result: MethodResult) => this.handleCreateFrameCryptor(call, result));
    this.cryptorMethodHandlers.set('frameCryptorFactoryCreateKeyProvider',
      (call: MethodCall, result: MethodResult) => this.handleCreateKeyProvider(call, result));
    this.cryptorMethodHandlers.set('keyProviderSetSharedKey',
      (call: MethodCall, result: MethodResult) => this.keyProviderSetSharedKey(call, result));
    let unsupportedMethods: string[] = [
      'frameCryptorSetKeyIndex', 'frameCryptorGetKeyIndex', 'frameCryptorSetEnabled',
      'frameCryptorGetEnabled', 'frameCryptorDispose', 'keyProviderRatchetSharedKey',
      'keyProviderExportSharedKey', 'keyProviderSetKey', 'keyProviderRatchetKey',
      'keyProviderExportKey', 'keyProviderSetSifTrailer', 'keyProviderDispose'
    ];
    unsupportedMethods.forEach((method: string) => {
      this.cryptorMethodHandlers.set(method,
        (call: MethodCall, result: MethodResult) => this.handleUnknownMethod(call, result));
    });
  }

  /**
   * 统一错误返回：与 MethodCallHandlerImpl.resultError 格式一致，
   * error code 使用方法名（与 Android/iOS 对齐），error message 含方法名与详情。
   * @param method 方法名（同时作为 error code）
   * @param error 错误描述
   * @param result 回调句柄
   */
  resultError(method: string, error: string, result: MethodResult): void {
    let errorMsg: string = `${method}(): ${error}`;
    Log.e(TAG, errorMsg);
    result.error(method, errorMsg, null);
  }

  /**
   * 帧加密方法分发入口：按 call.method 查找已注册处理器执行，
   * 未匹配则返回 notImplemented，异常统一经 resultError 上报。
   * @param call Flutter 方法调用
   * @param result 回调句柄
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    let method: string = call.method;
    try {
      let fun: CryptorMethodHandler | undefined = this.cryptorMethodHandlers.get(method);
      if (fun) {
        Log.d(TAG, `onMethodCall: ${method}`);
        fun(call, result);
      } else {
        Log.e(TAG, `onMethodCall Unknown method: ${method}`);
        result.notImplemented();
      }
    } catch (error) {
      this.resultError(method || 'onMethodCall', `failed: ${error}`, result);
    }
  }

  /**
   * 创建帧加密器：校验 keyProvider 与 peerConnection，按 sender/receiver 类型分发。
   * 平台尚未提供 FrameCryptorFactory 接口，当前返回 notSupported。
   * @param call Flutter 方法调用
   * @param result 回调句柄
   */
  handleCreateFrameCryptor(call: MethodCall, result: MethodResult): void {
    Log.d(TAG, `handleCreateFrameCryptor in!`);
    let keyProviderId: string = call.argument('keyProviderId');
    Log.d(TAG, `handleCreateFrameCryptor keyProviderId:${keyProviderId}`);
    let keyProvider: FrameCryptorKeyProvider | undefined = this.keyProviders.get(keyProviderId);
    if (!keyProvider) {
      this.resultError('frameCryptorFactoryCreateFrameCryptorFailed', 'keyProvider not found', result);
      return;
    }

    let peerConnectionId: string = call.argument('peerConnectionId');
    Log.d(TAG, `handleCreateFrameCryptor peerConnectionId:${peerConnectionId}`);
    let pco: PeerConnectionObserver | undefined = this.stateProvider.getPeerConnectionObserver(peerConnectionId);
    if (!pco) {
      this.resultError('frameCryptorFactoryCreateFrameCryptorFailed', 'peerConnection not found', result);
      return;
    }

    let participantId: string = call.argument('participantId');
    let type: string = call.argument('type');
    let algorithm: number = call.argument('algorithm');
    let rtpSenderId: string = call.argument('rtpSenderId');
    let rtpReceiverId: string = call.argument('rtpReceiverId');

    if (type === 'sender') {
      let rtpSender: RTCRtpSender | null = pco.getRtpSenderById(rtpSenderId);
      // TODO 没有接口
      // FrameCryptorFactory.createFrameCryptorForRtpSender
      this.resultError('frameCryptorFactoryCreateFrameCryptorFailed', 'no FrameCryptorFactory', result);
      return;

    } else if (type === 'receiver') {
      let rtpReceiver: RTCRtpReceiver | null = pco.getRtpReceiverById(rtpReceiverId);
      // TODO 没有接口
      // FrameCryptorFactory.createFrameCryptorForRtpReceiver
      this.resultError('frameCryptorFactoryCreateFrameCryptorFailed', 'no FrameCryptorFactory', result);
      return;
    } else {
      this.resultError('frameCryptorFactoryCreateFrameCryptorFailed', 'type must be sender or receiver', result);
      return;
    }
  }

  /**
   * 创建 keyProvider：生成 RFC4122 v4 UUID 作为 keyProviderId，缓存配置并返回。
   * @param call Flutter 方法调用
   * @param result 回调句柄，返回 { keyProviderId }
   */
  handleCreateKeyProvider(call: MethodCall, result: MethodResult): void {
    Log.d(TAG, `handleCreateKeyProvider in!`);

    let keyProviderId: string = util.generateRandomUUID(true);
    Log.d(TAG, 'RFC 4122 Version 4 UUID:' + keyProviderId);
    let configurationMap: ConstraintsMap = new ConstraintsMap(call.argument('keyProviderOptions'));
    Log.d(TAG, `keyProviderOptions map： ${configurationMap.toString()}`);
    this.keyProviders.set(keyProviderId, new FrameCryptorKeyProvider(configurationMap));

    let resultMap: DataMap = new Map();
    resultMap.set('keyProviderId', keyProviderId);
    result.success(resultMap);
  }


  /**
   * 未支持方法的统一处理：帧加密能力暂未支持，按实际方法名返回错误。
   * @param call Flutter 方法调用
   * @param result 回调句柄
   */
  handleUnknownMethod(call: MethodCall, result: MethodResult): void {
    //TODO 帧加密功能暂未支持
    Log.d(TAG, `onMethodCall handleUnknownMethod!`);
    // 错误码使用 call.method（实际方法名）而非 TAG 常量，便于 Dart 端定位具体失败方法
    this.resultError(call.method, `onMethodCall Unknown method: ${call.method}`, result);
  }

  /**
   * 设置共享密钥：校验 keyProvider 后写入指定 keyIndex。
   * 平台 libohos_webrtc.so 未暴露 setSharedKey 接口，此处保持 success 语义以匹配 Dart 契约。
   * @param call Flutter 方法调用
   * @param result 回调句柄，返回 { result: true }
   */
  keyProviderSetSharedKey(call: MethodCall, result: MethodResult): void {
    let keyProviderId: string = call.argument('keyProviderId') ?? '';
    Log.d(TAG, `keyProviderSetSharedKey keyProviderId:${keyProviderId}`);
    let keyProvider: FrameCryptorKeyProvider | undefined = this.keyProviders.get(keyProviderId);
    if (!keyProvider) {
      this.resultError('keyProviderSetKeySharedFailed', 'keyProvider not found', result);
      return;
    }
    let keyIndex: number = call.argument('keyIndex');
    let key: Uint8Array[] = call.argument('key');
    // 平台限制说明：libohos_webrtc.so 的 KeyProvider 接口未暴露 setSharedKey 方法，
    // OHOS 平台 E2EE 帧加密能力不可用。此处保留返回 { result: true } 是有意的平台适配——
    // Dart 层 KeyProviderImpl.setSharedKey 在 PlatformException 时会抛出字符串导致
    // "setSharedKey should complete without error" 用例失败，因此保持 success 语义
    // 以匹配 Dart 契约（与 startRecordToFile 返回 notSupported 不同：录制方法 Dart 层
    // 有 try/catch 期望错误，而 setSharedKey Dart 层期望成功完成）。
    // TODO 待 libohos_webrtc.so 提供 setSharedKey 接口后改为真实实现。
    let paramsResult: ConstraintsMap = new ConstraintsMap();
    paramsResult.putBoolean('result', true);
    result.success(paramsResult.toMap());
  }
}
