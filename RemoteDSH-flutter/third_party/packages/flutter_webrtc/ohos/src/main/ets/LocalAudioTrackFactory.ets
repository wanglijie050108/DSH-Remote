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
 
// 1. 系统 / Kit 导入
import { HashMap } from '@kit.ArkTS';
// 2. 第三方库导入
import { Log } from '@ohos/flutter_ohos';
import { AudioSource, AudioTrack, MediaStream, PeerConnectionFactory } from 'libohos_webrtc.so';
// 3. 本地模块导入
import AudioSwitchManager from './audio/AudioSwitchManager';
import StateProvider from './StateProvider';
import { ConstraintsArray } from './utils/ConstraintsArray';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { ObjectType } from './utils/ObjectType';

const TAG: string = 'FlutterWebRTCPlugin-LocalAudioTrackFactory';

/**
 * 从音频约束中解析 sourceId：优先取 deviceId，其次在 optional 数组中查找 sourceId。
 * @param mediaConstraints 音频约束 Map（可为 null）
 * @returns 解析到的 sourceId，无则返回空串
 */
function getSourceId(mediaConstraints: ConstraintsMap | null): string {
  if (mediaConstraints?.hasKey('deviceId')) {
    return mediaConstraints.getString('deviceId');
  }
  if (mediaConstraints?.getType('optional') === ObjectType.ARRAY) {
    let optional: ConstraintsArray | null = mediaConstraints.getArray('optional');
    if (optional) {
      for (let i = 0; i < optional.size(); i++) {
        if (optional.getType(i) === ObjectType.MAP) {
          let option: ConstraintsMap = new ConstraintsMap(optional.getMap(i));
          if (option.getType('sourceId') === ObjectType.STRING) {
            return option.getString('sourceId');
          }
        }
      }
    }
  }
  return '';
}

/**
 * 从媒体约束中解析音频输入 deviceId，无约束时回退为 '-1'。
 * @param constraints 媒体约束 Map
 * @returns deviceId 字符串
 */
function getDeviceId(constraints: ConstraintsMap): string {
  if (constraints.getType('audio') !== ObjectType.NULL) {
    return getSourceId(constraints.getMap('audio')) || '-1';
  }
  return '-1';
}

/**
 * 将音频轨道序列化为 Flutter 期望的 Map，含 settings 元数据。
 * @param track 音频轨道
 * @param deviceId 输入设备 id
 * @returns 序列化后的轨道参数 Map
 */
function trackToMap(track: AudioTrack, deviceId: string): ConstraintsMap {
  let trackParams: ConstraintsMap = new ConstraintsMap();
  trackParams.putBoolean('enabled', track.enabled);
  trackParams.putString('id', track.id);
  trackParams.putString('kind', 'audio');
  trackParams.putString('label', track.id);
  trackParams.putString('readyState', track.readyState.toString());
  trackParams.putBoolean('remote', false);
  let settings: ConstraintsMap = new ConstraintsMap();
  settings.putString('deviceId', deviceId);
  settings.putString('kind', 'audioinput');
  // 音频处理能力依据 ADM 实际硬件支持状态返回，而非硬编码 true，
  // 避免向上层谎报硬件不具备的 AEC / NS 能力。
  let echoCancellationSupported: boolean =
    AudioSwitchManager.getExistingInstance()?.isBuiltInAcousticEchoCancelerSupported() ?? false;
  let noiseSuppressionSupported: boolean =
    AudioSwitchManager.getExistingInstance()?.isBuiltInNoiseSuppressorSupported() ?? false;
  settings.putBoolean('autoGainControl', false);
  settings.putBoolean('echoCancellation', echoCancellationSupported);
  settings.putBoolean('noiseSuppression', noiseSuppressionSupported);
  settings.putNumber('channelCount', 1);
  settings.putNumber('latency', 0);
  trackParams.putMap('settings', settings.toMap());
  return trackParams;
}

/** Factory for creating, registering, and serializing local audio tracks. */
export class LocalAudioTrackFactory {
  /**
   * Creates a local audio track and records the corresponding AudioSource owner.
   * @param constraints media constraints supplied by Flutter
   * @param stream stream receiving the new track
   * @param stateProvider shared plugin state provider
   * @param audioSources track-to-source ownership map
   * @returns serialized track parameters, or an empty map when native creation fails
   */
  static create(constraints: ConstraintsMap, stream: MediaStream, stateProvider: StateProvider,
    audioSources: HashMap<string, AudioSource>): ConstraintsMap {
    let factory: PeerConnectionFactory = stateProvider.getPeerConnectionFactory();
    let audioSource: AudioSource = factory.createAudioSource();
    if (!audioSource) {
      Log.e(TAG, 'createAudioSource returned null');
      return new ConstraintsMap();
    }
    let track: AudioTrack = factory.createAudioTrack('audio', audioSource);
    if (!track) {
      Log.e(TAG, 'createAudioTrack returned null');
      return new ConstraintsMap();
    }
    stream.addTrack(track);
    stateProvider.putLocalTrack(track.id, track);
    audioSources.set(track.id, audioSource);
    AudioSwitchManager.getExistingInstance()?.start(`local:${track.id}`);
    return trackToMap(track, getDeviceId(constraints));
  }
}
