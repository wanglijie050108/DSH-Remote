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
 
// 1. 系统/Kit 导入
import { Log, MethodCall, MethodResult } from '@ohos/flutter_ohos';
// 2. 第三方库导入
import { AudioSource, MediaStreamTrack } from 'libohos_webrtc.so';
// 3. 本地模块导入
import AudioSwitchManager from './audio/AudioSwitchManager';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { getConfigurationMap, getPeerConnectionId, getTrackId } from './utils/CallUtils';

const TAG: string = 'FlutterWebRTCPlugin-MethodCallHandlerImpl';

/**
 * 音频相关方法处理器：从 MethodCallHandlerImpl 抽取的音频设备/静音/扬声器等接口实现。
 * 逻辑与原实现完全一致，仅做物理拆分以降低主类复杂度。
 */
export default class AudioMethodHandlers {
  private getTrackForIdFn: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null;
  private getAudioSourceForTrackFn: (trackId: string) => AudioSource | null;
  private resultErrorFn: (method: string, error: string, result?: MethodResult) => void;

  /**
   * 构造音频方法处理器：注入轨道查找、音频源查找与错误回调。
   */
  constructor(getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null,
              getAudioSourceForTrack: (trackId: string) => AudioSource | null,
              resultError: (method: string, error: string, result?: MethodResult) => void) {
    this.getTrackForIdFn = getTrackForId;
    this.getAudioSourceForTrackFn = getAudioSourceForTrack;
    this.resultErrorFn = resultError;
  }

  /** Resolves an audio track through the host state. */
  getTrackForId(trackId: string, peerConnectionId?: string): MediaStreamTrack | null {
    return this.getTrackForIdFn(trackId, peerConnectionId);
  }

  /** Resolves the native audio source associated with a track. */
  getAudioSourceForTrack(trackId: string): AudioSource | null {
    return this.getAudioSourceForTrackFn(trackId);
  }

  /** Propagates an audio method failure to Flutter. */
  resultError(method: string, error: string, result?: MethodResult): void {
    this.resultErrorFn(method, error, result);
  }

  /**
   * 设置指定音频轨道的音量。
   * @param call 方法调用（参数：trackId、volume）
   * @param result 回调句柄
   */
  setVolume(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      let peerConnectionId: string = getPeerConnectionId(call);
      let volume: number = call.argument('volume') ?? -1;
      // 校验 volume 为有效数值且落在合理范围 [0, 1]
      if (typeof volume !== 'number' || isNaN(volume) || volume < 0 || volume > 1) {
        this.resultError('setVolume', 'volume must be a number in range [0, 1]', result);
        return;
      }
      let ok: boolean = this.mediaStreamTrackSetVolume(trackId, volume, peerConnectionId);
      if (!ok) {
        this.resultError('setVolume', 'setVolume failed for track: ' + trackId, result);
        return;
      }
      result.success(null);
    } catch (error) {
      this.resultError('setVolume', 'setVolume failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 选择音频输出设备。
   * @param call 方法调用（参数：deviceId）
   * @param result 回调句柄
   */
  selectAudioOutput(call: MethodCall, result: MethodResult): void {
    try {
      let deviceId: string = call.argument('deviceId');
      if (!deviceId || deviceId.length === 0) {
        this.resultError('selectAudioOutput', 'deviceId is required', result);
        return;
      }
      let parsedId: number = parseInt(deviceId, 10);
      if (isNaN(parsedId)) {
        this.resultError('selectAudioOutput', 'deviceId must be a number', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.selectAudioOutput(parsedId);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'selectAudioOutput failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置麦克风静音状态。
   * @param call 方法调用（参数：mute）
   * @param result 回调句柄
   */
  setMicrophoneMute(call: MethodCall, result: MethodResult): void {
    try {
      let mute: boolean = call.argument('mute');
      // 校验 mute 参数为布尔类型
      if (typeof mute !== 'boolean') {
        this.resultError('setMicrophoneMute', 'mute must be a boolean', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.setMicrophoneMute(mute);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'setMicrophoneMute failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 选择音频输入设备（对应 Dart 层 Helper.selectAudioInput）。
   * 通过 AudioRoutingManager 的输入设备列表按 deviceId 定位设备并切换通信设备。
   * @param call 方法调用（参数：deviceId）
   * @param result 回调句柄
   */
  selectAudioInput(call: MethodCall, result: MethodResult): void {
    try {
      let deviceId: string = call.argument('deviceId') ?? '';
      if (!deviceId || deviceId.length === 0) {
        this.resultError('selectAudioInput', 'deviceId is required', result);
        return;
      }
      let parsedId: number = parseInt(deviceId, 10);
      if (isNaN(parsedId)) {
        this.resultError('selectAudioInput', 'deviceId must be a number', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.selectAudioInput(parsedId);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'selectAudioInput failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置 OHOS 音频配置（流用途、采集源等）。
   * @param call 方法调用（参数：configuration）
   * @param result 回调句柄
   */
  setOhosAudioConfiguration(call: MethodCall, result: MethodResult): void {
    try {
      let configuration: ConstraintsMap = getConfigurationMap(call);
      if (!configuration) {
        this.resultError(call.method, 'configuration is required', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.setAudioConfiguration(configuration);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'setOhosAudioConfiguration failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 启用/禁用扬声器。
   * @param call 方法调用（参数：enable）
   * @param result 回调句柄
   */
  enableSpeakerphone(call: MethodCall, result: MethodResult): void {
    try {
      let enable: boolean = call.argument('enable');
      // 参数运行时类型验证：enable 必须为布尔值，防止非法类型透传到原生层
      if (typeof enable !== 'boolean') {
        this.resultError('enableSpeakerphone', 'enable must be a boolean', result);
        return;
      }
      AudioSwitchManager.getExistingInstance()?.enableSpeakerphone(enable);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'enableSpeakerphone failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 确保 iOS 音频会话激活。OHOS 无此概念（音频会话由 AudioSwitchManager 统一管理），
   * 此处为 no-op 平台适配：返回 success，避免 Dart 端 NativeAudioManagement.ensureAudioSession()
   * 在 OHOS 上因 handler 缺失触发 MissingPluginException。
   * @param call 方法调用
   * @param result 回调句柄
   */
  ensureAudioSession(call: MethodCall, result: MethodResult): void {
    result.success(null);
  }

  /**
   * 启用扬声器但优先选择蓝牙/有线耳机。
   * @param call 方法调用
   * @param result 回调句柄
   */
  enableSpeakerphoneButPreferBluetooth(call: MethodCall, result: MethodResult): void {
    try {
      AudioSwitchManager.getExistingInstance()?.enableSpeakerButPreferBluetooth();
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'enableSpeakerphoneButPreferBluetooth failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置扬声器静音状态。
   * @param call 方法调用（参数：mute）
   * @param result 回调句柄，返回操作是否执行
   */
  setSpeakerMute(call: MethodCall, result: MethodResult): void {
    try {
      let mute: boolean = call.argument('mute') ?? false;
      // 参数运行时类型验证：mute 必须为布尔值
      if (typeof mute !== 'boolean') {
        this.resultError('setSpeakerMute', 'mute must be a boolean', result);
        return;
      }
      let manager: AudioSwitchManager | null = AudioSwitchManager.getExistingInstance();
      if (!manager) {
        this.resultError('setSpeakerMute', 'AudioSwitchManager not initialized', result);
        return;
      }
      result.success(manager.setSpeakerMute(mute));
    } catch (error) {
      this.resultError(call.method, 'setSpeakerMute failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 启用/禁用降噪。
   * @param call 方法调用（参数：enabled）
   * @param result 回调句柄，返回操作是否成功
   */
  setNoiseSuppressorEnabled(call: MethodCall, result: MethodResult): void {
    try {
      let enabled: boolean = call.argument('enabled') ?? false;
      // 参数运行时类型验证：enabled 必须为布尔值
      if (typeof enabled !== 'boolean') {
        this.resultError('setNoiseSuppressorEnabled', 'enabled must be a boolean', result);
        return;
      }
      let manager: AudioSwitchManager | null = AudioSwitchManager.getExistingInstance();
      if (!manager) {
        this.resultError('setNoiseSuppressorEnabled', 'AudioSwitchManager not initialized', result);
        return;
      }
      result.success(manager.setNoiseSuppressorEnabled(enabled));
    } catch (error) {
      this.resultError(call.method, 'setNoiseSuppressorEnabled failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询是否支持内置回声消除（AEC）。
   * @param call 方法调用
   * @param result 回调句柄，返回是否支持
   */
  isBuiltInAcousticEchoCancelerSupported(call: MethodCall, result: MethodResult): void {
    try {
      let manager: AudioSwitchManager | null = AudioSwitchManager.getExistingInstance();
      if (!manager) {
        this.resultError('isBuiltInAcousticEchoCancelerSupported',
          'AudioSwitchManager not initialized', result);
        return;
      }
      result.success(manager.isBuiltInAcousticEchoCancelerSupported());
    } catch (error) {
      this.resultError(call.method,
        'isBuiltInAcousticEchoCancelerSupported failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询是否支持内置降噪（NS）。
   * @param call 方法调用
   * @param result 回调句柄，返回是否支持
   */
  isBuiltInNoiseSuppressorSupported(call: MethodCall, result: MethodResult): void {
    try {
      let manager: AudioSwitchManager | null = AudioSwitchManager.getExistingInstance();
      if (!manager) {
        this.resultError('isBuiltInNoiseSuppressorSupported',
          'AudioSwitchManager not initialized', result);
        return;
      }
      result.success(manager.isBuiltInNoiseSuppressorSupported());
    } catch (error) {
      this.resultError(call.method,
        'isBuiltInNoiseSuppressorSupported failed: ' + JSON.stringify(error), result);
    }
  }

  /** Applies a normalized volume to the audio source behind a track. Returns success status. */
  mediaStreamTrackSetVolume(id: string, volume: number, peerConnectionId: string): boolean {
    let track: MediaStreamTrack | null = this.getTrackForId(id, peerConnectionId);
    if (!track) {
      Log.w(TAG, 'setVolume(): track not found: ' + id);
      return false;
    }
    // 仅音频轨道可设置音量；视频轨道忽略（与 Android/iOS 一致）
    if (track.kind === 'video') {
      Log.w(TAG, 'setVolume(): track is not audio: ' + id);
      return false;
    }
    // OHOS WebRTC 音量设置 API 位于 AudioSource.setVolume，
    // 通过 trackId 查找创建音频轨道时缓存的 AudioSource 并设置实际音量。
    let audioSource: AudioSource | null = this.getAudioSourceForTrack(id);
    if (!audioSource) {
      Log.w(TAG, 'setVolume(): audioSource not found for track: ' + id);
      return false;
    }
    try {
      audioSource.setVolume(volume);
      Log.d(TAG, 'setVolume(): ' + id + ',' + volume);
      return true;
    } catch (error) {
      Log.e(TAG, 'setVolume(): setVolume failed: ' + JSON.stringify(error));
      return false;
    }
  }
}
