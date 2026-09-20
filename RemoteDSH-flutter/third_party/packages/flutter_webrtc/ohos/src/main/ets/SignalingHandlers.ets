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
import {
  RTCPeerConnection,
  RTCSdpType,
  RTCSessionDescription,
  RTCSessionDescriptionInit,
  RTCIceCandidateInit,
  RTCConfiguration,
} from 'libohos_webrtc.so';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataMap, ObjectType } from './utils/ObjectType';
import {
  getCandidateMap,
  getConstraintsMap,
  getDescriptionMap,
  getTrackId,
  getConfigurationMap,
  getPeerConnectionId,
} from './utils/CallUtils';
import PeerConnectionObserver from './PeerConnectionObserver';

const TAG: string = 'FlutterWebRTCPlugin-SignalingHandlers';

/**
 * 信令相关方法集合（SDP 协商、候选者、统计、状态查询）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调获取 PeerConnection /
 * PeerConnectionObserver、错误回传与 RTC 配置解析，与原实现保持等价行为。
 */
export class SignalingHandlers {
  private getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null;
  private getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private parseRTCConfiguration: (map: ConstraintsMap) => RTCConfiguration;

  /**
   * 构信任令处理器：注入 PeerConnection/PCO 获取器、错误回传与 RTC 配置解析回调。
   */
  constructor(getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null,
    getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null,
    resultError: (method: string, error: string, result: MethodResult) => void,
    parseRTCConfiguration: (map: ConstraintsMap) => RTCConfiguration) {
    this.getPeerConnection = getPeerConnection;
    this.getPCO = getPCO;
    this.resultError = resultError;
    this.parseRTCConfiguration = parseRTCConfiguration;
  }

  /**
   * 创建 Offer SDP。
   * @param call 方法调用（参数：constraints）
   * @param result 回调句柄，返回 { sdp, type }
   */
  createOffer(call: MethodCall, result: MethodResult): void {
    try {
      let constraintsMap: ConstraintsMap = getConstraintsMap(call);
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      peerConnection.createOffer()
        .then((data: RTCSessionDescriptionInit) => {
          Log.d(TAG, `[createOffer] full SDP:\n${data.sdp}`);
          let params: DataMap = new Map();
          params.set('sdp', data.sdp ?? null);
          params.set('type', data.type);
          result.success(params);
        })
        .catch((error: BusinessError) => {
          this.resultError(
            call.method,
            'peerConnection.createOffer catch: ' + JSON.stringify(error),
            result
          );
        });
    } catch (error) {
      this.resultError(call.method, 'createOffer failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 创建 Answer SDP。
   * @param call 方法调用（参数：constraints）
   * @param result 回调句柄，返回 { sdp, type }
   */
  createAnswer(call: MethodCall, result: MethodResult): void {
    try {
      let constraintsMap: ConstraintsMap = getConstraintsMap(call);
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      peerConnection.createAnswer()
        .then((data: RTCSessionDescriptionInit) => {
          Log.d(TAG, `[createAnswer] full SDP:\n${data.sdp}`);
          let map: DataMap = new Map();
          map.set('sdp', data.sdp ?? null);
          map.set('type', data.type);
          result.success(map);
        })
        .catch((error: BusinessError) => {
          this.resultError(
            call.method,
            'peerConnection.createAnswer catch: ' + JSON.stringify(error),
            result
          );
        });
    } catch (error) {
      this.resultError(call.method, 'createAnswer failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置本地描述（LocalDescription）。
   * @param call 方法调用（参数：sdp、type）
   * @param result 回调句柄
   */
  setLocalDescription(call: MethodCall, result: MethodResult): void {
    try {
      let peerConnection: RTCPeerConnection | null = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let descriptionMap: ConstraintsMap = getDescriptionMap(call);
      let sdp: string = descriptionMap.getString('sdp');
      // 参数边界校验：sdp 与 type 为必填，缺失或空串时显式回错，避免底层收到非法输入
      if (!sdp || sdp.length === 0) {
        this.resultError(call.method, 'sdp is required and cannot be empty', result);
        return;
      }
      let typeRaw: string = descriptionMap.getString('type');
      if (!typeRaw || typeRaw.length === 0) {
        this.resultError(call.method, 'type is required and cannot be empty', result);
        return;
      }
      let type: RTCSdpType | null = this.parseSdpType(typeRaw);
      if (!type) {
        this.resultError(call.method, `unsupported SDP type: ${typeRaw}`, result);
        return;
      }
      let hasH264: boolean = sdp.includes('H264') || sdp.includes('h264');
      Log.d(TAG, `[setLocalDescription] type=${type}, SDP contains H264: ${hasH264}`);
      Log.d(TAG, `[setLocalDescription] full SDP:\n${sdp}`);
      let sdpInit: RTCSessionDescriptionInit = {
        sdp: sdp, type: type
      };
      peerConnection.setLocalDescription(sdpInit)
        .then(() => {
          result.success(null);
        })
        .catch((error: BusinessError) => {
          this.resultError(
            call.method,
            'peerConnection.setLocalDescription catch: ' + JSON.stringify(error),
            result);
        });
    } catch (error) {
      this.resultError(call.method, 'setLocalDescription failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置远端描述（RemoteDescription）。
   * @param call 方法调用（参数：sdp、type）
   * @param result 回调句柄
   */
  setRemoteDescription(call: MethodCall, result: MethodResult): void {
    try {
      let peerConnection: RTCPeerConnection | null = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let descriptionMap: ConstraintsMap = getDescriptionMap(call);
      let sdp: string = descriptionMap.getString('sdp');
      // 参数边界校验：sdp 与 type 为必填，缺失或空串时显式回错，避免底层收到非法输入
      if (!sdp || sdp.length === 0) {
        this.resultError(call.method, 'sdp is required and cannot be empty', result);
        return;
      }
      let typeRaw: string = descriptionMap.getString('type');
      if (!typeRaw || typeRaw.length === 0) {
        this.resultError(call.method, 'type is required and cannot be empty', result);
        return;
      }
      let type: RTCSdpType | null = this.parseSdpType(typeRaw);
      if (!type) {
        this.resultError(call.method, `unsupported SDP type: ${typeRaw}`, result);
        return;
      }
      let sdpInit: RTCSessionDescriptionInit = {
        sdp: sdp, type: type
      };
      peerConnection.setRemoteDescription(sdpInit)
        .then(() => {
          result.success(null);
        })
        .catch((error: BusinessError) => {
          this.resultError(
            call.method,
            'peerConnection.setRemoteDescription catch: ' + JSON.stringify(error),
            result);
        });
    } catch (error) {
      this.resultError(call.method, 'setRemoteDescription failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 校验并收窄 Flutter 传入的 SDP type。
   * @param value Flutter 传入的 SDP type 字符串
   * @returns 合法的 RTCSdpType，非法值返回 null
   */
  private parseSdpType(value: string): RTCSdpType | null {
    if (value === 'offer' || value === 'answer' || value === 'pranswer' || value === 'rollback') {
      return value;
    }
    return null;
  }

  /**
   * 添加 ICE 候选者。
   * @param call 方法调用（参数：candidate、sdpMid、sdpMLineIndex）
   * @param result 回调句柄，成功返回 true
   */
  addCandidate(call: MethodCall, result: MethodResult): void {
    try {
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let candidateMap: ConstraintsMap = getCandidateMap(call);
      let sdpMLineIndex: number = 0;
      if (candidateMap.getType('sdpMLineIndex') === ObjectType.NUMBER) {
        sdpMLineIndex = candidateMap.getNumber('sdpMLineIndex');
      }
      let candidate: RTCIceCandidateInit = {
        sdpMid: candidateMap.getString('sdpMid'),
        sdpMLineIndex: sdpMLineIndex,
        candidate: candidateMap.getString('candidate')
      };
      peerConnection.addIceCandidate(candidate).then(() => {
        result.success(true);
      }).catch((error: BusinessError) => {
        this.resultError(call.method, 'addIceCandidate failed: ' + JSON.stringify(error), result);
      });
    } catch (error) {
      this.resultError(call.method, 'addCandidate failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取 PeerConnection 统计信息。未指定 trackId 时返回整体统计，否则返回该轨道统计。
   * @param call 方法调用（参数：trackId 可选）
   * @param result 回调句柄，返回统计 Map
   */
  getStats(call: MethodCall, result: MethodResult): void {
    try {
      let trackId: string = getTrackId(call);
      let pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      if (trackId === '') {
        pco.getStats(result);
      } else {
        pco.getStatsForTrack(trackId, result);
      }
    } catch (error) {
      this.resultError(call.method, 'getStats failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取本地描述。
   * @param call 方法调用
   * @param result 回调句柄，返回 { sdp, type } 或 null
   */
  getLocalDescription(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let sdp: RTCSessionDescription | undefined = peerConnection.localDescription;
      if (!sdp) {
        result.success(null);
        return;
      }
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('sdp', sdp.sdp);
      params.putString('type', sdp.type);
      result.success(params.toMap());
    } catch (error) {
      this.resultError(call.method, 'getLocalDescription failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取远端描述。
   * @param call 方法调用
   * @param result 回调句柄，返回 { sdp, type } 或 null
   */
  getRemoteDescription(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let sdp: RTCSessionDescription | undefined = peerConnection.remoteDescription;
      if (!sdp) {
        result.success(null);
        return;
      }
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('sdp', sdp.sdp);
      params.putString('type', sdp.type);
      result.success(params.toMap());
    } catch (error) {
      this.resultError(call.method, 'getRemoteDescription failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 更新 PeerConnection 配置。
   * @param call 方法调用（参数：configuration）
   * @param result 回调句柄
   */
  setConfiguration(call: MethodCall, result: MethodResult): void {
    try {
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let configurationMap: ConstraintsMap = getConfigurationMap(call);
      peerConnection.setConfiguration(this.parseRTCConfiguration(configurationMap));
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'setConfiguration failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询信令状态。
   * @param call 方法调用
   * @param result 回调句柄，返回 { state }
   */
  getSignalingState(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let params: DataMap = new Map();
      params.set('state', normalizeStateString(peerConnection.signalingState));
      result.success(params);
    } catch (error) {
      this.resultError(call.method, 'getSignalingState failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询 ICE 收集状态。
   * @param call 方法调用
   * @param result 回调句柄，返回 { state }
   */
  getIceGatheringState(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let params: DataMap = new Map();
      params.set('state', normalizeStateString(peerConnection.iceGatheringState));
      result.success(params);
    } catch (error) {
      this.resultError(call.method, 'getIceGatheringState failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询 ICE 连接状态。
   * @param call 方法调用
   * @param result 回调句柄，返回 { state }
   */
  getIceConnectionState(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let params: DataMap = new Map();
      params.set('state', normalizeStateString(peerConnection.iceConnectionState));
      result.success(params);
    } catch (error) {
      this.resultError(call.method, 'getIceConnectionState failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询 PeerConnection 连接状态。
   * @param call 方法调用
   * @param result 回调句柄，返回 { state }
   */
  getConnectionState(call: MethodCall, result: MethodResult): void {
    try {
      if (!this.requirePeerConnectionId(call, result)) {
        return;
      }
      const peerConnection = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      let params: DataMap = new Map();
      params.set('state', normalizeStateString(peerConnection.connectionState));
      result.success(params);
    } catch (error) {
      this.resultError(call.method, 'getConnectionState failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 校验 peerConnectionId 非空：状态查询方法仅依赖 peerConnectionId 定位 PeerConnection，
   * 显式拒绝空串避免底层 HashMap 以空键查询的潜在问题。
   * @param call 方法调用
   * @param result 回调句柄
   * @returns 校验通过返回 true，失败（已回错）返回 false
   */
  private requirePeerConnectionId(call: MethodCall, result: MethodResult): boolean {
    let peerConnectionId: string = getPeerConnectionId(call);
    if (!peerConnectionId || peerConnectionId.length === 0) {
      this.resultError(call.method, 'peerConnectionId is required', result);
      return false;
    }
    return true;
  }
}

/**
 * 将 native 连接/信令状态值显式收窄为字符串。
 * native 各状态属性为字符串字面量联合类型（如 "stable"/"connected"），
 * 此处统一通过 String() 归一化，保证 Dart 侧收到的是可预期的字符串而非透传枚举。
 * @param state native 状态值
 * @returns 归一化后的字符串状态
 */
function normalizeStateString(state: string): string {
  return state ? String(state) : '';
}
