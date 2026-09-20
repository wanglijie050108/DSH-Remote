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
import { MediaStreamTrack } from 'libohos_webrtc.so';
import GetUserMediaImpl from './GetUserMediaImpl';
import { getPeerConnectionId, getTrackId } from './utils/CallUtils';

const TAG: string = 'FlutterWebRTCPlugin-TrackControlHandlers';

/**
 * 媒体轨道控制相关方法集合（启用/禁用、闪光灯、缩放、摄像头切换）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 getUserMediaImpl 引用与
 * getTrackForId / resultError 回调，与原实现保持等价行为。
 */
export class TrackControlHandlers {
  private getUserMediaImplGetter: () => GetUserMediaImpl | null;
  private getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;

  /**
   * 构造轨道控制处理器：注入 GetUserMediaImpl 获取器、轨道查找与错误回调。
   */
  constructor(getUserMediaImplGetter: () => GetUserMediaImpl | null,
    getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null,
    resultError: (method: string, error: string, result: MethodResult) => void) {
    this.getUserMediaImplGetter = getUserMediaImplGetter;
    this.getTrackForId = getTrackForId;
    this.resultError = resultError;
  }

  /**
   * 启用/禁用指定轨道。track 不存在或状态无变化时仍需回复 Flutter，避免 Future 挂起。
   * @param call 方法调用（参数：trackId、enabled、peerConnectionId）
   * @param result 回调句柄
   */
  mediaStreamTrackSetEnable(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamTrackSetEnable trackId= ' + trackId);
      let enabled: boolean = call.argument('enabled');
      Log.d(TAG, 'mediaStreamTrackSetEnable enabled= ' + enabled);
      if (typeof enabled !== 'boolean') {
        this.resultError('mediaStreamTrackSetEnable', 'enabled must be a boolean', result);
        return;
      }
      let peerConnectionId: string = getPeerConnectionId(call);
      Log.d(TAG, 'mediaStreamTrackSetEnable peerConnectionId= ' + peerConnectionId);

      let track: MediaStreamTrack | null = this.getTrackForId(trackId, peerConnectionId);
      if (track === null) {
        // track 不存在时必须回复 Flutter，否则 Future 挂起
        this.resultError('mediaStreamTrackSetEnable', 'track is null for id: ' + trackId, result);
        return;
      } else if (track.enabled === enabled) {
        // 状态无变化，仍需回复 success，避免 Future 挂起
        result.success(null);
        return;
      }
      track.enabled = enabled;
      result.success(null);
    } catch (error) {
      this.resultError('mediaStreamTrackSetEnable',
        'mediaStreamTrackSetEnable failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询指定轨道是否支持闪光灯。
   * @param call 方法调用（参数：trackId）
   * @param result 回调句柄
   */
  mediaStreamTrackHasTorch(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamTrackHasTorch trackId= ' + trackId);
      let impl: GetUserMediaImpl | null = this.getUserMediaImplGetter();
      if (impl) {
        Log.d(TAG, 'mediaStreamTrackHasTorch hasTorch in!');
        impl.hasTorch(trackId, result);
      } else {
        this.resultError('mediaStreamTrackHasTorch', 'getUserMediaImpl null !', result);
      }
    } catch (error) {
      this.resultError('mediaStreamTrackHasTorch', 'mediaStreamTrackHasTorch failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置指定轨道的闪光灯开关。
   * @param call 方法调用（参数：trackId、torch）
   * @param result 回调句柄
   */
  mediaStreamTrackSetTorch(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamTrackSetTorch trackId= ' + trackId);
      let torch: boolean = call.argument('torch');
      Log.d(TAG, 'mediaStreamTrackSetTorch torch= ' + torch);
      if (typeof torch !== 'boolean') {
        this.resultError('mediaStreamTrackSetTorch', 'torch must be a boolean', result);
        return;
      }
      let impl: GetUserMediaImpl | null = this.getUserMediaImplGetter();
      if (impl) {
        // 将 trackId 传递到实现层，便于按轨道定位摄像头进行闪光灯控制
        impl.setTorch(trackId, torch, result);
      } else {
        this.resultError('mediaStreamTrackSetTorch', 'getUserMediaImpl null !', result);
      }
    } catch (error) {
      this.resultError('mediaStreamTrackSetTorch', 'mediaStreamTrackSetTorch failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置指定轨道的相机缩放级别。
   * @param call 方法调用（参数：trackId、zoomLevel）
   * @param result 回调句柄
   */
  mediaStreamTrackSetZoom(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamTrackSetZoom trackId= ' + trackId);
      let zoomLevel: number = call.argument('zoomLevel');
      Log.d(TAG, 'mediaStreamTrackSetZoom zoomLevel= ' + zoomLevel);
      if (typeof zoomLevel !== 'number' || isNaN(zoomLevel)) {
        this.resultError('mediaStreamTrackSetZoom', 'zoomLevel must be a finite number', result);
        return;
      }
      let impl: GetUserMediaImpl | null = this.getUserMediaImplGetter();
      if (impl) {
        // 将 trackId 传递到实现层，便于按轨道定位摄像头进行缩放控制
        impl.setZoom(trackId, zoomLevel, result);
      } else {
        this.resultError('mediaStreamTrackSetZoom', 'getUserMediaImpl null !', result);
      }
    } catch (error) {
      this.resultError('mediaStreamTrackSetZoom', 'mediaStreamTrackSetZoom failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 切换指定轨道关联的摄像头（前/后置）。
   * @param call 方法调用（参数：trackId）
   * @param result 回调句柄
   */
  mediaStreamTrackSwitchCamera(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamTrackSwitchCamera trackId= ' + trackId);
      let impl: GetUserMediaImpl | null = this.getUserMediaImplGetter();
      if (impl) {
        // 将 trackId 传递到实现层，便于按轨道定位摄像头进行切换
        impl.switchCamera(trackId, result);
      } else {
        this.resultError('mediaStreamTrackSwitchCamera', 'getUserMediaImpl null !', result);
      }
    } catch (error) {
      this.resultError('mediaStreamTrackSwitchCamera',
        'mediaStreamTrackSwitchCamera failed: ' + JSON.stringify(error), result);
    }
  }
}
