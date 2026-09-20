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

import { MethodResult, EventChannel, Log } from '@ohos/flutter_ohos';
import { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { ConstraintsMap } from './utils/ConstraintsMap';
import webrtc, {
  FrameResolutionEvent,
  MediaStream,
  MediaStreamTrack,
  NativeVideoRenderer,
  VideoTrack
} from 'libohos_webrtc.so';
import StateProvider from './StateProvider';

const TAG: string = 'FlutterWebRTCPlugin-FlutterRTCVideoRenderer';

/**
 * 视频帧分辨率/旋转变化回调的数据结构。
 * 替代原先的 ESObject，为回调参数提供明确的编译期类型。
 */
type FrameResolutionData = FrameResolutionEvent;

export default class FlutterRTCVideoRenderer implements StreamHandler {
  private id: number = -1;
  private surfaceId: string = '';
  private mediaStream: MediaStream | null = null;
  private ownerTag: string | null = '';
  private videoTrack: VideoTrack | null = null;
  eventChannel: EventChannel | null = null;
  eventSink: EventSink | null = null;
  private width: number = 0;
  private height: number = 0;
  private rotation: number = -1;
  private nativeVideoRenderer: NativeVideoRenderer;
  private disposed: boolean = false;

  /**
   * 构造视频渲染器：创建 NativeVideoRenderer、绑定帧分辨率回调并初始化事件出口。
   * @param textureId 纹理 id（由 TextureRegistry 分配，与 Dart 侧 RTCVideoRenderer 对应）
   * @param stateProvider 状态提供者（保留引用供后续资源访问）
   */
  constructor(textureId: number, stateProvider: StateProvider) {
    this.nativeVideoRenderer = new NativeVideoRenderer();
    this.bindFrameResolutionCallback();
    this.eventSink = null;
    this.ownerTag = '';
  }

  /**
   * 视频帧分辨率/旋转变化回调，将变化事件推送到 Flutter 层。
   * @param data 分辨率与旋转信息
   */
  frameResolutionChanged(data: FrameResolutionData): void {
    try {
      if (this.disposed) {
        return;
      }
      Log.d(TAG, 'onFrameResolutionChanged ' + JSON.stringify(data));
      if (!this.eventSink) {
        return;
      }
      if (this.width !== data.width || this.height !== data.height) {
        let params: ConstraintsMap = new ConstraintsMap();
        params.putString('event', 'didTextureChangeVideoSize');
        params.putNumber('id', this.id);
        params.putNumber('width', data.width);
        params.putNumber('height', data.height);
        this.width = data.width;
        this.height = data.height;
        this.eventSink.success(params.toMap());
      }
      if (this.rotation !== data.rotation) {
        let params: ConstraintsMap = new ConstraintsMap();
        params.putString('event', 'didTextureChangeRotation');
        params.putNumber('id', this.id);
        params.putNumber('rotation', data.rotation);
        this.rotation = data.rotation;
        this.eventSink.success(params.toMap());
      }
    } catch (error) {
      Log.e(TAG, 'frameResolutionChanged failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 设置视频渲染器的 ID。
   * @param id 渲染器唯一标识
   */
  setId(id: number): void {
    this.id = id;
  }

  /**
   * 获取当前绑定的 surfaceId。
   * @returns surfaceId 字符串
   */
  getSurfaceId(): string {
    return this.surfaceId;
  }

  /**
   * 初始化视频渲染器，绑定 surfaceId 并创建底层 NativeVideoRenderer。
   * 若 surfaceId 已被替换，则先释放旧的渲染器再重新创建。
   * @param id surfaceId 字符串
   */
  init(id: string): void {
    if (this.disposed || id === '') {
      return;
    }
    if (this.surfaceId === '') {
      //首次进入
      this.surfaceId = id;
      this.nativeVideoRenderer.init(this.surfaceId);
    } else {
      //被替换,释放重新创建
      Log.d(TAG, 'init surfaceId :  ' + id);
      // release 可能抛异常，需保护以避免阻断后续重新创建
      try {
        this.nativeVideoRenderer.release();
      } catch (error) {
        Log.e(TAG, 'nativeVideoRenderer.release (reinit) failed: ' + JSON.stringify(error));
      }
      this.nativeVideoRenderer = new NativeVideoRenderer();
      this.bindFrameResolutionCallback();
      this.surfaceId = id;
      this.nativeVideoRenderer.init(this.surfaceId);
      this.tryAddRendererToVideoTrack();
    }
  }

  /**
   * EventChannel 注册回调：缓存 EventSink 以便后续向 Flutter 推送视频渲染事件。
   * @param args 事件通道参数
   * @param events 事件下沉句柄
   */
  onListen(args: Object, events: EventSink): void {
    this.eventSink = events;
  }

  /**
   * EventChannel 注销回调：清除 EventSink 引用以停止事件推送。
   * @param args 事件通道参数
   */
  onCancel(args: Object): void {
    this.eventSink = null;
  }

  /**
   * 绑定 EventChannel，用于向 Flutter 层推送事件。
   * @param eventChannel 事件通道实例
   */
  public setEventChannel(eventChannel: EventChannel): void {
    this.eventChannel = eventChannel;
  }

  /**
   * 通过 MethodResult 向 Flutter 层返回错误信息。
   * @param method 调用方方法名
   * @param error 错误描述
   * @param result MethodResult 回调
   */
  resultError(method: string, error: string, result: MethodResult): void {
    let errorMsg: string = method + '(): ' + error;
    result.error(method, errorMsg, null);
    Log.d(TAG, errorMsg);
  }

  /**
   * 释放视频渲染器资源：解除 EventChannel 绑定、停止视频轨道、释放 NativeVideoRenderer，
   * 并清除帧分辨率回调以打破 nativeVideoRenderer -> callback -> this 的循环引用。
   */
  public dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    if (this.eventChannel !== null) {
      this.eventChannel?.setStreamHandler(null);
    }
    this.eventSink = null;
    this.eventChannel = null;
    this.mediaStream = null;
    this.ownerTag = null;
    this.videoTrack = null;
    this.nativeVideoRenderer.onFrameResolutionChanged = null;
    // release 可能抛异常，需保护以确保 dispose 流程完整执行
    try {
      this.nativeVideoRenderer.release();
    } catch (error) {
      Log.e(TAG, 'nativeVideoRenderer.release failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 设置视频流的 MediaStream 数据源，并自动提取其中的视频轨道进行渲染。
   * @param mediaStream 媒体流对象，传 null 表示清除当前流
   * @param ownerTag 流的所有者标签，用于对等连接的轨道归属识别
   * @param trackId 可选，指定具体的视频轨道 ID
   */
  public setStream(mediaStream: MediaStream | null, ownerTag: string | null, trackId?: string): void {
    let videoTrack: MediaStreamTrack | null;
    this.mediaStream = mediaStream;
    this.ownerTag = ownerTag;
    Log.d(TAG, 'mediaStream id :' + this.mediaStream?.id);
    Log.d(TAG, 'mediaStream surfaceId :' + this.surfaceId);
    Log.d(TAG, 'mediaStream trackId :' + trackId);
    Log.d(TAG, 'mediaStream ownerTag :' + ownerTag);
    if (mediaStream === null) {
      Log.d(TAG, 'mediaStream mediaStream null :');
      videoTrack = null;
    } else {
      let videoTracks: MediaStreamTrack[] = mediaStream?.getVideoTracks();
      videoTrack = videoTracks.length > 0 ? videoTracks[0] : null;
    }
    Log.e(TAG, 'setStream  setVideoTrack : ' + videoTrack?.id);
    this.setVideoTrack(videoTrack);
  }

  /**
   * 设置当前渲染器绑定的视频轨道。若轨道有变化则更新底层渲染器。
   * @param videoTrack 视频轨道对象，传 null 表示解除绑定
   */
  setVideoTrack(videoTrack: MediaStreamTrack | null): void {
    if (this.disposed) {
      return;
    }
    let oldValue: MediaStreamTrack | null = this.videoTrack;
    Log.d(TAG, 'setStream  setVideoTrack oldValue : ' + oldValue?.id);
    Log.d(TAG, 'setStream  setVideoTrack videoTrack : ' + videoTrack?.id);
    if (oldValue?.id === videoTrack?.id) {
      // 轨道未变，但 SurfaceTexture 可能因屏幕旋转而重建了。如果 surfaceId 发生变化，
      // 仍需重新将当前轨道绑定到新的 NativeVideoRenderer。
      Log.w(TAG, 'FlutterRTCVideoRenderer VideoTrack no change, re-adding renderer to track');
      this.tryAddRendererToVideoTrack();
      return;
    }
    // VideoTrack is a TS interface (runtime-erased), so instanceof narrowing is unavailable;
    // the cast is required to store the MediaStreamTrack into the VideoTrack | null field.
    this.videoTrack = videoTrack as VideoTrack | null;
    if (!videoTrack) {
      Log.e(TAG, 'FlutterRTCVideoRenderer.setVideoTrack, set video track to null');
      this.removeRendererFromVideoTrack();
      return;
    }
    try {
      Log.d(TAG, 'FlutterRTCVideoRenderer.setVideoTrack, set video track to ' + videoTrack.id);
      this.tryAddRendererToVideoTrack();
    } catch (error) {
      Log.e(TAG, 'tryAddRendererToVideoTrack ' + error);
    }
  }

  /**
   * 将底层 NativeVideoRenderer 的视频轨道置空，解除渲染绑定。
   * 此操作不会停止采集端轨道，避免影响其他发送方复用同一轨道。
   */
  removeRendererFromVideoTrack(): void {
    // Renderer does not own MediaStreamTrack. Detaching a source must never stop
    // the capture track because the same track can still be used by a sender.
    this.nativeVideoRenderer.setVideoTrack(null);
  }

  /**
   * 尝试将当前绑定的视频轨道设置到底层渲染器。
   * 必须在未释放、surfaceId 已初始化且 videoTrack 非空时才执行。
   */
  tryAddRendererToVideoTrack(): void {
    if (!this.disposed && this.surfaceId !== '' && this.videoTrack) {
      this.nativeVideoRenderer.setVideoTrack(this.videoTrack);
    }
  }

  private bindFrameResolutionCallback(): void {
    this.nativeVideoRenderer.onFrameResolutionChanged =
      (event: FrameResolutionEvent): void => this.frameResolutionChanged(event);
  }

  /**
   * 检查指定的媒体流 ID 与当前渲染器绑定的流是否一致，且 ownerTag 匹配。
   * @param id 待校验的媒体流 ID
   * @param ownerTag 待校验的所有者标签
   * @returns 匹配成功返回 true，否则返回 false
   */
  public checkMediaStream(id: string, ownerTag: string): boolean {
    if (id === null || this.mediaStream === null || ownerTag === null || ownerTag !== this.ownerTag) {
      return false;
    }
    return id === this.mediaStream.id;
  }

  /**
   * 检查指定的视频轨道 ID 与当前渲染器绑定的轨道是否一致，且 ownerTag 匹配。
   * @param id 待校验的视频轨道 ID
   * @param ownerTag 待校验的所有者标签
   * @returns 匹配成功返回 true，否则返回 false
   */
  public checkVideoTrack(id: string, ownerTag: string): boolean {
    if (id === null || this.videoTrack === null || ownerTag === null || ownerTag !== this.ownerTag) {
      return false;
    }
    return id === this.videoTrack.id;
  }
}
