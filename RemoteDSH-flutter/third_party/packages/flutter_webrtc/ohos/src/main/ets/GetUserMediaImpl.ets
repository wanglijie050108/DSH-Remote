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

import StateProvider from './StateProvider';
import { Log, MethodResult, SurfaceTextureEntry } from '@ohos/flutter_ohos';
import { ConstraintsArray } from './utils/ConstraintsArray';
import { ConstraintsMap } from './utils/ConstraintsMap';
import {
  AudioSource,
  MediaStream,
  MediaStreamTrack,
  PeerConnectionFactory,
  VideoSource,
  VideoTrack
} from 'libohos_webrtc.so';
import { HashMap } from '@kit.ArkTS';
import { ObjectType } from './utils/ObjectType';
import { LocalAudioTrackFactory } from './LocalAudioTrackFactory';
import {
  beginConfig,
  getCameraDevices,
  getCameraInput,
  getCameraManager,
  getCaptureSession,
  getPreviewOutput,
  getSupportedOutputCapability,
  isTorchSupported,
  releaseCamera,
  setSessionCameraInput,
  setSessionPreviewOutput,
  setTorchMode,
  setZoom,
  startSession,
  switchCamera
} from './utils/CameraStateManager';
import { camera } from '@kit.CameraKit';
import { common } from '@kit.AbilityKit';
import { VideoConstraintsParser, VideoConstraintsResult } from './VideoConstraintsParser';

const TAG: string = 'FlutterWebRTCPlugin-GetUserMediaImpl';

export default class GetUserMediaImpl {
  private static DEFAULT_WIDTH: number = 1280;
  private static DEFAULT_HEIGHT: number = 720;
  private static DEFAULT_FPS: number = 30;
  // @deprecated unused 以下常量为 Android 权限/录屏模型的遗留占位，OHOS 权限走 PermissionsUtil，
  // 当前实现未引用；保留以兼容历史调用方，勿在新代码中使用。
  private static PERMISSION_AUDIO: string = '';
  private static PERMISSION_VIDEO: string = '';
  private static PERMISSION_SCREEN: string = '';
  private static CAPTURE_PERMISSION_REQUEST_CODE: number = 1;
  private static GRANT_RESULTS: string = 'GRANT_RESULT';
  private static PERMISSIONS: string = 'PERMISSION';
  private static PROJECTION_DATA: string = 'PROJECTION_DATA';
  private static RESULT_RECEIVER: string = 'RESULT_RECEIVER';
  private static REQUEST_CODE: string = 'REQUEST_CODE';
  // private mVideoCapturers: HashMap<String, VideoCapturerInfo> = new HashMap();
  // private mSurfaceTextureHelpers: HashMap<String, SurfaceTextureHelper> = new HashMap();
  private stateProvider: StateProvider | null = null;
  private applicationContext: common.Context | null = null;
  private isFacing: boolean = true;
  private isTorchOn: boolean = false;
  private surfaceTextureEntry: SurfaceTextureEntry | null = null;
  // trackId -> AudioSource 映射：创建本地音频轨道时记录其对应的 AudioSource，
  // 供 setVolume 通过 trackId 定位音频源并设置实际音量（OHOS volume API 位于 AudioSource）。
  private audioSources: HashMap<string, AudioSource> = new HashMap();
  private videoConstraintsParser: VideoConstraintsParser = new VideoConstraintsParser();

  /**
   * 构造 GetUserMediaImpl：注入状态提供者与应用上下文，并预热摄像头管理器。
   * @param stateProvider 全局状态提供者，用于缓存本地流/轨道与获取 PeerConnectionFactory
   * @param applicationContext 应用上下文，透传给摄像头管理器初始化
   */
  constructor(stateProvider: StateProvider, applicationContext: common.Context) {
    this.stateProvider = stateProvider;
    this.applicationContext = applicationContext;
    getCameraManager(applicationContext);
  }

  /**
   * 设置 SurfaceTextureEntry，用于视频渲染输出。
   * @param surfaceTextureEntry SurfaceTextureEntry 实例或 null
   */
  setSurfaceTextureEntry(surfaceTextureEntry: SurfaceTextureEntry | null): void {
    this.surfaceTextureEntry = surfaceTextureEntry;
  }

  /**
   * 通过 MethodResult 返回错误信息并记录日志。
   * @param method 方法名
   * @param error 错误描述
   * @param result 回调句柄
   */
  resultError(method: string, error: string, result: MethodResult): void {
    let errorMsg: string = method + '(): ' + error;
    result.error(method, errorMsg, null);
    Log.d(TAG, errorMsg);
  }

  /**
   * 获取用户媒体设备（音频和视频轨道），将结果通过 MethodResult 回调返回。
   * @param constraints 媒体约束
   * @param result 回调句柄
   * @param mediaStream 目标媒体流
   */
  getUserMedia(constraints: ConstraintsMap, result: MethodResult, mediaStream: MediaStream): void {
    Log.d(TAG, 'getUserMedia in!');

    try {
      /*
       * 这里的作用是获取media的 streamId audioTracks videoTracks
       *
       * */
      let trackParams: ConstraintsMap[] = [new ConstraintsMap(), new ConstraintsMap()];

      trackParams[0] = this.getUserAudio(constraints, mediaStream);
      trackParams[1] = this.getUserVideo(constraints, mediaStream);

      let audioTracks: ConstraintsArray = new ConstraintsArray();
      let videoTracks: ConstraintsArray = new ConstraintsArray();
      let successResult: ConstraintsMap = new ConstraintsMap();

      for (let i = 0; i < trackParams.length; i++) {
        if (trackParams[i].toMap() === null) {
          continue;
        }
        if (trackParams[i].getString('kind') === 'audio') {
          audioTracks.pushMap(trackParams[i].toMap());
        } else {
          videoTracks.pushMap(trackParams[i].toMap());
        }
      }

      let streamId: string = mediaStream.id;
      Log.d(TAG, 'MediaStream id: ' + streamId);
      this.stateProvider?.putLocalStream(streamId, mediaStream);

      successResult.putString('streamId', streamId);
      successResult.putArray('audioTracks', audioTracks.toArrayList());
      successResult.putArray('videoTracks', videoTracks.toArrayList());
      result.success(successResult.toMap());
    } catch (error) {
      this.resultError('getUserMedia', 'getUserMedia failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 屏幕共享捕获（遗留入口）。
   * 当前实际实现已迁移至 MediaCaptureHandlers.getDisplayMedia，此遗留方法仅做日志记录，
   * 不再挂起调用方 Future。若被误调用则显式返回错误，避免 Flutter 侧 Future 永久悬挂。
   * @param constraints 媒体约束
   * @param result 回调句柄
   * @param mediaStream 目标媒体流
   */
  getDisplayMedia(constraints: ConstraintsMap, result: MethodResult, mediaStream: MediaStream): void {
    Log.w(TAG, 'getDisplayMedia legacy entry reached; real impl is in MediaCaptureHandlers.getDisplayMedia');
    result.error(
      'getDisplayMedia',
      'legacy GetUserMediaImpl.getDisplayMedia is deprecated; use MediaCaptureHandlers',
      null
    );
  }

  /**
   * 创建本地音频轨道。
   * 注意：OHOS WebRTC SDK 暂未提供按 deviceId 选择音频输入设备的 setPreferredInputDevice API，
   * 此处记录传入的 deviceId（供 settings 回传），并使用默认输入设备创建轨道。
   * 不再使用空的 try 块吞掉逻辑。
   * @param constraints 媒体约束
   * @param stream 目标媒体流
   * @returns 音频轨道参数 Map
   */
  getUserAudio(constraints: ConstraintsMap, stream: MediaStream): ConstraintsMap {
    Log.d(TAG, 'getUserAudio in!');
    try {
      let stateProvider: StateProvider | null = this.stateProvider;
      if (!stateProvider) {
        Log.e(TAG, 'getUserAudio stateProvider is null');
        return new ConstraintsMap();
      }
      let trackParams: ConstraintsMap = LocalAudioTrackFactory.create(
        constraints,
        stream,
        stateProvider,
        this.audioSources
      );
      Log.d(TAG, 'getUserAudio out!');
      return trackParams;
    } catch (error) {
      Log.e(TAG, 'getUserAudio failed: ' + JSON.stringify(error));
      // 重新抛出，交由 getUserMedia 外层 try-catch 传播到 Flutter，
      // 避免返回空 Map 导致 Flutter 收到"成功但无轨道"的误导性结果。
      throw new Error('getUserAudio failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建本地视频轨道。
   * @param constraints 媒体约束
   * @param stream 目标媒体流
   * @returns 视频轨道参数 Map
   */
  getUserVideo(constraints: ConstraintsMap, stream: MediaStream): ConstraintsMap {
    Log.d(TAG, 'getUserVideo in!');
    try {
      let stateProvider: StateProvider | null = this.stateProvider;
      if (!stateProvider) {
        Log.e(TAG, 'getUserVideo stateProvider is null');
        return new ConstraintsMap();
      }

      let parsed: VideoConstraintsResult = this.videoConstraintsParser.parse(constraints);
      let videoConstraintsMap: ConstraintsMap = parsed.videoConstraintsMap;
      let videoConstraintsMandatory: ConstraintsMap = parsed.videoConstraintsMandatory;

      let facingMode: string = this.videoConstraintsParser.getFacingMode(videoConstraintsMap);
      this.isFacing = facingMode === '' || !(facingMode === 'environment');
      Log.d(TAG, 'getUserVideo facingMode=' + facingMode + ' isFacing=' + this.isFacing);

      let videoWidth: number = this.videoConstraintsParser.resolveNumber(videoConstraintsMap, videoConstraintsMandatory,
        'width', 'minWidth', GetUserMediaImpl.DEFAULT_WIDTH);
      let videoHeight: number = this.videoConstraintsParser.resolveNumber(
        videoConstraintsMap, videoConstraintsMandatory,
        'height', 'minHeight', GetUserMediaImpl.DEFAULT_HEIGHT);
      let videoFrameRate: number = this.videoConstraintsParser.resolveNumber(
        videoConstraintsMap, videoConstraintsMandatory,
        'frameRate', 'minFrameRate', GetUserMediaImpl.DEFAULT_FPS);

      let track: VideoTrack = this.createVideoTrack(stateProvider, stream);
      let trackParams: ConstraintsMap = this.buildVideoTrackParams(track, facingMode,
        videoWidth, videoHeight, videoFrameRate);

      Log.d(TAG, 'getUserVideo out!');
      return trackParams;
    } catch (error) {
      Log.e(TAG, 'getUserVideo failed: ' + JSON.stringify(error));
      // 重新抛出，交由 getUserMedia 外层 try-catch 传播到 Flutter，
      // 避免返回空 Map 导致 Flutter 收到"成功但无轨道"的误导性结果。
      throw new Error('getUserVideo failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建视频轨道并加入媒体流与本地轨道缓存。
   * @param stateProvider 状态提供者
   * @param stream 目标媒体流
   * @returns 创建的视频轨道
   */
  private createVideoTrack(stateProvider: StateProvider, stream: MediaStream): VideoTrack {
    let pcFactory: PeerConnectionFactory = stateProvider.getPeerConnectionFactory();
    let videoSource: VideoSource = pcFactory.createVideoSource();
    let track: VideoTrack = pcFactory.createVideoTrack('video', videoSource);
    stream.addTrack(track);
    stateProvider.putLocalTrack(track.id, track);
    return track;
  }

  /**
   * 构建视频轨道参数 Map。
   * @param track 视频轨道
   * @param facingMode 朝向
   * @param videoWidth 宽度
   * @param videoHeight 高度
   * @param videoFrameRate 帧率
   * @returns 轨道参数 Map
   */
  private buildVideoTrackParams(track: VideoTrack, facingMode: string,
    videoWidth: number, videoHeight: number, videoFrameRate: number): ConstraintsMap {
    let trackParams: ConstraintsMap = new ConstraintsMap();
    trackParams.putBoolean('enabled', track.enabled);
    trackParams.putString('id', track.id);
    trackParams.putString('kind', 'video');
    trackParams.putString('label', track.id);
    trackParams.putString('readyState', track.readyState.toString());
    trackParams.putBoolean('remote', false);

    let settings: ConstraintsMap = new ConstraintsMap();
    settings.putString('deviceId', '' + -1);
    settings.putString('kind', 'videoinput');
    settings.putNumber('width', videoWidth);
    settings.putNumber('height', videoHeight);
    settings.putNumber('frameRate', videoFrameRate);
    if (facingMode !== null) {
      settings.putString('facingMode', facingMode);
    }
    trackParams.putMap('settings', settings.toMap());
    return trackParams;
  }

  /**
   * check torchMode is available
   * */
  hasTorch(trackId: string, result: MethodResult): void {
    Log.d(TAG, `hasTorch in, trackId=${trackId}`);
    let track: MediaStreamTrack | undefined = this.stateProvider?.getLocalTrack(trackId);
    if (!track || track.kind !== 'video') {
      this.resultError('hasTorch', `video track not found for trackId: ${trackId}`, result);
      return;
    }
    result.success(isTorchSupported());
  }

  /**
   * 设置指定视频轨道对应摄像头的闪光灯模式。
   * @param trackId 视频轨道 id
   * @param torch true 表示开启闪光灯，false 表示关闭
   * @param result 回调句柄
   */
  setTorch(trackId: string, torch: boolean, result: MethodResult): void {
    Log.d(TAG, `setTorch in, trackId=${trackId}`);
    try {
      // 通过 trackId 校验轨道存在性，便于按轨道定位对应的摄像头会话
      let track: MediaStreamTrack | undefined = this.stateProvider?.getLocalTrack(trackId);
      if (!track || track.kind !== 'video') {
        this.resultError('setTorch', `video track not found for trackId: ${trackId}`, result);
        return;
      }
      setTorchMode(torch ? camera.FlashMode.FLASH_MODE_ALWAYS_OPEN : camera.FlashMode.FLASH_MODE_CLOSE);
      result.success(null);
      this.isTorchOn = torch;
    } catch (error) {
      let message: string = JSON.stringify(error);
      Log.e(TAG, `The setTorchMode call failed: ${message}`);
      this.resultError('setTorch', `The setTorchMode call failed: ${message}`, result);
    }
  }

  private cameraPosition: boolean = false;

  /**
   * 切换摄像头。不再对 surfaceTextureEntry 使用非空断言，缺失时返回错误而非崩溃。
   * @param trackId 视频轨道 id
   * @param result 回调句柄
   */
  switchCamera(trackId: string, result: MethodResult): void {
    Log.d(TAG, `switchCamera in, trackId=${trackId}`);
    let surfaceId: string;
    try {
      // 通过 trackId 校验视频轨道存在性，便于按轨道定位对应摄像头
      let track: MediaStreamTrack | undefined = this.stateProvider?.getLocalTrack(trackId);
      if (!track || track.kind !== 'video') {
        this.resultError('switchCamera', `video track not found for trackId: ${trackId}`, result);
        return;
      }
      if (!this.surfaceTextureEntry) {
        this.resultError('switchCamera', 'surfaceTextureEntry is null', result);
        return;
      }
      surfaceId = this.surfaceTextureEntry.getSurfaceId().toString();
      this.cameraPosition = !this.cameraPosition;
      switchCamera(Number(this.cameraPosition), surfaceId, 0);
      result.success(true);
    } catch (error) {
      let message: string = JSON.stringify(error);
      Log.e(TAG, `The switchCamera call failed: ${message}`);
      this.resultError('switchCamera', `The switchCamera call failed: ${message}`, result);
    }
  }

  /**
   * 设置指定视频轨道对应摄像头的缩放级别。
   * @param trackId 视频轨道 id
   * @param zoomLevel 缩放级别
   * @param result 回调句柄
   */
  setZoom(trackId: string, zoomLevel: number, result: MethodResult): void {
    Log.d(TAG, `setZoom in, trackId=${trackId}`);
    try {
      // 通过 trackId 校验视频轨道存在性，便于按轨道定位对应摄像头进行缩放
      let track: MediaStreamTrack | undefined = this.stateProvider?.getLocalTrack(trackId);
      if (!track || track.kind !== 'video') {
        this.resultError('setZoom', `video track not found for trackId: ${trackId}`, result);
        return;
      }
      setZoom(zoomLevel);
      result.success(null);
    } catch (error) {
      let message: string = JSON.stringify(error);
      Log.e(TAG, `The setZoom call failed: ${message}`);
      this.resultError('setZoom', `The setZoom call failed: ${message}`, result);
    }
  }

  /**
   * 通过 trackId 查找对应的本地音频源（AudioSource），供 setVolume 设置实际音量。
   * OHOS WebRTC 的音量设置 API 位于 AudioSource.setVolume，而非 AudioTrack，
   * 因此创建音频轨道时记录 trackId -> AudioSource 映射以支持按轨道定位。
   * @param trackId 音频轨道 id
   * @returns 对应的 AudioSource，无则 null
   */
  getAudioSourceForTrack(trackId: string): AudioSource | null {
    let source: AudioSource | undefined = this.audioSources.get(trackId);
    return source ?? null;
  }

  /**
   * 移除指定视频捕获器资源，并清空缓存的 surfaceTextureEntry 引用。
   * @param id 视频轨道 id
   */
  removeVideoCapturer(id: string): void {
    Log.d(TAG, 'removeVideoCapturer id: ' + id);
    this.surfaceTextureEntry = null;
  }

  /**
   * 释放 GetUserMediaImpl 持有的资源：释放摄像头会话并清空引用。
   * 注意：AudioSource（见 libohos_webrtc/webrtc.d.ts）仅声明 setVolume，
   * 未暴露 stop()/release() 方法，原生音频源由 native GC 管理，故此处仅清空映射。
   */
  /**
   * 释放 GetUserMediaImpl 持有的资源（surfaceTextureEntry、stateProvider 引用、相机资源）。
   * releaseCamera 为异步操作，使用 await 确保相机 session 在返回前完整释放，
   * 避免相机回调在 Ability 销毁后访问已释放的 session 对象。
   */
  async dispose(): Promise<void> {
    try {
      await releaseCamera();
    } catch (error) {
      Log.e(TAG, 'dispose releaseCamera failed: ' + JSON.stringify(error));
    }
    // AudioSource 无 stop()/release() API，原生源由 GC 回收，仅清空映射。
    this.audioSources.clear();
    this.surfaceTextureEntry = null;
    this.stateProvider = null;
    this.applicationContext = null;
  }
}
