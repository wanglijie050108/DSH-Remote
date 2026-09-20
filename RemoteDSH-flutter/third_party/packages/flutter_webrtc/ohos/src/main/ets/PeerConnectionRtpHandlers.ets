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
import { Log, MethodResult } from '@ohos/flutter_ohos';
import { HashMap } from '@kit.ArkTS';
// 2. 第三方库导入
import {
  MediaStreamTrack,
  RTCRtpReceiver,
  RTCRtpSender,
  RTCRtpTransceiverDirection,
  RTCPeerConnection,
  MediaStream,
  RTCRtpTransceiver,
  RTCRtpEncodingParameters,
  RTCRtpSendParameters,
  RTCRtpTransceiverInit,
} from 'libohos_webrtc.so';
// 3. 本地模块导入
import StateProvider from './StateProvider';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { ConstraintsArray } from './utils/ConstraintsArray';
import { DataArray, DataMap, ObjectType } from './utils/ObjectType';
import { rtpReceiverToMap, rtpSenderToMap, transceiverToMap } from './utils/PCOUtils';
import { RtpParameterMapper } from './RtpParameterMapper';

const TAG: string = 'FlutterWebRTCPlugin-PeerConnectionObserver';

/**
 * 抽离自 PeerConnectionObserver 的 RTP 收发器/Sender/Receiver 相关方法集合。
 * 持有对 PCO 共享的 transceivers 映射的引用，以及 PCO 在 setPeerConnection 时同步的
 * peerConnection 引用，因此迁出的方法体与原实现保持逐字节一致。
 */
export class PeerConnectionRtpHandlers {
  private peerConnection: RTCPeerConnection;
  private stateProvider: StateProvider;
  private transceivers: HashMap<string, RTCRtpTransceiver>;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private parameterMapper: RtpParameterMapper = new RtpParameterMapper();

  /**
   * 构造函数，注入 RTP 收发器处理器所需的依赖（PeerConnection 实例、stateProvider、
   * 共享的 transceivers 映射与错误回调）。
   * @param getPeerConnection 获取当前 RTCPeerConnection 的回调
   * @param stateProvider 状态提供者，用于生成 UUID
   * @param transceivers 共享的 transceivers 映射
   * @param resultError 统一错误回调
   */
  constructor(getPeerConnection: () => RTCPeerConnection, stateProvider: StateProvider,
    transceivers: HashMap<string, RTCRtpTransceiver>,
    resultError: (method: string, error: string, result: MethodResult) => void) {
    this.peerConnection = getPeerConnection();
    this.stateProvider = stateProvider;
    this.transceivers = transceivers;
    this.resultError = resultError;
  }

  /** Breaks the error callback that captures the owning PeerConnectionObserver. */
  dispose(): void {
    this.resultError = (method: string, error: string, result: MethodResult): void => {
      Log.w(TAG, `Ignoring ${method} after RTP handler disposal: ${error}`);
    };
  }

  /**
   * 同步设置当前的 RTCPeerConnection 实例。
   * @param peerConnection 新的 PeerConnection 实例
   */
  setPeerConnection(peerConnection: RTCPeerConnection): void {
    this.peerConnection = peerConnection;
  }

  /**
   * 按 id 在 PeerConnection 的 senders 中查找对应的 RTP Sender。
   * @param id RTP Sender 的 id
   * @returns 匹配的 RTCRtpSender，无则 null
   */
  getRtpSenderById(id: string): RTCRtpSender | null {
    let senders: RTCRtpSender[] = this.peerConnection.getSenders();
    Log.d(TAG, 'senders length : ' + senders.length);
    for (let sender of senders) {
      Log.d(TAG, 'sender id : ' + sender.id);
      Log.d(TAG, ' id : ' + id);
      if (id === sender.id) {
        return sender;
      }
    }
    return null;
  }

  /**
   * 按 id 在 PeerConnection 的 receivers 中查找对应的 RTP Receiver。
   * @param id RTP Receiver 的 id
   * @returns 匹配的 RTCRtpReceiver，无则 null
   */
  getRtpReceiverById(id: string): RTCRtpReceiver | null {
    let receivers: RTCRtpReceiver[] = this.peerConnection.getReceivers();
    Log.d(TAG, 'receivers length : ' + receivers.length);
    for (let receiver of receivers) {
      Log.d(TAG, 'receiver id : ' + receiver.id);
      Log.d(TAG, ' id : ' + id);
      if (id === receiver.id) {
        return receiver;
      }
    }
    return null;
  }

  /**
   * 通过 trackId 从所有 transceiver 的 receiver 中反查对应的 MediaStreamTrack。
   * @param trackId 轨道 id
   * @returns 匹配的 MediaStreamTrack，无则 null
   */
  // 保持公开可见性，以兼容当前外部调用方式并与 Android 端行为一致。
  getTransceiversTrack(trackId: string): MediaStreamTrack | null {
    // Unified Plan 下才需要从 transceiver receiver 中反查轨道。
    //   return null;
    // }
    try {
      let transceivers: RTCRtpTransceiver[] = this.peerConnection.getTransceivers();
      for (let i = 0; i < transceivers.length; i++) {
        let receiver: RTCRtpReceiver = transceivers[i].receiver;
        if (receiver !== null && receiver.track !== null && receiver.track.id === trackId) {
          return receiver.track;
        }
      }
    } catch (error) {
      Log.e(TAG, 'getTransceiversTrack failed: ' + JSON.stringify(error));
    }
    return null;
  }

  /**
   * 获取 PeerConnection 的所有 RTCRtpTransceiver 并返回给 Flutter 侧。
   * @param result 用于返回结果的 MethodResult
   */
  getTransceivers(result: MethodResult): void {
    let transceivers: RTCRtpTransceiver[] = this.peerConnection.getTransceivers();
    let transceiversParams: ConstraintsArray = new ConstraintsArray();
    for (let transceiver of transceivers) {
      let transceiverId: string | null = transceiver.mid;
      if (!transceiverId) {
        transceiverId = this.stateProvider.getNextStreamUUID();
      }
      // 缓存 transceiver，确保后续 setCodecPreferences 等操作能通过 transceiverId 找到
      this.transceivers.set(transceiverId, transceiver);
      transceiversParams.pushMap(transceiverToMap(transceiverId, transceiver));
    }
    let params: ConstraintsMap = new ConstraintsMap();
    params.putArray('transceivers', transceiversParams.toArrayList());
    result.success(params.toMap());
  }

  /**
   * 获取 PeerConnection 的所有 RTCRtpSender 并返回给 Flutter 侧。
   * @param result 用于返回结果的 MethodResult
   */
  getSenders(result: MethodResult): void {
    let senders: RTCRtpSender[] = this.peerConnection.getSenders();
    let sendersParams: ConstraintsArray = new ConstraintsArray();
    for (let sender of senders) {
      sendersParams.pushMap(rtpSenderToMap(sender));
    }
    let params: ConstraintsMap = new ConstraintsMap();
    params.putArray('senders', sendersParams.toArrayList());
    result.success(params.toMap());
  }

  /**
   * 获取 PeerConnection 的所有 RTCRtpReceiver 并返回给 Flutter 侧。
   * @param result 用于返回结果的 MethodResult
   */
  getReceivers(result: MethodResult): void {
    let receivers: RTCRtpReceiver[] = this.peerConnection.getReceivers();
    let receiversParams: ConstraintsArray = new ConstraintsArray();
    for (let receiver of receivers) {
      receiversParams.pushMap(rtpReceiverToMap(receiver));
    }
    let params: ConstraintsMap = new ConstraintsMap();
    params.putArray('receivers', receiversParams.toArrayList());
    result.success(params.toMap());
  }

  /**
   * 添加 RTCRtpTransceiver 到 PeerConnection，支持按轨道或 kind 创建。
   * @param trackOrKind 轨道对象或媒体类型字符串（'audio' 或 'video'）
   * @param result 用于返回结果的 MethodResult
   * @param transceiverInit transceiver 初始化参数
   * @param streams 关联的 MediaStream 数组
   */
  addTransceiver(trackOrKind: MediaStreamTrack | string, result: MethodResult,
    transceiverInit?: DataMap, streams?: MediaStream[]): void {
    try {
      let transceiver: RTCRtpTransceiver = this.peerConnection.addTransceiver(trackOrKind,
        this.mapToRtpTransceiverInit(transceiverInit, streams));
      let transceiverId: string = transceiver.mid ?? this.stateProvider.getNextStreamUUID();
      this.transceivers.set(transceiverId, transceiver);
      result.success(transceiverToMap(transceiverId, transceiver));
    } catch (error) {
      this.resultError('addTransceiver', 'addTransceiver failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 将 Flutter 侧的参数映射为原生 RTCRtpTransceiverInit 对象。
   * @param parameters 包含 direction、sendEncodings 等字段的参数映射
   * @param streams 关联的 MediaStream 数组
   * @returns RTCRtpTransceiverInit 对象，parameters 为空则返回 undefined
   */
  mapToRtpTransceiverInit(parameters?: DataMap, streams?: MediaStream[]): RTCRtpTransceiverInit | undefined {
    return this.parameterMapper.mapTransceiverInit(parameters, streams);
  }

  /**
   * 将 Flutter 侧的编码参数映射为原生 RTCRtpEncodingParameters 对象。
   * @param parameters 包含 active、maxBitrate、maxFramerate、scaleResolutionDownBy 的编码参数
   * @returns 转换后的 RTCRtpEncodingParameters 对象
   */
  mapToEncoding(parameters: DataMap): RTCRtpEncodingParameters {
    return this.parameterMapper.mapEncoding(parameters);
  }

  /**
   * 向 PeerConnection 添加音视频轨道。
   * @param track 要添加的 MediaStreamTrack
   * @param streams 关联的 MediaStream 数组
   * @param result 用于返回结果的 MethodResult
   */
  addTrack(track: MediaStreamTrack, streams: MediaStream[], result: MethodResult): void {
    try {
      let sender: RTCRtpSender = this.peerConnection.addTrack(track, ...streams);
      Log.d(TAG, `[addTrack] track kind=${track.kind}, id=${track.id}`);
      let params: RTCRtpSendParameters = sender.getParameters();
      Log.d(TAG, `[addTrack] sender parameters: transactionId=${params.transactionId},` +
        ` codecs count=${params.codecs.length}`);
      for (let codec of params.codecs) {
        Log.d(TAG, `[addTrack]   sender codec: mimeType=${codec.mimeType},` +
          ` payloadType=${codec.payloadType}, clockRate=${codec.clockRate}`);
      }
      result.success(rtpSenderToMap(sender));
    } catch (error) {
      this.resultError('addTrack', 'addTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 从 PeerConnection 移除指定的 RTP Sender 对应的轨道。
   * @param senderId RTP Sender 的 id
   * @param result 用于返回结果的 MethodResult
   */
  removeTrack(senderId: string, result: MethodResult): void {
    try {
      let sender: RTCRtpSender | null = this.getRtpSenderById(senderId);
      if (!sender) {
        this.resultError('removeTrack', 'sender is null', result);
        return;
      }
      this.peerConnection.removeTrack(sender);
      let params: DataMap = new Map();
      params.set('result', true);
      result.success(params);
    } catch (error) {
      this.resultError('removeTrack', 'removeTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 设置指定 RTP Sender 的编码参数。
   * @param rtpSenderId RTP Sender 的 id
   * @param parameters 新的编码参数
   * @param result 用于返回结果的 MethodResult
   */
  async rtpSenderSetParameters(rtpSenderId: string, parameters: DataMap,
    result: MethodResult): Promise<void> {
    let sender: RTCRtpSender | null = this.getRtpSenderById(rtpSenderId);
    if (!sender) {
      this.resultError('rtpSenderSetParameters', 'sender is null', result);
      return;
    }
    let updatedParameters: RTCRtpSendParameters = this.updateRtpParameters(sender.getParameters(), parameters);
    let params: DataMap = new Map();
    try {
      await sender.setParameters(updatedParameters);
      params.set('result', true);
    } catch (error) {
      // 失败时记录错误详情，避免错误被静默吞没（仅返回 false 会让上层无从诊断）
      Log.e(TAG, 'rtpSenderSetParameters failed: ' + JSON.stringify(error));
      params.set('result', false);
    }
    result.success(params);
  }

  /**
   * 设置或替换指定 RTP Sender 的媒体轨道。
   * @param rtpSenderId RTP Sender 的 id
   * @param track 要设置的 MediaStreamTrack，可为 null
   * @param result 用于返回结果的 MethodResult
   * @param replace true 表示替换轨道，false 表示设置轨道
   */
  async rtpSenderSetTrack(rtpSenderId: string, track: MediaStreamTrack | null,
    result: MethodResult, replace: boolean): Promise<void> {
    let sender: RTCRtpSender | null = this.getRtpSenderById(rtpSenderId);
    if (!sender) {
      this.resultError('rtpSenderSetTrack', 'sender is null', result);
      return;
    }
    try {
      if (replace) {
        await sender.replaceTrack(track);
      } else {
        await sender.setTrack(track, false);
      }
      result.success(null);
    } catch (error) {
      this.resultError('rtpSenderSetTrack', JSON.stringify(error), result);
    }
  }

  /**
   * 用 Flutter 侧传入的新参数更新原生 RTP 发送参数对象。
   * @param parameters 当前的 RTCRtpSendParameters
   * @param newParameters Flutter 侧传入的新编码参数
   * @returns 更新后的 RTCRtpSendParameters
   */
  updateRtpParameters(parameters: RTCRtpSendParameters, newParameters: DataMap): RTCRtpSendParameters {
    return this.parameterMapper.updateSendParameters(parameters, newParameters);
  }

  /**
   * 设置指定 RTP Sender 关联的 MediaStream 列表。
   * @param rtpSenderId RTP Sender 的 id
   * @param streams 要关联的 MediaStream 数组
   * @param result 用于返回结果的 MethodResult
   */
  rtpSenderSetStreams(rtpSenderId: string, streams: MediaStream[], result: MethodResult): void {
    try {
      let sender: RTCRtpSender | null = this.getRtpSenderById(rtpSenderId);
      if (sender === null) {
        this.resultError('rtpSenderSetStreams', 'sender is null', result);
        return;
      }
      sender.setStreams(...streams);
      result.success(null);
    } catch (error) {
      this.resultError('rtpSenderSetStreams', 'setStreams failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 获取指定 transceiver 当前的传输方向。
   * @param transceiverId transceiver 的 id
   * @param result 用于返回结果的 MethodResult
   */
  rtpTransceiverGetCurrentDirection(transceiverId: string, result: MethodResult): void {
    const transceiver: RTCRtpTransceiver | undefined = this.getRtpTransceiverById(transceiverId);
    if (!transceiver) {
      this.resultError('rtpTransceiverGetCurrentDirection', 'transceiver is null', result);
      return;
    }
    const direction: RTCRtpTransceiverDirection = transceiver.direction;
    if (!direction) {
      result.success(null);
    } else {
      const params: ConstraintsMap = new ConstraintsMap();
      params.putString('result', direction);
      result.success(params.toMap());
    }
  }

  /**
   * 停止指定的 transceiver。
   * @param transceiverId transceiver 的 id
   * @param result 用于返回结果的 MethodResult
   */
  rtpTransceiverStop(transceiverId: string, result: MethodResult): void {
    const transceiver: RTCRtpTransceiver | undefined = this.getRtpTransceiverById(transceiverId);
    if (!transceiver) {
      this.resultError('rtpTransceiverStop', 'transceiver is null', result);
      return;
    }
    transceiver.stop();
    result.success(null);
  }

  private getRtpTransceiverById(id: string): RTCRtpTransceiver | undefined {
    let transceiver: RTCRtpTransceiver | undefined = this.transceivers.get(id);
    if (!transceiver) {
      // 单次遍历：优先按 mid 匹配，再退化用 receiver.id / sender.id 匹配
      // （兼容 addTrack 临时 id）
      transceiver = this.findTransceiver((item: RTCRtpTransceiver) => {
        return item.mid === id || item.receiver?.id === id || item.sender?.id === id;
      });
      // 找到后缓存，后续查询直接命中
      if (transceiver) {
        this.transceivers.set(id, transceiver);
      }
    }
    return transceiver;
  }

  /**
   * 按断言在 PeerConnection 的所有 transceiver 中查找第一个匹配项。
   * @param predicate 匹配断言
   * @returns 匹配的 transceiver，无则 undefined
   */
  findTransceiver(predicate: (transceiver: RTCRtpTransceiver) => boolean):
    RTCRtpTransceiver | undefined {
    let transceivers: RTCRtpTransceiver[] = this.peerConnection.getTransceivers();
    for (let i = 0; i < transceivers.length; i++) {
      if (predicate(transceivers[i])) {
        return transceivers[i];
      }
    }
    return undefined;
  }

  /**
   * 设置指定 transceiver 的传输方向。
   * @param direction 目标传输方向
   * @param transceiverId transceiver 的 id
   * @param result 用于返回结果的 MethodResult
   */
  rtpTransceiverSetDirection(direction: RTCRtpTransceiverDirection, transceiverId: string,
    result: MethodResult): void {
    let transceiver: RTCRtpTransceiver | undefined = this.getRtpTransceiverById(transceiverId);
    if (!transceiver) {
      this.resultError('rtpTransceiverSetDirection', 'transceiver is null', result);
      return;
    }
    transceiver.direction = direction;
    result.success(null);
  }

  /**
   * 获取指定 transceiver 的传输方向。
   * @param transceiverId transceiver 的 id
   * @param result 用于返回结果的 MethodResult
   */
  rtpTransceiverGetDirection(transceiverId: string, result: MethodResult): void {
    let transceiver: RTCRtpTransceiver | undefined = this.getRtpTransceiverById(transceiverId);
    if (!transceiver) {
      this.resultError('rtpTransceiverGetDirection', 'transceiver is null', result);
      return;
    }
    let params: ConstraintsMap = new ConstraintsMap();
    params.putString('result', transceiver.direction);
    result.success(params.toMap());
  }

  /**
   * 设置指定 transceiver 的编解码器优先级，影响发送端和接收端的编码器选择。
   * @param transceiverId transceiver 的 id
   * @param codecs 按优先级排序的编解码器列表
   * @param result 用于返回结果的 MethodResult
   */
  rtpTransceiverSetCodecPreferences(transceiverId: string, codecs: DataArray, result: MethodResult): void {
    const transceiver: RTCRtpTransceiver | undefined = this.getRtpTransceiverById(transceiverId);
    if (!transceiver) {
      this.resultError('rtpTransceiverSetCodecPreferences', 'transceiver is null', result);
      return;
    }
    transceiver.setCodecPreferences(this.parameterMapper.mapCodecs(codecs));
    result.success(null);
    Log.d(TAG, 'rtpTransceiverSetCodecPreferences success! ');
  }

}
