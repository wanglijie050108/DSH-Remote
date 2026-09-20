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
 
import { MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { HashMap } from '@kit.ArkTS';
import { MediaStream, MediaStreamTrack } from 'libohos_webrtc.so';
import PeerConnectionObserver from './PeerConnectionObserver';
import { DataArray, DataMap, MethodChannelValue, ObjectType } from './utils/ObjectType';
import { ConstraintsMap } from './utils/ConstraintsMap';
import {
  getDirection,
  getRtpSenderId,
  getSenderId,
  getStreamIds,
  getTrackId,
  getTransceiverId
} from './utils/CallUtils';

/**
 * RTP 收发器 / Sender / Receiver 相关方法集合。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调获取 PCO、
 * getMediaStreamTrack、resultError 与共享的 localStreams 映射，与原实现保持等价行为。
 */
export class RtpTransceiverHandlers {
  private getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null;
  private getMediaStreamTrack: (call: MethodCall, result: MethodResult) => MediaStreamTrack | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private localStreams: HashMap<string, MediaStream>;

  /**
   * 构造 RTP 收发器处理器：注入 PCO 获取器、轨道获取器、错误回调与本地流映射。
   */
  constructor(getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null,
    getMediaStreamTrack: (call: MethodCall, result: MethodResult) => MediaStreamTrack | null,
    resultError: (method: string, error: string, result: MethodResult) => void,
    localStreams: HashMap<string, MediaStream>) {
    this.getPCO = getPCO;
    this.getMediaStreamTrack = getMediaStreamTrack;
    this.resultError = resultError;
    this.localStreams = localStreams;
  }

  /**
   * 向 PeerConnection 添加轨道并关联指定流。
   * @param call 方法调用（参数：trackId、streamIds）
   * @param result 回调句柄
   */
  addTrack(call: MethodCall, result: MethodResult): void {
    try {
      let pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      let track: MediaStreamTrack | null = this.getMediaStreamTrack(call, result);
      if (!track) {
        return;
      }
      let streamIds: string[] = getStreamIds(call);
      let streams: MediaStream[] = [];
      for (let streamId of streamIds) {
        if (this.localStreams.hasKey(streamId)) {
          streams.push(this.localStreams.get(streamId));
        }
      }
      pco.addTrack(track, streams, result);
    } catch (error) {
      this.resultError('addTrack', 'addTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 从 PeerConnection 移除指定 Sender 的轨道。
   * @param call 方法调用（参数：senderId）
   * @param result 回调句柄
   */
  removeTrack(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.removeTrack(getSenderId(call), result);
    } catch (error) {
      this.resultError('removeTrack', 'removeTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 添加 RTP 收发器（基于 track 或 mediaType）。
   * @param call 方法调用（参数：trackId 或 mediaType、transceiverInit）
   * @param result 回调句柄，返回 transceiver Map
   */
  addTransceiver(call: MethodCall, result: MethodResult): void {
    try {
      const pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      let transceiverInit: DataMap = call.argument('transceiverInit');
      if (call.hasArgument('trackId')) {
        let track: MediaStreamTrack | null = this.getMediaStreamTrack(call, result);
        if (!track) {
          return;
        }
        let streams: MediaStream[] = this.resolveTransceiverStreams(transceiverInit, track);
        pco.addTransceiver(track, result, transceiverInit, streams);
      } else if (call.hasArgument('mediaType')) {
        let mediaType: string = call.argument('mediaType');
        pco.addTransceiver(mediaType, result, transceiverInit);
      } else {
        this.resultError(call.method, 'Incomplete parameters', result);
      }
    } catch (error) {
      this.resultError(call.method, 'addTransceiver failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 解析 addTransceiver 关联的媒体流：先取 init.streamIds 指定的流，
   * 再补全本地包含该 track 的流（去重）。
   * @param transceiverInit transceiver 初始化参数
   * @param track 关联的媒体轨道
   * @returns 关联的媒体流列表
   */
  private resolveTransceiverStreams(transceiverInit: DataMap, track: MediaStreamTrack): MediaStream[] {
    let streams: MediaStream[] = [];
    // 获取 flutter 层传下来的流
    let initMap: ConstraintsMap = new ConstraintsMap(transceiverInit);
    if (initMap.getType('streamIds') === ObjectType.ARRAY) {
      let streamIds: DataArray = initMap.getListArray('streamIds');
      streamIds.forEach((idValue: MethodChannelValue) => {
        if (typeof idValue === 'string' && this.localStreams.hasKey(idValue)) {
          streams.push(this.localStreams.get(idValue));
        }
      });
    }
    // 寻找附加的 track 所属的视频流（去重）
    this.localStreams.forEach((stream: MediaStream) => {
      if (stream?.getTracks().find((item: MediaStreamTrack) => item.id === track.id)) {
        if (!streams.find((item: MediaStream) => item.id === stream.id)) {
          streams.push(stream);
        }
      }
    });
    return streams;
  }

  /**
   * 设置 transceiver 方向。
   * @param call 方法调用（参数：peerConnectionId、transceiverId、direction）
   * @param result 调用结果
   */
  rtpTransceiverSetDirection(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.rtpTransceiverSetDirection(getDirection(call), getTransceiverId(call), result);
    } catch (error) {
      this.resultError('rtpTransceiverSetDirection',
        'rtpTransceiverSetDirection failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询 transceiver 方向。
   * @param call 方法调用（参数：peerConnectionId、transceiverId）
   * @param result 调用结果
   */
  rtpTransceiverGetDirection(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.rtpTransceiverGetDirection(getTransceiverId(call), result);
    } catch (error) {
      this.resultError('rtpTransceiverGetDirection',
        'rtpTransceiverGetDirection failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 查询 transceiver 当前协商方向。
   * @param call 方法调用（参数：peerConnectionId、transceiverId）
   * @param result 调用结果
   */
  rtpTransceiverGetCurrentDirection(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.rtpTransceiverGetCurrentDirection(getTransceiverId(call), result);
    } catch (error) {
      this.resultError('rtpTransceiverGetCurrentDirection',
        'rtpTransceiverGetCurrentDirection failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 停止 transceiver。
   * @param call 方法调用（参数：peerConnectionId、transceiverId）
   * @param result 调用结果
   */
  rtpTransceiverStop(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.rtpTransceiverStop(getTransceiverId(call), result);
    } catch (error) {
      this.resultError('rtpTransceiverStop', 'rtpTransceiverStop failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置 Sender 参数。
   * @param call 方法调用（参数：peerConnectionId、rtpSenderId、parameters）
   * @param result 调用结果
   */
  rtpSenderSetParameters(call: MethodCall, result: MethodResult): void {
    try {
      let parameters: DataMap = call.argument('parameters');
      if (parameters === null || parameters === undefined) {
        this.resultError('rtpSenderSetParameters', 'parameters is required', result);
        return;
      }
      this.getPCO(call, result)?.rtpSenderSetParameters(getRtpSenderId(call), parameters, result);
    } catch (error) {
      this.resultError('rtpSenderSetParameters',
        'rtpSenderSetParameters failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 替换 Sender 关联的轨道。
   * @param call 方法调用（参数：peerConnectionId、rtpSenderId、trackId）
   * @param result 调用结果
   */
  rtpSenderReplaceTrack(call: MethodCall, result: MethodResult): void {
    try {
      this.handleRtpSenderSetTrack(call, result, true);
    } catch (error) {
      this.resultError('rtpSenderReplaceTrack', 'rtpSenderReplaceTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置 Sender 关联的轨道。
   * @param call 方法调用（参数：peerConnectionId、rtpSenderId、trackId）
   * @param result 调用结果
   */
  rtpSenderSetTrack(call: MethodCall, result: MethodResult): void {
    try {
      this.handleRtpSenderSetTrack(call, result, false);
    } catch (error) {
      this.resultError('rtpSenderSetTrack', 'rtpSenderSetTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 统一的 Sender 轨道设置/替换实现。
   * @param call 方法调用
   * @param result 回调句柄
   * @param replace 是否为替换语义
   */
  handleRtpSenderSetTrack(call: MethodCall, result: MethodResult, replace: boolean): void {
    try {
      const pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      let track: MediaStreamTrack | null = null;
      if (getTrackId(call).length > 0) {
        track = this.getMediaStreamTrack(call, result);
        if (!track) {
          return;
        }
      }
      pco.rtpSenderSetTrack(getRtpSenderId(call), track, result, replace);
    } catch (error) {
      this.resultError('handleRtpSenderSetTrack',
        'handleRtpSenderSetTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置 Sender 关联的流列表。
   * @param call 方法调用（参数：rtpSenderId、streamIds）
   * @param result 回调句柄
   */
  rtpSenderSetStreams(call: MethodCall, result: MethodResult): void {
    try {
      let pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      let rtpSenderId: string = getRtpSenderId(call);
      let streamIds: string[] = getStreamIds(call);
      let streams: MediaStream[] = [];
      for (let streamId of streamIds) {
        if (this.localStreams.hasKey(streamId)) {
          streams.push(this.localStreams.get(streamId));
        }
      }
      // 一次性传入完整的 streams 数组，避免在循环内逐次调用导致覆盖与重复回调
      pco.rtpSenderSetStreams(rtpSenderId, streams, result);
    } catch (error) {
      this.resultError('rtpSenderSetStreams', 'rtpSenderSetStreams failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取所有 Sender。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 调用结果
   */
  getSenders(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.getSenders(result);
    } catch (error) {
      this.resultError('getSenders', 'getSenders failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取所有 Receiver。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 调用结果
   */
  getReceivers(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.getReceivers(result);
    } catch (error) {
      this.resultError('getReceivers', 'getReceivers failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取所有 Transceiver。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 调用结果
   */
  getTransceivers(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.getTransceivers(result);
    } catch (error) {
      this.resultError('getTransceivers', 'getTransceivers failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置 transceiver 编解码器偏好。
   * @param call 方法调用（参数：transceiverId、codecs）
   * @param result 回调句柄
   */
  setCodecPreferences(call: MethodCall, result: MethodResult): void {
    try {
      let codecs: DataMap[] = call.argument('codecs');
      if (codecs === null || codecs === undefined || !Array.isArray(codecs)) {
        this.resultError('setCodecPreferences', 'codecs is required', result);
        return;
      }
      this.getPCO(call, result)?.rtpTransceiverSetCodecPreferences(getTransceiverId(call), codecs, result);
    } catch (error) {
      this.resultError('setCodecPreferences', 'setCodecPreferences failed: ' + JSON.stringify(error), result);
    }
  }
}
 
