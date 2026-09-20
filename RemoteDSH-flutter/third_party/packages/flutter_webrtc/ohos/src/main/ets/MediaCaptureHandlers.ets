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
 
import { Log, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { HashMap } from '@kit.ArkTS';
import {
  MediaStream,
  MediaStreamTrack,
  MediaStreamConstraints,
  MediaTrackConstraints,
  DisplayMediaStreamOptions,
  MediaDevices,
} from 'libohos_webrtc.so';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataMap } from './utils/ObjectType';
import { ObjectType } from './utils/ObjectType';
import { getConstraintsMap } from './utils/CallUtils';
import { PermissionsManager } from './utils/PermissionsManager';

const TAG: string = 'FlutterWebRTCPlugin-MediaCaptureHandlers';

/**
 * 媒体捕获相关方法集合（getUserMedia、getDisplayMedia、createLocalMediaStream、序列化）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调与共享的 localStreams 映射。
 */

/**
 * 媒体捕获处理器的依赖注入配置对象，避免构造函数参数数量超标。
 */
export interface MediaCaptureHandlersOptions {
  getMediaTrackConstraints: (videoOptionMap: DataMap) => MediaTrackConstraints;
  putLocalStream: (streamId: string, stream: MediaStream) => boolean;
  getNextStreamUUID: () => string;
  resultError: (method: string, error: string, result: MethodResult) => void;
  localStreams: HashMap<string, MediaStream>;
  localTracks: HashMap<string, MediaStreamTrack>;
}

export class MediaCaptureHandlers {
  private getMediaTrackConstraints: (videoOptionMap: DataMap) => MediaTrackConstraints;
  private putLocalStream: (streamId: string, stream: MediaStream) => boolean;
  private getNextStreamUUID: () => string;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private localStreams: HashMap<string, MediaStream>;
  private localTracks: HashMap<string, MediaStreamTrack>;

  /**
   * 构造媒体捕获处理器：注入媒体约束转换、本地流注册、UUID 生成与错误回调。
   */
  constructor(options: MediaCaptureHandlersOptions) {
    this.getMediaTrackConstraints = options.getMediaTrackConstraints;
    this.putLocalStream = options.putLocalStream;
    this.getNextStreamUUID = options.getNextStreamUUID;
    this.resultError = options.resultError;
    this.localStreams = options.localStreams;
    this.localTracks = options.localTracks;
  }

  /**
   * 获取用户媒体流（摄像头/麦克风）。先校验权限，再走 handleGetUserMedia。
   * @param call 方法调用（参数：audio/video 约束）
   * @param result 回调句柄
   */
  getUserMedia(call: MethodCall, result: MethodResult): void {
    let constraintsMap: ConstraintsMap = getConstraintsMap(call);
    if (!constraintsMap) {
      this.resultError(call.method, 'constraints is required', result);
      return;
    }
    PermissionsManager.getInstance().processPermissions(constraintsMap, (code: string | null, err: string | null) => {
      if (!code) {
        // 权限授予，继续获取媒体流
        this.handleGetUserMedia(constraintsMap, result);
      } else {
        // 权限拒绝：必须将错误传播到 Flutter 层，否则 Future 永远挂起导致界面冻结
        this.resultError('getUserMedia', err ?? code ?? 'Permission denied', result);
      }
    });
  }

  /**
   * 创建空本地媒体流并返回其 id。
   * @param call 方法调用
   * @param result 回调句柄，返回 { streamId }
   */
  createLocalMediaStream(call: MethodCall, result: MethodResult): void {
    try {
      let mediaStream: MediaStream = new MediaStream();
      let streamId: string = mediaStream.id;
      this.putLocalStream(streamId, mediaStream);
      let response: ConstraintsMap = new ConstraintsMap();
      response.putString('streamId', streamId);
      result.success(response.toMap());
    } catch (error) {
      this.resultError('createLocalMediaStream',
        `Failed to create local media stream: ${JSON.stringify(error)}`, result);
    }
  }

  /**
   * 请求媒体捕获权限。
   * @param call 方法调用（参数：audio/video 约束）
   * @param result 回调句柄，授权成功返回 true
   */
  requestCapturePermission(call: MethodCall, result: MethodResult): void {
    try {
      let constraintsMap: ConstraintsMap = getConstraintsMap(call);
      PermissionsManager.getInstance().processPermissions(constraintsMap, (code: string | null, err: string | null) => {
        if (code || err) {
          this.resultError('requestCapturePermission', err ?? code ?? 'unknown', result);
          return;
        }
        result.success(true);
      });
    } catch (error) {
      this.resultError('requestCapturePermission', `Unexpected error: ${JSON.stringify(error)}`, result);
    }
  }

  /**
   * 获取屏幕共享流。关键路径需包裹 try-catch，确保异常传播到 Flutter 层。
   * @param call 方法调用
   * @param result 回调句柄
   */
  async getDisplayMedia(call: MethodCall, result: MethodResult): Promise<void> {
    try {
      let constraints: ConstraintsMap = getConstraintsMap(call);
      let mediaOption: DisplayMediaStreamOptions = {};
      if (constraints.getType('audio') === ObjectType.BOOLEAN) {
        mediaOption.audio = constraints.getBoolean('audio');
      } else if (constraints.getType('audio') === ObjectType.MAP) {
        let audioOption: ConstraintsMap | null = constraints.getMap('audio');
        if (audioOption) {
          mediaOption.audio = this.getMediaTrackConstraints(audioOption.toMap());
        }
      }
      if (constraints.getType('video') === ObjectType.BOOLEAN) {
        mediaOption.video = constraints.getBoolean('video');
      } else if (constraints.getType('video') === ObjectType.MAP) {
        let videoOptionMap: ConstraintsMap | null = constraints.getMap('video');
        if (videoOptionMap) {
          mediaOption.video = this.getMediaTrackConstraints(videoOptionMap.toMap());
        }
      }

      Log.d(TAG, `getDisplayMedia mediaOption: ${JSON.stringify(mediaOption)}`);
      let mediaDevices: MediaDevices = new MediaDevices();
      let mediaStream: MediaStream = await mediaDevices.getDisplayMedia(mediaOption);
      // 先做 null 检查再访问 mediaStream.id，避免 use-before-check 风险
      if (!mediaStream) {
        this.resultError('getDisplayMedia', 'Failed to create new media stream', result);
        return;
      }
      let streamId: string = mediaStream.id ?? this.getNextStreamUUID();
      Log.d(TAG, 'getDisplayMedia mediaStream.id streamId= ' + streamId);

      let params: DataMap = this.serializeMediaStream(mediaStream);
      this.localStreams.set(mediaStream.id, mediaStream);
      result.success(params);
    } catch (error) {
      this.resultError('getDisplayMedia', `Failed to get display media: ${JSON.stringify(error)}`, result);
    }
  }

  /**
   * 获取用户媒体流的内部实现。关键路径需包裹 try-catch，
   * 确保权限拒绝、设备不可用、约束无效等异常能传播到 Flutter 层，
   * 而非丢失为未处理 Promise。
   * @param constraints 媒体约束
   * @param result 回调句柄
   */
  public async handleGetUserMedia(constraints: ConstraintsMap, result: MethodResult): Promise<void> {
    try {
      let mediaOption: MediaStreamConstraints = {};
      if (constraints.getType('audio') === ObjectType.BOOLEAN) {
        mediaOption.audio = constraints.getBoolean('audio');
      } else if (constraints.getType('audio') === ObjectType.MAP) {
        let audioOption: ConstraintsMap | null = constraints.getMap('audio');
        if (audioOption) {
          mediaOption.audio = this.getMediaTrackConstraints(audioOption.toMap());
        }
      }
      if (constraints.getType('video') === ObjectType.BOOLEAN) {
        mediaOption.video = constraints.getBoolean('video');
      } else if (constraints.getType('video') === ObjectType.MAP) {
        let videoOptionMap: ConstraintsMap | null = constraints.getMap('video');
        if (videoOptionMap) {
          mediaOption.video = this.getMediaTrackConstraints(videoOptionMap.toMap());
        }
      }

      Log.d(TAG, `handleGetUserMedia mediaOption: ${JSON.stringify(mediaOption)}`);
      let mediaDevices: MediaDevices = new MediaDevices();
      let userMedia: MediaStream = await mediaDevices.getUserMedia(mediaOption);

      let params: DataMap = this.serializeMediaStream(userMedia);
      this.localStreams.set(userMedia.id, userMedia);
      result.success(params);
    } catch (error) {
      this.resultError('getUserMedia', `Failed to get user media: ${JSON.stringify(error)}`, result);
    }
  }

  /**
   * 将 MediaStream 序列化为 Flutter 期望的 Map：含 streamId、videoTracks、audioTracks，
   * 并将轨道缓存到 localTracks。
   * @param mediaStream 媒体流
   * @returns 序列化后的参数 Map
   */
  public serializeMediaStream(mediaStream: MediaStream): DataMap {
    let params: DataMap = new Map();
    params.set('streamId', mediaStream.id);
    params.set('ownerTag', 'local');
    params.set('videoTracks', this.serializeTracks(mediaStream.getVideoTracks()));
    params.set('audioTracks', this.serializeTracks(mediaStream.getAudioTracks()));
    return params;
  }

  /**
   * 将一组轨道序列化为 DataMap 数组，并缓存到 localTracks。
   * @param tracks 轨道列表
   * @returns 序列化后的轨道 Map 数组
   */
  private serializeTracks(tracks: MediaStreamTrack[]): DataMap[] {
    let result: DataMap[] = [];
    for (let track of tracks) {
      let map: DataMap = new Map();
      map.set('enabled', track.enabled);
      map.set('id', track.id);
      map.set('kind', track.kind);
      map.set('label', track.id);
      map.set('readyState', track.readyState);
      map.set('remote', false);
      result.push(map);
      this.localTracks.set(track.id, track);
    }
    return result;
  }
}
