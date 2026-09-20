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
import { MediaStreamTrack, RTCRtpCapabilities, RTCRtpReceiver, RTCRtpSender } from 'libohos_webrtc.so';
import { DataMap } from './utils/ObjectType';
import { capabilitiesToMap } from './utils/PCOUtils';
import { getPeerConnectionId, getTrackId } from './utils/CallUtils';
import { isNotEmpty } from './utils/Utils';
import AudioSwitchManager from './audio/AudioSwitchManager';

const TAG: string = 'FlutterWebRTCPlugin-CapabilityMiscHandlers';

/**
 * 编解码能力查询与暂不支持特性（录制/帧捕获/偏好输入设备）相关方法集合。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调，与原实现保持等价行为。
 */
export class CapabilityMiscHandlers {
  private getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;

  /**
   * 构能力查询处理器：注入轨道查找与错误回调，处理编解码能力查询与平台限制桩方法。
   */
  constructor(getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null,
    resultError: (method: string, error: string, result: MethodResult) => void) {
    this.getTrackForId = getTrackForId;
    this.resultError = resultError;
  }

  /**
   * 平台不支持功能的统一错误返回：错误码使用 'notSupported'，
   * 与接口规格说明及 Flutter PlatformException(notSupported) 约定对齐，
   * 区别于核心方法运行时异常使用的 'WEBRTC_ERROR'。
   * @param method 方法名
   * @param error 错误描述
   * @param result 回调句柄
   */
  private resultNotSupported(method: string, error: string, result: MethodResult): void {
    let errorMsg: string = `${method}(): ${error}`;
    Log.e(TAG, errorMsg);
    result.error('notSupported', errorMsg, new Map<string, string>([['method', method]]));
  }

  /**
   * 设置偏好音频输入设备（对应 Dart 层 setPreferredInputDevice）。
   * 通过 AudioRoutingManager 的输入设备列表按 deviceId 定位设备并切换通信设备，
   * 与 selectAudioInput 共用底层 selectAudioInput 实现。
   * @param call 方法调用（参数：deviceId）
   * @param result 回调句柄
   */
  setPreferredInputDevice(call: MethodCall, result: MethodResult): void {
    try {
      let deviceId: string = call.argument('deviceId') ?? '';
      if (!deviceId || deviceId.length === 0) {
        this.resultError('setPreferredInputDevice', 'deviceId is required', result);
        return;
      }
      let parsedId: number = parseInt(deviceId, 10);
      if (isNaN(parsedId)) {
        this.resultError('setPreferredInputDevice', 'deviceId must be a number', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.selectAudioInput(parsedId);
      result.success(null);
    } catch (error) {
      this.resultError('setPreferredInputDevice', 'setPreferredInputDevice failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取指定媒体类型的 RTP Sender 能力（编解码器列表）。
   * @param call 方法调用（参数：kind）
   * @param result 回调句柄，返回能力 Map
   */
  getRtpSenderCapabilities(call: MethodCall, result: MethodResult): void {
    try {
      let kind: string = call.argument('kind') ?? '';
      let mediaType: string = kind === 'video' ? 'video' : 'audio';
      let capabilities: RTCRtpCapabilities | null = RTCRtpSender.getCapabilities(mediaType);
      if (capabilities) {
        Log.d(TAG, `[getRtpSenderCapabilities] kind=${mediaType}, codecs count=${capabilities.codecs.length}`);
        for (let codec of capabilities.codecs) {
          Log.d(TAG, `[getRtpSenderCapabilities]   codec: mimeType=${codec.mimeType},` +
            ` payloadType=${codec.payloadType}, clockRate=${codec.clockRate}`);
        }
        let params: DataMap = capabilitiesToMap(capabilities);
        result.success(params);
      } else {
        Log.w(TAG, `[getRtpSenderCapabilities] kind=${mediaType}: returned null — no capabilities!`);
        this.resultError('getRtpSenderCapabilities', 'capabilities is null', result);
      }
    } catch (error) {
      this.resultError('getRtpSenderCapabilities', 'getRtpSenderCapabilities failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取指定媒体类型的 RTP Receiver 能力（编解码器列表）。
   * @param call 方法调用（参数：kind）
   * @param result 回调句柄，返回能力 Map
   */
  getRtpReceiverCapabilities(call: MethodCall, result: MethodResult): void {
    try {
      let kind: string = call.argument('kind') ?? '';
      let mediaType: string = kind === 'video' ? 'video' : 'audio';
      let capabilities: RTCRtpCapabilities | null = RTCRtpReceiver.getCapabilities(mediaType);
      if (capabilities) {
        let params: DataMap = capabilitiesToMap(capabilities);
        result.success(params);
      } else {
        this.resultError('getRtpReceiverCapabilities', 'capabilities is null', result);
      }
    } catch (error) {
      this.resultError('getRtpReceiverCapabilities',
        'getRtpReceiverCapabilities failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 开始录制到文件。OHOS WebRTC SDK 暂未提供录制 API，
   * 显式返回“不支持”，避免 Dart Future 挂起。
   * 错误码使用 'notSupported'（与接口规格说明及 Flutter PlatformException 约定对齐，
   * 区别于核心方法的 'WEBRTC_ERROR'）。
   * @param call 方法调用
   * @param result 回调句柄
   */
  startRecordToFile(call: MethodCall, result: MethodResult): void {
    try {
      this.resultNotSupported('startRecordToFile', 'Media recording is not supported on OHOS yet', result);
    } catch (error) {
      this.resultError('startRecordToFile', 'startRecordToFile failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 停止录制。OHOS WebRTC SDK 暂未提供录制 API，显式返回“不支持”，避免 Dart Future 挂起。
   * 错误码使用 'notSupported'（与接口规格说明对齐）。
   * @param call 方法调用
   * @param result 回调句柄
   */
  stopRecordToFile(call: MethodCall, result: MethodResult): void {
    try {
      this.resultNotSupported('stopRecordToFile', 'Media recording is not supported on OHOS yet', result);
    } catch (error) {
      this.resultError('stopRecordToFile', 'stopRecordToFile failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 捕获视频帧到文件。OHOS WebRTC SDK 暂未提供帧捕获 API，
   * 显式返回“不支持”，避免 Dart 层 Future 挂起。
   * @param call 方法调用（参数：trackId、path）
   * @param result 回调句柄
   */
  captureFrame(call: MethodCall, result: MethodResult): void {
    try {
      let videoTrackId: string = getTrackId(call);
      let peerConnectionId: string = getPeerConnectionId(call);
      let path: string = call.argument('path');
      Log.d(TAG, 'path:' + path + ', videoTrackId:' + videoTrackId + ', peerConnectionId:' + peerConnectionId);
      if (isNotEmpty(videoTrackId)) {
        let track: MediaStreamTrack | null = this.getTrackForId(videoTrackId, peerConnectionId);
        if (track && track.kind === 'video') {
          // 平台限制：帧捕获 API 在 OHOS 不可用，用 notSupported 错误码（与接口规格说明对齐）
          this.resultNotSupported('captureFrame', 'Frame capture is not supported on OHOS yet', result);
        } else {
          this.resultError('captureFrame', 'It\'s not video track', result);
        }
      } else {
        this.resultError('captureFrame', 'Track is null', result);
      }
    } catch (error) {
      this.resultError('captureFrame', 'captureFrame failed: ' + JSON.stringify(error), result);
    }
  }
}
