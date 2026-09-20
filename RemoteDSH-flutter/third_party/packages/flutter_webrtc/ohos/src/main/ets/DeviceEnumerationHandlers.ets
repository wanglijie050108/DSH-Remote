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
import { BusinessError } from '@ohos.base';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { ConstraintsArray } from './utils/ConstraintsArray';
import { DataArray, DataMap, ObjectType } from './utils/ObjectType';
import { camera } from '@kit.CameraKit';
import { audio } from '@kit.AudioKit';
import { MediaDevices, MediaDeviceInfo, MediaTrackConstraints } from 'libohos_webrtc.so';

const TAG: string = 'FlutterWebRTCPlugin-MethodCallHandlerImpl';

/**
 * 设备枚举与媒体约束处理器：从 MethodCallHandlerImpl 抽取的设备枚举、
 * 媒体约束转换、相机/音频设备信息构造等接口实现。
 * 逻辑与原实现完全一致，仅做物理拆分以降低主类复杂度。
 */
export default class DeviceEnumerationHandlers {
  /**
   * 将 Flutter 传入的约束 Map 转换为 OHOS MediaTrackConstraints。
   * @param videoOptionMap 源约束 Map
   * @returns 转换后的 MediaTrackConstraints
   */
  getMediaTrackConstraints(videoOptionMap: DataMap): MediaTrackConstraints {
    let videoOption: MediaTrackConstraints = {};
    // 标量约束字段：存在即拷贝
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'width');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'height');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'aspectRatio');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'frameRate');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'facingMode');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'resizeMode');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'sampleRate');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'sampleSize');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'echoCancellation');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'autoGainControl');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'noiseSuppression');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'latency');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'channelCount');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'groupId');
    this.copyConstraintIfPresent(videoOptionMap, videoOption, 'deviceId');
    // optional.sourceId 兼容旧约束格式
    this.applyOptionalSourceId(videoOptionMap, videoOption);
    return videoOption;
  }

  /**
   * 若 src 中存在 key，则将其拷贝到 dst 对应字段。
   * @param src 源约束 Map
   * @param dst 目标 MediaTrackConstraints
   * @param key 约束键名
   */
  private copyConstraintIfPresent(src: DataMap, dst: MediaTrackConstraints, key: string): void {
    let source: ConstraintsMap = new ConstraintsMap(src);
    if (!source.hasKey(key)) {
      return;
    }
    // 按值类型分组查找，降低圈复杂度：number / string / boolean 三组。
    let numericKeys: string[] = ['width', 'height', 'aspectRatio', 'frameRate',
      'sampleRate', 'sampleSize', 'latency', 'channelCount'];
    let stringKeys: string[] = ['facingMode', 'resizeMode', 'groupId', 'deviceId'];
    let booleanKeys: string[] = ['echoCancellation', 'autoGainControl', 'noiseSuppression'];

    if (numericKeys.indexOf(key) >= 0) {
      this.assignNumericConstraint(dst, key, source.getNumber(key));
    } else if (stringKeys.indexOf(key) >= 0) {
      this.assignStringConstraint(dst, key, source.getString(key));
    } else if (booleanKeys.indexOf(key) >= 0) {
      this.assignBooleanConstraint(dst, key, source.getBoolean(key));
    }
  }

  /**
   * 将数值类约束按 key 赋值到 MediaTrackConstraints 对应字段。
   * @param dst 目标约束对象
   * @param key 约束键名
   * @param value 数值
   */
  private assignNumericConstraint(dst: MediaTrackConstraints, key: string, value: number): void {
    if (key === 'width') {
      dst.width = value;
    } else if (key === 'height') {
      dst.height = value;
    } else if (key === 'aspectRatio') {
      dst.aspectRatio = value;
    } else if (key === 'frameRate') {
      dst.frameRate = value;
    } else if (key === 'sampleRate') {
      dst.sampleRate = value;
    } else if (key === 'sampleSize') {
      dst.sampleSize = value;
    } else if (key === 'latency') {
      dst.latency = value;
    } else if (key === 'channelCount') {
      dst.channelCount = value;
    }
  }

  /**
   * 将字符串类约束按 key 赋值到 MediaTrackConstraints 对应字段。
   * @param dst 目标约束对象
   * @param key 约束键名
   * @param value 字符串值
   */
  private assignStringConstraint(dst: MediaTrackConstraints, key: string, value: string): void {
    if (key === 'facingMode') {
      dst.facingMode = value;
    } else if (key === 'resizeMode') {
      dst.resizeMode = value;
    } else if (key === 'groupId') {
      dst.groupId = value;
    } else if (key === 'deviceId') {
      dst.deviceId = value;
    }
  }

  /**
   * 将布尔类约束按 key 赋值到 MediaTrackConstraints 对应字段。
   * @param dst 目标约束对象
   * @param key 约束键名
   * @param value 布尔值
   */
  private assignBooleanConstraint(dst: MediaTrackConstraints, key: string, value: boolean): void {
    if (key === 'echoCancellation') {
      dst.echoCancellation = value;
    } else if (key === 'autoGainControl') {
      dst.autoGainControl = value;
    } else if (key === 'noiseSuppression') {
      dst.noiseSuppression = value;
    }
  }

  /**
   * 处理旧格式 optional.sourceId，将其映射到 deviceId。
   * @param src 源约束 Map
   * @param dst 目标 MediaTrackConstraints
   */
  private applyOptionalSourceId(src: DataMap, dst: MediaTrackConstraints): void {
    let source: ConstraintsMap = new ConstraintsMap(src);
    let optionalList: ConstraintsArray | null = source.getArray('optional');
    if (!optionalList) {
      return;
    }
    for (let index: number = 0; index < optionalList.size(); index++) {
      if (optionalList.getType(index) === ObjectType.MAP) {
        let data: ConstraintsMap = new ConstraintsMap(optionalList.getMap(index));
        if (data.getType('sourceId') === ObjectType.STRING) {
          dst.deviceId = data.getString('sourceId');
        }
      }
    }
  }

  /**
   * 获取相机设备信息。
   * @param call Flutter 方法调用
   * @param result 用于返回设备列表或错误
   */
  getSources(call: MethodCall, result: MethodResult): void {
    try {
      let resultMap: DataMap = new Map();
      let mediaDevices: MediaDevices = new MediaDevices();
      mediaDevices.enumerateDevices().then((data: MediaDeviceInfo[]) => {
        Log.i(TAG, 'getUserMediaImpl.getSources : ' + JSON.stringify(data));
        let list: DataArray = [];
        for (let info of data) {
          let map: DataMap = new Map();
          map.set('deviceId', info.deviceId);
          map.set('groupId', info.deviceId);
          map.set('kind', info.kind);
          map.set('label', info.label);
          list.push(map);
        }
        resultMap.set('sources', list);
        result.success(resultMap);
      }).catch((error: BusinessError) => {
        // enumerateDevices 失败时必须将错误传播到 Flutter，否则 Future 挂起
        let errMsg: string = `getSources(): enumerateDevices failed: ${JSON.stringify(error)}`;
        Log.e(TAG, errMsg);
        result.error('getSources', `enumerateDevices failed: ${JSON.stringify(error)}`, null);
      });
    } catch (error) {
      let errMsg: string = `getSources failed: ${JSON.stringify(error)}`;
      Log.e(TAG, errMsg);
      result.error('getSources', errMsg, null);
    }
  }

  /**
   * Serializes one camera device for Flutter.
   * @param index device index used as the public identifier
   * @param camera native camera descriptor
   * @returns serialized camera properties
   */
  getCameraInfo(index: number, camera: camera.CameraDevice): ConstraintsMap {
    let params: ConstraintsMap = new ConstraintsMap();
    let facing: string = camera.cameraPosition === 2 ? 'front' : 'back';
    params.putString('label',
      'Camera ' + index + ', Facing ' + facing + ', Orientation ' + camera.cameraOrientation);
    params.putString('deviceId', '' + index);
    params.putString('facing', facing);
    params.putString('kind', 'videoinput');

    return params;
  }

  /**
   * Serializes one audio input device for Flutter.
   * @param audioDeviceDescriptor native audio input descriptor
   * @returns serialized input device properties
   */
  getAudioInputInfo(audioDeviceDescriptor: audio.AudioDeviceDescriptor): ConstraintsMap {
    let type: number = audioDeviceDescriptor.deviceType.valueOf();
    let label: string = audioDeviceDescriptor.name;
    let address: string = audioDeviceDescriptor.address;
    // ohos 麦克风 对应安卓 设备内置麦克风 AudioDeviceInfo.TYPE_BUILTIN_MIC
    if (audioDeviceDescriptor.deviceType === audio.DeviceType.MIC) {
      label = 'Built-in Microphone (' + address + ')';
    }

    // ohos 有线耳机，带麦克风。 对应安卓 有线耳机类型的音频设备
    if (audioDeviceDescriptor.deviceType === audio.DeviceType.WIRED_HEADSET) {
      label = 'Wired Headset';
    }
    // ohos 蓝牙设备SCO连接 对应安卓 蓝牙SCO协议连接的音频设备 AudioDeviceInfo.TYPE_BLUETOOTH_SCO
    // 在ohos中还有A2DP协议连接，这里先放一起 TODO 后面看是否需要修改
    if (audioDeviceDescriptor.deviceType === audio.DeviceType.BLUETOOTH_SCO ||
      audioDeviceDescriptor.deviceType === audio.DeviceType.BLUETOOTH_A2DP) {
      label = 'Bluetooth SCO (' + audioDeviceDescriptor.name + ')';
    }

    let audios: ConstraintsMap = new ConstraintsMap();
    audios.putString('label', label);
    audios.putString('deviceId', '' + audioDeviceDescriptor.id);
    audios.putString('groupId', '' + type);
    audios.putString('facing', '');
    audios.putString('kind', 'audioinput');

    return audios;
  }

  /**
   * Serializes one audio output device for Flutter.
   * @param audioDeviceDescriptor native audio output descriptor
   * @returns serialized output device properties
   */
  getAudioOutputInfo(audioDeviceDescriptor: audio.AudioDeviceDescriptor): ConstraintsMap {

    let audioOutputMap: ConstraintsMap = new ConstraintsMap();

    audioOutputMap.putString('label', audioDeviceDescriptor.name);
    audioOutputMap.putString('deviceId', '' + audioDeviceDescriptor.id);
    audioOutputMap.putString('facing', '');
    audioOutputMap.putString('kind', 'audiooutput');

    return audioOutputMap;
  }
}
