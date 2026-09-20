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
  BinaryMessenger,
  Log,
  MethodCall,
  MethodCallHandler,
  MethodResult,
  TextureRegistry,
  EventChannel
} from '@ohos/flutter_ohos';
import { common, UIAbility } from '@kit.AbilityKit';
import { ArrayList, HashMap, JSON, PlainArray } from '@kit.ArkTS';
import util from '@ohos.util';
import { camera } from '@kit.CameraKit';
import { audio } from '@kit.AudioKit';
// 2. 第三方库导入
import {
  MediaStreamTrack,
  RTCPeerConnection,
  PeerConnectionFactory,
  AudioDeviceModule,
  AudioSource,
  MediaStream,
  Event,
  RTCConfiguration,
  MediaTrackConstraints,
} from 'libohos_webrtc.so';
// 3. 本地模块导入
import StateProvider from './StateProvider';
import PeerConnectionObserver from './PeerConnectionObserver';
import FlutterRTCVideoRenderer from './FlutterRTCVideoRenderer';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataMap, ObjectType } from './utils/ObjectType';
import GetUserMediaImpl from './GetUserMediaImpl';
import { MethodHandler } from './MethodHandlers';
import AudioSwitchManager from './audio/AudioSwitchManager';
import FlutterRTCFrameCryptor from './FlutterRTCFrameCryptor';
import {
  getOptionsAudioConfiguration,
  getOptionsForceSWCodec,
  getOptionsForceSWCodecList,
  getOptionsNetworkIgnoreMask
} from './utils/OptionsUtils';
import {
  getConfigurationMap,
  getConstraintsMap,
  getOptionsMap,
  getPeerConnectionId,
  getStreamId,
  getTrackId
} from './utils/CallUtils';
import AudioMethodHandlers from './AudioMethodHandlers';
import DeviceEnumerationHandlers from './DeviceEnumerationHandlers';
import { TrackControlHandlers } from './TrackControlHandlers';
import { SignalingHandlers } from './SignalingHandlers';
import { RtpTransceiverHandlers } from './RtpTransceiverHandlers';
import { MediaStreamHandlers } from './MediaStreamHandlers';
import { MediaCaptureHandlers } from './MediaCaptureHandlers';
import { VideoRendererHandlers } from './VideoRendererHandlers';
import { DataChannelConnectionHandlers } from './DataChannelConnectionHandlers';
import { CapabilityMiscHandlers } from './CapabilityMiscHandlers';
import { PeerConnectionConfigHandlers } from './PeerConnectionConfigHandlers';
import { createMethodCallDispatcher } from './MethodCallDispatcher';
import { MediaStateLookup } from './MediaStateLookup';
import { disposePluginResources } from './PluginResourceDisposer';

const TAG: string = 'FlutterWebRTCPlugin-MethodCallHandlerImpl';

export default class MethodCallHandlerImpl implements MethodCallHandler, StateProvider {
  private ability: UIAbility | null = null;
  private messenger: BinaryMessenger;
  private context: common.Context;
  private textures: TextureRegistry;
  private peerConnectionObservers: HashMap<string, PeerConnectionObserver> = new HashMap();
  private peerConnectionFactory: PeerConnectionFactory | null = null;
  private localStreams: HashMap<string, MediaStream> = new HashMap();
  private localTracks: HashMap<string, MediaStreamTrack> = new HashMap();
  private renders: PlainArray<FlutterRTCVideoRenderer> = new PlainArray();
  private stateProvider: StateProvider;
  private getUserMediaImpl: GetUserMediaImpl | null = null;
  private frameCryptor: FlutterRTCFrameCryptor;
  private textureId: number = 0;
  private audioHandlers: AudioMethodHandlers | null = null;
  private deviceHandlers: DeviceEnumerationHandlers | null = null;
  private trackControlHandlers: TrackControlHandlers | null = null;
  private signalingHandlers: SignalingHandlers | null = null;
  private rtpTransceiverHandlers: RtpTransceiverHandlers | null = null;
  private mediaStreamHandlers: MediaStreamHandlers | null = null;
  private mediaCaptureHandlers: MediaCaptureHandlers | null = null;
  private videoRendererHandlers: VideoRendererHandlers | null = null;
  private dataChannelConnectionHandlers: DataChannelConnectionHandlers | null = null;
  private capabilityMiscHandlers: CapabilityMiscHandlers | null = null;
  private configHandlers: PeerConnectionConfigHandlers | null = null;
  private methodHandlers: Map<string, MethodHandler> = new Map<string, MethodHandler>();
  private mediaStateLookup: MediaStateLookup;
  // dispose 标志：dispose 后拦截任何后续 onMethodCall，避免分发到已销毁的 handler
  private disposed: boolean = false;

  /**
   * 构造方法调用处理器：注入上下文、信使、纹理注册表，创建所有子 Handler 并注册方法路由表。
   */
  constructor(context: common.Context, messenger: BinaryMessenger, textureRegistry: TextureRegistry) {
    this.context = context;
    this.textures = textureRegistry;
    this.messenger = messenger;
    this.stateProvider = this;
    this.mediaStateLookup = new MediaStateLookup(
      this.localStreams,
      this.localTracks,
      this.peerConnectionObservers
    );
    this.frameCryptor = new FlutterRTCFrameCryptor(this);
    this.initHandlers();
    let audio: AudioMethodHandlers | null = this.audioHandlers;
    let capability: CapabilityMiscHandlers | null = this.capabilityMiscHandlers;
    let connection: DataChannelConnectionHandlers | null = this.dataChannelConnectionHandlers;
    let device: DeviceEnumerationHandlers | null = this.deviceHandlers;
    let capture: MediaCaptureHandlers | null = this.mediaCaptureHandlers;
    let mediaStream: MediaStreamHandlers | null = this.mediaStreamHandlers;
    let rtp: RtpTransceiverHandlers | null = this.rtpTransceiverHandlers;
    let signaling: SignalingHandlers | null = this.signalingHandlers;
    let track: TrackControlHandlers | null = this.trackControlHandlers;
    let videoRenderer: VideoRendererHandlers | null = this.videoRendererHandlers;
    if (!audio || !capability || !connection || !device || !capture || !mediaStream ||
      !rtp || !signaling || !track || !videoRenderer) {
      throw new Error('failed to initialize WebRTC method handlers');
    }
    this.methodHandlers = createMethodCallDispatcher({
      initialize: (call: MethodCall, result: MethodResult) => this.initialize(call, result),
      createPeerConnection: (call: MethodCall, result: MethodResult) => this.createPeerConnection(call, result),
      audio: audio,
      capability: capability,
      connection: connection,
      device: device,
      capture: capture,
      mediaStream: mediaStream,
      rtp: rtp,
      signaling: signaling,
      track: track,
      videoRenderer: videoRenderer
    });
  }

  /**
   * 初始化所有抽取出的 Handler 子类，注入 host 回调与共享映射。
   * 抽离自构造函数以控制方法长度，行为与原构造函数等价。
   */
  private initHandlers(): void {
    this.initAudioAndDeviceHandlers();
    this.initSignalingAndRtpHandlers();
    this.initMediaAndCapabilityHandlers();
  }

  /** 初始化音频、设备枚举、PC 配置、轨道控制类 Handler。 */
  private initAudioAndDeviceHandlers(): void {
    this.audioHandlers = new AudioMethodHandlers(
      (id: string, pcId?: string): MediaStreamTrack | null => this.getTrackForId(id, pcId),
      (id: string): AudioSource | null => this.getUserMediaImpl?.getAudioSourceForTrack(id) ?? null,
      (method: string, error: string, result?: MethodResult): void => this.resultError(method, error, result)
    );
    this.deviceHandlers = new DeviceEnumerationHandlers();
    this.configHandlers = new PeerConnectionConfigHandlers({
      messenger: this.messenger,
      stateProvider: this.stateProvider,
      peerConnectionObservers: this.peerConnectionObservers,
      getNextStreamUUID: (): string => this.getNextStreamUUID(),
      getPcf: (): PeerConnectionFactory | null => this.peerConnectionFactory,
      setPcf: (pcf: PeerConnectionFactory | null): void => { this.peerConnectionFactory = pcf; }
    });
    this.trackControlHandlers = new TrackControlHandlers(
      (): GetUserMediaImpl | null => this.getUserMediaImpl,
      (id: string, pcId?: string): MediaStreamTrack | null => this.getTrackForId(id, pcId),
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result)
    );
  }

  /** 初始化信令、RTP 收发器、媒体流类 Handler。 */
  private initSignalingAndRtpHandlers(): void {
    this.signalingHandlers = new SignalingHandlers(
      (call: MethodCall, result: MethodResult): RTCPeerConnection | null => this.getPeerConnection(call, result),
      (call: MethodCall, result: MethodResult): PeerConnectionObserver | null => this.getPCO(call, result),
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result),
      (map: ConstraintsMap): RTCConfiguration => this.parseRTCConfiguration(map)
    );
    this.rtpTransceiverHandlers = new RtpTransceiverHandlers(
      (call: MethodCall, result: MethodResult): PeerConnectionObserver | null => this.getPCO(call, result),
      (call: MethodCall, result: MethodResult): MediaStreamTrack | null => this.getMediaStreamTrack(call, result),
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result),
      this.localStreams
    );
    this.mediaStreamHandlers = new MediaStreamHandlers({
      getMediaStream: (call: MethodCall, result: MethodResult, errorMsg?: string): MediaStream | undefined =>
        this.getMediaStream(call, result, errorMsg),
      getMediaStreamTrack: (call: MethodCall, result: MethodResult): MediaStreamTrack | null =>
        this.getMediaStreamTrack(call, result),
      getTrackForId: (id: string, pcId?: string): MediaStreamTrack | null => this.getTrackForId(id, pcId),
      getStreamForId: (id: string, pcId: string): MediaStream | null => this.getStreamForId(id, pcId),
      getPeerConnection: (call: MethodCall, result: MethodResult): RTCPeerConnection | null =>
        this.getPeerConnection(call, result),
      getPCO: (call: MethodCall, result: MethodResult): PeerConnectionObserver | null =>
        this.getPCO(call, result),
      resultError: (method: string, error: string, result: MethodResult): void =>
        this.resultError(method, error, result),
      localStreams: this.localStreams,
      localTracks: this.localTracks,
      renders: this.renders,
      textureIdGetter: (): number => this.textureId,
      removeVideoCapturer: (trackId: string): void => this.getUserMediaImpl?.removeVideoCapturer(trackId)
    });
  }

  /** 初始化媒体捕获、视频渲染、数据通道、编解码能力类 Handler。 */
  private initMediaAndCapabilityHandlers(): void {
    this.mediaCaptureHandlers = new MediaCaptureHandlers({
      getMediaTrackConstraints: (videoOptionMap: DataMap): MediaTrackConstraints =>
        this.getMediaTrackConstraints(videoOptionMap),
      putLocalStream: (streamId: string, stream: MediaStream): boolean => this.putLocalStream(streamId, stream),
      getNextStreamUUID: (): string => this.getNextStreamUUID(),
      resultError: (method: string, error: string, result: MethodResult): void =>
        this.resultError(method, error, result),
      localStreams: this.localStreams,
      localTracks: this.localTracks
    });
    this.videoRendererHandlers = new VideoRendererHandlers({
      textures: this.textures,
      messenger: this.messenger,
      stateProvider: this.stateProvider,
      renders: this.renders,
      localStreams: this.localStreams,
      getStreamForId: (id: string, pcId: string): MediaStream | null => this.getStreamForId(id, pcId),
      resultError: (method: string, error: string, result: MethodResult): void =>
        this.resultError(method, error, result)
    });
    this.dataChannelConnectionHandlers = new DataChannelConnectionHandlers(
      (call: MethodCall, result: MethodResult): PeerConnectionObserver | null => this.getPCO(call, result),
      (call: MethodCall, result: MethodResult): RTCPeerConnection | null => this.getPeerConnection(call, result),
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result),
      this.peerConnectionObservers
    );
    this.capabilityMiscHandlers = new CapabilityMiscHandlers(
      (id: string, pcId?: string): MediaStreamTrack | null => this.getTrackForId(id, pcId),
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result)
    );
  }

  /**
   * 统一错误返回：记录日志并通过 MethodResult 将错误传播到 Flutter 层。
   * error code 使用方法名（与 Android `result.error(method, error, null)` / iOS 一致），
   * 便于 Dart 层按 PlatformException.code 区分错误来源；error message 含方法名与详情，
   * 供 Dart 层 `e.message` 展示。
   * @param method 方法名（同时作为 error code）
   * @param error 错误描述
   * @param result 回调句柄
   */
  resultError(method: string, error: string, result?: MethodResult): void {
    let errorMsg: string = `${method}(): ${error}`;
    Log.e(TAG, errorMsg);
    if (result) {
      result.error(method, errorMsg, null);
    } else {
      Log.e(TAG, `Cannot propagate error because MethodResult is unavailable: ${errorMsg}`);
    }
  }

  /**
   * 释放插件持有的全部资源，应在 onDetachedFromEngine 时调用。
   * 幂等：重复调用直接返回，避免 LifeCycleObserver.onAbilityDestroy 与
   * FlutterWebRTCPlugin.stopListening 双重触发导致 disposePluginResources 二次执行。
   * 释放顺序：先取消渲染器与轨道/流，再释放 PeerConnection，最后释放工厂与相机。
   */
  async dispose(): Promise<void> {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    await disposePluginResources({ renders: this.renders, localStreams: this.localStreams,
      localTracks: this.localTracks, peerConnections: this.peerConnectionObservers,
      mediaStreamHandlers: this.mediaStreamHandlers, factory: this.peerConnectionFactory,
      frameCryptor: this.frameCryptor, userMedia: this.getUserMediaImpl });
    // 清理 methodHandlers 闭包引用：这些闭包持有各 Handler 对象，
    // dispose 后显式 clear 以便 GC 回收已释放的 Handler。
    this.methodHandlers.clear();
    // 各 Handler 的依赖回调捕获宿主 this；置空子对象字段以断开
    // MCHI -> handler -> closure -> MCHI 循环引用链。
    this.audioHandlers = null;
    this.deviceHandlers = null;
    this.trackControlHandlers = null;
    this.signalingHandlers = null;
    this.rtpTransceiverHandlers = null;
    this.mediaStreamHandlers = null;
    this.mediaCaptureHandlers = null;
    this.videoRendererHandlers = null;
    this.dataChannelConnectionHandlers = null;
    this.capabilityMiscHandlers = null;
    this.configHandlers = null;
    this.peerConnectionFactory = null;
    this.getUserMediaImpl = null;
  }

  /**
   * 方法分发入口：根据 call.method 在 methodHandlers 中查找对应处理函数并调用。
   * 未命中时转交 frameCryptor 处理，整体包裹 try-catch 避免异常丢失。
   * @param call Flutter 方法调用
   * @param result 回调句柄
   */
  onMethodCall(call: MethodCall, result: MethodResult): void {
    // dispose 后不再分发，避免 methodHandlers 内的对象已被销毁但仍被调用。
    // 必须显式回错，否则 Flutter 侧 MethodChannel Future 会永久挂起。
    if (this.disposed) {
      Log.w(TAG, `onMethodCall ignored after dispose: ${call.method}`);
      result.error('disposed', 'FlutterWebRTCPlugin has been disposed', null);
      return;
    }
    let method: string = call.method;
    try {
      let handler: MethodHandler | undefined = this.methodHandlers.get(method);
      if (handler) {
        Log.d(TAG, `onMethodCall: ${method}`);
        handler(call, result);
      } else {
        this.frameCryptor.onMethodCall(call, result);
      }
    } catch (error) {
      this.resultError(method || 'onMethodCall', `failed: ${error}`, result);
    }
  }

  /**
   * 从MethodCall中解析peerConnectionId并获取PeerConnectionObserver。
   * @param call Flutter方法调用，包含peerConnectionId参数
   * @param result 回调句柄，peerConnection为null时回传错误
   * @returns 对应的PeerConnectionObserver，未找到或peerConnection为null时返回null
   */
  getPCO(call: MethodCall, result: MethodResult): PeerConnectionObserver | null {
    let peerConnectionObserver: PeerConnectionObserver | undefined =
      this.getPeerConnectionObserver(getPeerConnectionId(call));
    if (!peerConnectionObserver || !peerConnectionObserver.getPeerConnection()) {
      this.resultError(call.method, 'peerConnection is null', result);
      return null;
    }
    return peerConnectionObserver;
  }

  /**
   * 从MethodCall中解析peerConnectionId并获取RTCPeerConnection。
   * @param call Flutter方法调用，包含peerConnectionId参数
   * @param result 回调句柄，peerConnection为null时回传错误
   * @returns 对应的RTCPeerConnection，未找到时返回null
   */
  getPeerConnection(call: MethodCall, result: MethodResult): RTCPeerConnection | null {
    let peerConnectionObserver: PeerConnectionObserver | null = this.getPCO(call, result);
    return peerConnectionObserver?.getPeerConnection() ?? null;
  }

  /**
   * 根据peerConnectionId获取PeerConnectionObserver。
   * @param peerConnectionId PeerConnection的唯一标识
   * @returns 对应的PeerConnectionObserver，未找到时返回undefined
   */
  getPeerConnectionObserver(peerConnectionId: string): PeerConnectionObserver | undefined {
    return this.peerConnectionObservers.get(peerConnectionId);
  }

  /**
   * 从MethodCall中解析streamId并获取对应的MediaStream。
   * @param call Flutter方法调用，包含streamId参数
   * @param result 回调句柄，stream为undefined时回传错误
   * @param errorMsg 自定义错误消息，未提供时使用默认消息
   * @returns 对应的MediaStream，未找到时返回undefined
   */
  getMediaStream(call: MethodCall, result: MethodResult, errorMsg?: string): MediaStream | undefined {
    let mediaStream: MediaStream | undefined = this.getLocalStreams(getStreamId(call));
    if (!mediaStream) {
      this.resultError(call.method, errorMsg || 'mediaStream is null', result);
    }
    return mediaStream;
  }

  /**
   * 根据streamId获取本地MediaStream。
   * @param streamId Stream的唯一标识
   * @returns 对应的MediaStream，未找到时返回undefined
   */
  getLocalStreams(streamId: string): MediaStream | undefined {
    return this.localStreams.get(streamId);
  }

  /**
   * 从MethodCall中解析trackId并获取对应的MediaStreamTrack。
   * @param call Flutter方法调用，包含trackId参数
   * @param result 回调句柄，track为null时回传错误
   * @returns 对应的MediaStreamTrack，未找到时返回null
   */
  getMediaStreamTrack(call: MethodCall, result: MethodResult): MediaStreamTrack | null {
    let track: MediaStreamTrack | undefined = this.getLocalTrack(getTrackId(call));
    if (!track) {
      this.resultError(call.method, 'track is null', result);
      return null;
    }
    return track;
  }

  /**
   * 根据trackId获取本地MediaStreamTrack。
   * @param trackId Track的唯一标识
   * @returns 对应的MediaStreamTrack，未找到时返回undefined
   */
  getLocalTrack(trackId: string): MediaStreamTrack | undefined {
    return this.localTracks.get(trackId);
  }

  /**
   * 初始化 WebRTC 插件：解析 Flutter 传入的 optionsMap 配置项（网络掩码、强制软编、音频配置等），
   * 创建 AudioDeviceModule 并懒加载 PeerConnectionFactory 与 GetUserMediaImpl。重复调用直接返回 success 保证幂等。
   * @param call 方法调用（参数：options）
   * @param result 回调句柄
   */
  async initialize(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let optionsMap: ConstraintsMap = getOptionsMap(call);
      // 参数边界校验：optionsMap 必须存在；若解析异常则显式回错，
      // 避免后续访问抛出不明错误
      if (!optionsMap) {
        this.resultError('initialize', 'optionsMap is required', result);
        return;
      }
      let networkIgnoreMask: number = getOptionsNetworkIgnoreMask(optionsMap);
      let forceSWCodec: boolean = getOptionsForceSWCodec(optionsMap);
      let forceSWCodecList: ArrayList<string> = getOptionsForceSWCodecList(optionsMap);
      let audioConfiguration: ConstraintsMap = getOptionsAudioConfiguration(optionsMap);
      Log.i(TAG, `initialize optionsMap= ${optionsMap.toString()}`);
      Log.i(TAG, `initialize networkIgnoreMask= ${networkIgnoreMask}`);
      Log.i(TAG, `initialize forceSWCodec= ${forceSWCodec}`);
      Log.i(TAG, `initialize forceSWCodecList= ${forceSWCodecList}`);
      Log.i(TAG, 'initialize: forceSWCodec/forceSWCodecList are handled internally by libohos_webrtc.so,' +
        ' not configurable from ETS layer');
      Log.i(TAG, `initialize audioConfiguration= ${audioConfiguration}`);

      if (this.peerConnectionFactory) {
        // 工厂已初始化：仍需响应 Flutter，避免 Dart 侧 Future 永久挂起。
        result.success(null);
        return;
      }

      let audioSwitchManager: AudioSwitchManager = AudioSwitchManager.getInstance();
      await audioSwitchManager.createAudioDeviceModule();

      this.getUserMediaImpl = new GetUserMediaImpl(this.stateProvider, this.context);

      // 当前 ohos-webrtc 暂无其他可初始化接口；现有初始化流程已完成。
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'initialize failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 创建 PeerConnection 并返回其 id。
   * 关键路径包裹 try-catch，确保配置解析/工厂创建异常能传播到 Flutter 层而非丢失。
   * @param call 方法调用（参数：configuration、constraints）
   * @param result 回调句柄，返回 { peerConnectionId }
   */
  createPeerConnection(call: MethodCall, result: MethodResult): void {
    try {
      let configurationMap: ConstraintsMap = getConfigurationMap(call);
      let constraintsMap: ConstraintsMap = getConstraintsMap(call);
      Log.d(TAG, `createPeerConnection : configurationMap=${configurationMap.toString()}`);
      Log.d(TAG, `createPeerConnection : constraints=${constraintsMap.toString()}`);
      let configHandlers: PeerConnectionConfigHandlers | null = this.configHandlers;
      if (!configHandlers) {
        this.resultError(call.method, 'configuration handler is unavailable', result);
        return;
      }
      let peerConnectionId: string = configHandlers.peerConnectionInit(configurationMap, constraintsMap);
      let res: ConstraintsMap = new ConstraintsMap();
      res.putString('peerConnectionId', peerConnectionId);
      result.success(res.toMap());
    } catch (error) {
      this.resultError(call.method, 'createPeerConnection failed: ' + JSON.stringify(error), result);
    }
  }

  /** 懒加载获取 PeerConnectionFactory。委托给 PeerConnectionConfigHandlers。 */
  getPeerConnectionFactory(): PeerConnectionFactory {
    if (!this.configHandlers) {
      throw new Error('configuration handler is unavailable');
    }
    return this.configHandlers.getPeerConnectionFactory();
  }

  /**
   * 将本地MediaStream存入Map中。
   * @param streamId Stream的唯一标识
   * @param stream 要存储的MediaStream
   * @returns 始终返回true
   */
  putLocalStream(streamId: string, stream: MediaStream): boolean {
    this.localStreams.set(streamId, stream);
    return true;
  }

  /**
   * 将本地Track存入Map中。
   * @param trackId Track的唯一标识
   * @param track 要存储的MediaStreamTrack
   * @returns 始终返回true
   */
  putLocalTrack(trackId: string, track: MediaStreamTrack): boolean {
    this.localTracks.set(trackId, track);
    return true;
  }

  /**
   * 生成下一个Track的UUID，确保不与已有Track冲突。
   * @returns 唯一的Track UUID字符串
   */
  getNextTrackUUID(): string {
    let uuid: string = '';
    do {
      uuid = util.generateRandomUUID();
    } while (this.getTrackForId(uuid) !== null);

    return uuid;
  }

  /**
   * 获取当前的UIAbility实例。
   * @returns UIAbility实例，可能为null
   */
  getAbility(): UIAbility | null {
    return this.ability;
  }

  /**
   * 获取应用的ApplicationContext。
   * @returns ApplicationContext实例或undefined
   */
  getApplicationContext(): common.ApplicationContext | undefined {
    return this.context.getApplicationContext();
  }

  /**
   * 获取当前BinaryMessenger实例。
   * @returns BinaryMessenger实例
   */
  getMessenger(): BinaryMessenger {
    return this.messenger;
  }

  /**
   * 将DataMap转换为MediaTrackConstraints约束对象。
   * @param videoOptionMap 视频选项数据映射
   * @returns 媒体轨道约束对象
   */
  getMediaTrackConstraints(videoOptionMap: DataMap): MediaTrackConstraints {
    return this.getDeviceHandlers().getMediaTrackConstraints(videoOptionMap);
  }

  /**
   * 获取摄像头信息。
   * @param index 摄像头索引
   * @param camera 摄像头设备对象
   * @returns 摄像头设备信息的ConstraintsMap
   */
  getCameraInfo(index: number, camera: camera.CameraDevice): ConstraintsMap {
    return this.getDeviceHandlers().getCameraInfo(index, camera);
  }

  /**
   * 获取音频输入设备信息。
   * @param audioDeviceDescriptor 音频设备描述符
   * @returns 音频输入设备信息的ConstraintsMap
   */
  getAudioInputInfo(audioDeviceDescriptor: audio.AudioDeviceDescriptor): ConstraintsMap {
    return this.getDeviceHandlers().getAudioInputInfo(audioDeviceDescriptor);
  }

  /**
   * 获取音频输出设备信息。
   * @param audioDeviceDescriptor 音频设备描述符
   * @returns 音频输出设备信息的ConstraintsMap
   */
  getAudioOutputInfo(audioDeviceDescriptor: audio.AudioDeviceDescriptor): ConstraintsMap {
    return this.getDeviceHandlers().getAudioOutputInfo(audioDeviceDescriptor);
  }

  private getDeviceHandlers(): DeviceEnumerationHandlers {
    if (!this.deviceHandlers) {
      throw new Error('device handlers are unavailable');
    }
    return this.deviceHandlers;
  }

  private parseRTCConfiguration(map: ConstraintsMap): RTCConfiguration {
    if (!this.configHandlers) {
      throw new Error('configuration handler is unavailable');
    }
    return this.configHandlers.parseRTCConfiguration(map);
  }

  /**
   * 设置当前的UIAbility实例。
   * @param ability UIAbility实例，可为null
   */
  setAbility(ability: UIAbility | null): void {
    this.ability = ability;
  }

  /**
   * 生成下一个Stream的UUID，确保不与已有Stream冲突。
   * @returns 唯一的Stream UUID字符串
   */
  public getNextStreamUUID(): string {
    let uuid: string = '';
    do {
      uuid = util.generateRandomUUID();
    } while (this.getStreamForId(uuid, '') !== null);

    return uuid;
  }

  /** Resolves a local or remote stream by id. */
  getStreamForId(id: string, peerConnectionId: string): MediaStream | null {
    return this.mediaStateLookup.getStream(id, peerConnectionId);
  }

  /** Resolves a local or remote track by id. */
  getTrackForId(trackId: string, peerConnectionId?: string): MediaStreamTrack | null {
    return this.mediaStateLookup.getTrack(trackId, peerConnectionId);
  }


  /**
   * 处理协商需要事件，记录日志。
   * @param event 协商需要事件对象
   */
  onNegotiationNeeded(event: Event): void {
    Log.d(TAG, 'onNegotiationNeeded: this=' + JSON.stringify(this));
    Log.d(TAG, 'onNegotiationNeeded: event=' + JSON.stringify(event));
  }
}
