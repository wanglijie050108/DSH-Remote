/*
 * Copyright (C) 2026 Huawei Device Co., Ltd.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 
import { BinaryMessenger, EventChannel, Log, MethodCall, MethodResult, TextureRegistry } from '@ohos/flutter_ohos';
import { HashMap, PlainArray } from '@kit.ArkTS';
import { MediaStream } from 'libohos_webrtc.so';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { getStreamId, getTrackId } from './utils/CallUtils';
import FlutterRTCVideoRenderer from './FlutterRTCVideoRenderer';
import StateProvider from './StateProvider';

const TAG: string = 'FlutterWebRTCPlugin-VideoRendererHandlers';

/**
 * 视频渲染器相关方法集合（创建、释放、设置源）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 textures、messenger、stateProvider、
 * renders 映射与 host 回调，与原实现保持等价行为。
 */

/**
 * 视频渲染器处理器的依赖注入配置对象，将多个构造参数收敛为单一对象，
 * 避免构造函数参数数量超标。
 */
export interface VideoRendererHandlersOptions {
  textures: TextureRegistry;
  messenger: BinaryMessenger;
  stateProvider: StateProvider;
  renders: PlainArray<FlutterRTCVideoRenderer>;
  localStreams: HashMap<string, MediaStream>;
  getStreamForId: (id: string, peerConnectionId: string) => MediaStream | null;
  resultError: (method: string, error: string, result: MethodResult) => void;
}

export class VideoRendererHandlers {
  private textures: TextureRegistry;
  private messenger: BinaryMessenger;
  private stateProvider: StateProvider;
  private renders: PlainArray<FlutterRTCVideoRenderer>;
  private localStreams: HashMap<string, MediaStream>;
  private getStreamForId: (id: string, peerConnectionId: string) => MediaStream | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;

  /**
   * 构造视频渲染器处理器：从依赖注入配置对象中读取并缓存纹理注册表、信使、
   * 状态提供者、渲染器映射、本地流映射及 host 回调。
   * @param options 依赖注入配置对象（收敛多构造参数，避免参数数量超标）
   */
  constructor(options: VideoRendererHandlersOptions) {
    this.textures = options.textures;
    this.messenger = options.messenger;
    this.stateProvider = options.stateProvider;
    this.renders = options.renders;
    this.localStreams = options.localStreams;
    this.getStreamForId = options.getStreamForId;
    this.resultError = options.resultError;
  }

  /**
   * 创建视频渲染器并注册纹理与事件通道。
   * 关键路径包裹 try-catch，确保纹理/渲染器创建异常能传播到 Flutter 层而非丢失。
   * @param call 方法调用
   * @param result 回调句柄，返回 { textureId }
   */
  createVideoRenderer(call: MethodCall, result: MethodResult): void {
    try {
      let textureId: number = this.textures.getTextureId();
      let render: FlutterRTCVideoRenderer =
        new FlutterRTCVideoRenderer(textureId, this.stateProvider);
      Log.d(TAG, 'createVideoRenderer create FlutterRTCVideoRenderer !');
      this.renders.add(textureId, render);
      let eventChannel: EventChannel =
        new EventChannel(this.messenger, 'FlutterWebRTC/Texture' + textureId);
      eventChannel.setStreamHandler(render);
      render.setEventChannel(eventChannel);
      render.setId(textureId);
      let params: ConstraintsMap = new ConstraintsMap();
      params.putNumber('textureId', textureId);
      Log.d(TAG, 'createVideoRenderer result.success: ' + Array.from(params.toMap().entries()));
      result.success(params.toMap());
    } catch (error) {
      this.resultError(call.method, 'createVideoRenderer failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 释放指定视频渲染器并从 renders 移除。
   * 关键路径：dispose() 可能抛出异常，必须用 try-catch + finally 包裹，
   * 确保：①即使 dispose 失败渲染器仍从 Map 移除（避免泄漏）；②Flutter 端必定收到响应。
   * @param call 方法调用（参数：textureId）
   * @param result 回调句柄
   */
  videoRendererDispose(call: MethodCall, result: MethodResult): void {
    let textureId: number = call.argument('textureId');
    // 参数边界校验：textureId 必须为有效数字
    if (textureId === null || typeof textureId !== 'number' || isNaN(textureId)) {
      this.resultError('videoRendererDispose', 'invalid textureId', result);
      return;
    }
    Log.d(TAG, 'videoRendererDispose textureId= ' + textureId);
    let render: FlutterRTCVideoRenderer | undefined = this.renders.get(textureId);
    if (!render) {
      this.resultError('videoRendererDispose', `render [${textureId}] not found !`, result);
      return;
    }
    try {
      render.dispose();
      result.success(null);
    } catch (error) {
      this.resultError('videoRendererDispose', 'render.dispose failed: ' + JSON.stringify(error), result);
    } finally {
      // 无论 dispose 成功或失败，都必须从 Map 移除，避免渲染器泄漏滞留
      this.renders.remove(textureId);
    }
  }

  /**
   * 为渲染器设置视频源（流或轨道）。
   * @param call 方法调用（参数：textureId、surfaceId、streamId、ownerTag、trackId）
   * @param result 回调句柄
   */
  videoRendererSetSrcObject(call: MethodCall, result: MethodResult): void {
    let textureId: number = call.argument('textureId');
    let surfaceId: string = call.argument('surfaceId');
    let streamId: string = getStreamId(call);
    let ownerTag: string = call.argument('ownerTag');
    let trackId: string = getTrackId(call);

    // 参数边界校验：textureId 必须为有效数字
    if (textureId === null || typeof textureId !== 'number' || isNaN(textureId)) {
      this.resultError('videoRendererSetSrcObject', 'invalid textureId', result);
      return;
    }
    Log.d(TAG, 'videoRendererSetSrcObject textureId= ' + textureId);
    Log.d(TAG, 'videoRendererSetSrcObject streamId= ' + streamId);
    Log.d(TAG, 'videoRendererSetSrcObject ownerTag= ' + ownerTag);
    Log.d(TAG, 'videoRendererSetSrcObject trackId= ' + trackId);
    Log.d(TAG, 'videoRendererSetSrcObject surfaceId= ' + surfaceId);

    let videoRender: FlutterRTCVideoRenderer | undefined = this.renders.get(textureId);
    if (!videoRender) {
      this.resultError('videoRendererSetSrcObject', `videoRender [${textureId}] not found !`, result);
      return;
    }
    // 关键路径包裹 try-catch：videoRender.init() / setStream() 可能抛出异常，
    // 必须捕获并通过 resultError 传播到 Flutter，避免错误丢失导致 Future 挂起。
    try {
      // An empty stream id is the Flutter-side representation of srcObject=null.
      // Detach it before validating the SurfaceTexture; teardown can happen after the
      if (streamId === null || streamId === '') {
        videoRender.setStream(null, ownerTag);
        result.success(null);
        return;
      }
      if (!surfaceId) {
        this.resultError('videoRendererSetSrcObject', `videoRender surfaceId not found !`, result);
        return;
      }
      if (surfaceId !== '' && videoRender.getSurfaceId() !== surfaceId) {
        videoRender.init(surfaceId);
      }
      this.applyStreamToRenderer(videoRender, streamId, ownerTag, trackId);
      result.success(null);
    } catch (error) {
      this.resultError('videoRendererSetSrcObject',
        'setSrcObject failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 按 ownerTag 解析目标 MediaStream 并设置到渲染器。
   * 本地流从 localStreams 缓存读取，远端流委托 getStreamForId；
   * 携带 trackId 时走单轨道绑定分支，否则绑定整个流。
   * @param videoRender 目标渲染器
   * @param streamId 流 id
   * @param ownerTag 流归属标签（'local' 或 PeerConnectionId）
   * @param trackId 轨道 id（为 null/'0' 表示绑定整流）
   */
  private applyStreamToRenderer(videoRender: FlutterRTCVideoRenderer, streamId: string,
    ownerTag: string, trackId: string): void {
    let stream: MediaStream | null;
    if (ownerTag === 'local') {
      stream = this.localStreams.get(streamId);
    } else {
      stream = this.getStreamForId(streamId, ownerTag);
    }
    if (trackId !== null && trackId !== '0') {
      videoRender.setStream(stream, ownerTag, trackId);
    } else {
      videoRender.setStream(stream, ownerTag);
    }
  }
}
