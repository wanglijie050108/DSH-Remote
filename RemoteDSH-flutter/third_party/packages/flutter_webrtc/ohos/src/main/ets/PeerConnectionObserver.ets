/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import { BinaryMessenger, Log, MethodResult } from '@ohos/flutter_ohos';
import EventChannel, { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import {
  MediaStreamTrack,
  RTCDataChannel,
  RTCRtpReceiver,
  RTCRtpSender,
  RTCRtpCapabilities,
  RTCRtpCodec,
  RTCRtpTransceiverDirection,
  RTCPeerConnection,
  MediaStream,
  RTCRtpTransceiver,
  RTCConfiguration,
  RTCPeerConnectionIceEvent,
  Event,
  RTCDataChannelEvent,
  RTCTrackEvent,
  RTCIceCandidate,
} from 'libohos_webrtc.so';
import StateProvider from './StateProvider';
import { HashMap, util } from '@kit.ArkTS';
import { ConstraintsMap } from './utils/ConstraintsMap';
import AudioSwitchManager from './audio/AudioSwitchManager';
import { DataChannelObserver } from './DataChannelObserver';
import { DataArray, DataMap, ObjectType } from './utils/ObjectType';
import { DataChannelInit } from './DataChannelInit';
import { candidateToMap, mediaTrackToMap, rtpReceiverToMap, rtpSenderToMap, transceiverToMap } from './utils/PCOUtils';
import { dataMapToString } from './utils/Utils';
import { mediaStreamTrackToMap } from './utils/TrackUtils';
import { PeerConnectionDataChannels } from './PeerConnectionDataChannels';
import { PeerConnectionRtpHandlers } from './PeerConnectionRtpHandlers';
import { PeerConnectionEventHandlers } from './PeerConnectionEventHandlers';
import { PeerConnectionStatsHandlers } from './PeerConnectionStatsHandlers';

const TAG: string = 'FlutterWebRTCPlugin-PeerConnectionObserver';
const CHANNEL_NAME: string = 'FlutterWebRTC/peerConnectionEvent';

export default class PeerConnectionObserver implements StreamHandler {
  private peerConnection: RTCPeerConnection;
  private configuration: RTCConfiguration;
  private stateProvider: StateProvider;
  private messenger: BinaryMessenger;
  private id: string;
  private eventChannel: EventChannel;
  private eventSink: EventSink | null = null;
  private dataChannels: HashMap<string, RTCDataChannel> = new HashMap();
  private dataChannelObservers: HashMap<string, DataChannelObserver> = new HashMap();
  remoteStreams: HashMap<string, MediaStream> = new HashMap();
  remoteTracks: HashMap<string, MediaStreamTrack> = new HashMap();
  transceivers: HashMap<string, RTCRtpTransceiver> = new HashMap();
  private dcHandlers: PeerConnectionDataChannels;
  private rtpHandlers: PeerConnectionRtpHandlers;
  private eventHandlers: PeerConnectionEventHandlers;
  private statsHandlers: PeerConnectionStatsHandlers;

  /**
   * 构造观察者：初始化配置/状态/通道，创建数据通道与 RTP 子处理器，
   * 注册 PeerConnection 回调并绑定 EventChannel。
   * @param configuration RTC 配置
   * @param stateProvider 状态提供者
   * @param messenger Flutter 二进制信使
   * @param id PeerConnection 的 flutterId
   * @param peerConnection 底层 PeerConnection 实例
   */
  constructor(configuration: RTCConfiguration, stateProvider: StateProvider, messenger: BinaryMessenger,
    id: string, peerConnection: RTCPeerConnection) {
    this.configuration = configuration;
    this.stateProvider = stateProvider;
    this.messenger = messenger;
    this.id = id;
    this.peerConnection = peerConnection;
    this.dcHandlers = new PeerConnectionDataChannels({
      messenger: messenger,
      id: id,
      stateProvider: stateProvider,
      dataChannels: this.dataChannels,
      dataChannelObservers: this.dataChannelObservers,
      resultError: (method: string, error: string, result: MethodResult): void =>
        this.resultError(method, error, result),
      sendEvent: (event: DataMap): void => this.sendEvent(event),
      peerConnection: peerConnection
    });
    this.rtpHandlers = new PeerConnectionRtpHandlers((): RTCPeerConnection => this.peerConnection, stateProvider,
      this.transceivers,
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result));
    // 事件回调处理器：承载 8 个 native 事件回调，注入共享的远端流/轨道映射与
    // sendEvent/findTransceiver/onDataChannel/getNextStreamUUID 回调。
    this.eventHandlers = new PeerConnectionEventHandlers({
      getPeerConnection: (): RTCPeerConnection => this.peerConnection,
      remoteStreams: this.remoteStreams,
      remoteTracks: this.remoteTracks,
      id: id,
      sendEvent: (event: DataMap): void => this.sendEvent(event),
      findTransceiver: (predicate: (transceiver: RTCRtpTransceiver) => boolean): RTCRtpTransceiver | undefined =>
        this.rtpHandlers.findTransceiver(predicate),
      onDataChannel: (event: RTCDataChannelEvent): void => this.dcHandlers.onDataChannel(event),
      getNextStreamUUID: (): string => this.stateProvider.getNextStreamUUID()
    });
    this.statsHandlers = new PeerConnectionStatsHandlers(peerConnection,
      (method: string, error: string, result: MethodResult): void => this.resultError(method, error, result));
    this.setPeerConnectionCallback();
    this.eventChannel = new EventChannel(messenger, `${CHANNEL_NAME}${id}`);
    this.eventChannel.setStreamHandler(this);
  }

  /**
   * 为指定数据通道注册观察者，监听其状态与消息事件。
   * @param dcId 数据通道的 flutterId
   * @param dataChannel 底层数据通道实例
   */
  registerDataChannelObserver(dcId: string, dataChannel: RTCDataChannel): void {
    this.dcHandlers.registerDataChannelObserver(dcId, dataChannel);
  }

  /**
   * 统一错误返回：记录日志并通过 MethodResult 将错误传播到 Flutter 层。
   * @param method 方法名
   * @param error 错误描述
   * @param result 回调句柄
   */
  resultError(method: string, error: string, result: MethodResult): void {
    let errorMsg: string = `${method}(): ${error}`;
    Log.e(TAG, errorMsg);
    result.error(method, error, null);
  }

  /**
   * EventChannel 开始监听时缓存事件出口。
   * @param args EventChannel 订阅参数（当前未使用）
   * @param events 事件下沉句柄，缓存后用于向 Flutter 推送 PeerConnection 事件
   */
  onListen(args: Object, events: EventSink): void {
    this.eventSink = events;
  }

  /**
   * EventChannel 取消监听时清空事件出口，避免向已失效的 sink 推送。
   * @param args EventChannel 订阅参数（当前未使用）
   */
  onCancel(args: Object): void {
    this.eventSink = null;
  }

  /**
   * 向 Flutter 层推送一个事件。
   * @param event 事件数据
   */
  sendEvent(event: DataMap): void {
    this.eventSink?.success(event);
  }

  /**
   * 获取底层 RTCPeerConnection 实例。
   * @returns 关联的 PeerConnection
   */
  getPeerConnection(): RTCPeerConnection {
    return this.peerConnection;
  }

  /**
   * 更新底层 PeerConnection 实例，并同步到子处理器与回调注册。
   * @param peerConnection 新的 PeerConnection 实例
   */
  setPeerConnection(peerConnection: RTCPeerConnection): void {
    this.peerConnection = peerConnection;
    this.dcHandlers.setPeerConnection(peerConnection);
    this.rtpHandlers.setPeerConnection(peerConnection);
    this.eventHandlers.setPeerConnection(peerConnection);
    this.statsHandlers.setPeerConnection(peerConnection);
    this.setPeerConnectionCallback();
  }

  /** 向底层 PeerConnection 注册所有 WebRTC 事件回调（委托给事件处理器）。 */
  setPeerConnectionCallback(): void {
    this.eventHandlers.setPeerConnectionCallback();
  }

  /**
   * 清除 PeerConnection 上注册的所有回调，打破 peerConnection -> callback -> this 的循环引用，
   * 并确保 PC 关闭后不会触发已失效的回调（委托给事件处理器）。
   */
  clearPeerConnectionCallback(): void {
    this.eventHandlers.clearPeerConnectionCallback();
  }

  /** 触发底层 PeerConnection 的 ICE 重启。 */
  restartIce(): void {
    try {
      this.peerConnection.restartIce();
    } catch (error) {
      Log.e(TAG, 'restartIce error: ' + JSON.stringify(error));
    }
  }

  /**
   * 关闭 PeerConnection 并清理本地缓存的远端流/轨道/数据通道映射。
   */
  close(): void {
    // 关闭底层 PeerConnection 时进行异常保护，确保即使 close() 抛错，
    // 后续的 HashMap 与 dataChannelObservers 清理仍能正常执行。
    try {
      this.peerConnection.close();
    } catch (error) {
      Log.e(TAG, 'peerConnection.close failed: ' + JSON.stringify(error));
    }
    // 释放远端音频轨道对应的 AudioRenderer 引用计数：onTrack 对每条音频
    // 轨道调用了 AudioSwitchManager.start()（activeCount++），此处必须对称
    // 调用 stop()（activeCount--），否则连接反复创建/关闭后 AudioRenderer
    // 会一直保持 started 状态，消耗 CPU/电池（内存泄漏）。
    for (let track of this.remoteTracks.values()) {
      if (track && track.kind === 'audio') {
        AudioSwitchManager.getExistingInstance()?.stop(`remote:${this.id}:${track.id}`);
      }
    }
    // 释放所有数据通道观察者，避免回调悬空与循环引用
    for (let observer of this.dataChannelObservers.values()) {
      observer?.dispose();
    }
    this.dataChannelObservers.clear();
    this.dataChannels.clear();
    this.remoteStreams.clear();
    this.remoteTracks.clear();
    this.transceivers.clear();
  }

  /**
   * 释放 PeerConnection 资源：清除所有事件回调（避免循环引用与回调悬空）、
   * 关闭连接释放底层资源，并解除 EventChannel 绑定。
   */
  dispose(): void {
    this.clearPeerConnectionCallback();
    this.close();
    this.eventChannel.setStreamHandler(null);
    this.eventSink = null;
    // 子处理器持有的注入回调会捕获 this；显式替换为无状态回调，断开
    // PCO -> handler -> closure -> PCO 循环引用链。
    this.dcHandlers.dispose();
    this.rtpHandlers.dispose();
    this.eventHandlers.dispose();
  }

  /**
   * 创建数据通道并通过 result 返回结果。
   * @param label 通道标签
   * @param config 通道初始化配置约束
   * @param result 回调句柄
   */
  createDataChannel(label: string, config: ConstraintsMap, result: MethodResult): void {
    this.dcHandlers.createDataChannel(label, config, result);
  }

  /**
   * 关闭指定 id 的数据通道。
   * @param dataChannelId 数据通道 flutterId
   */
  dataChannelClose(dataChannelId: string): void {
    this.dcHandlers.dataChannelClose(dataChannelId);
  }

  /**
   * 通过指定数据通道发送数据。
   * @param dataChannelId 数据通道 flutterId
   * @param byteBuffer 待发送的字节缓冲
   * @param isBinary 是否为二进制数据
   */
  dataChannelSend(dataChannelId: string, byteBuffer: ArrayBuffer, isBinary: boolean): boolean {
    return this.dcHandlers.dataChannelSend(dataChannelId, byteBuffer, isBinary);
  }

  /**
   * 按 id 查找 RTP 发送器。
   * @param id 发送器 id
   * @returns 找到则返回 RTCRtpSender，否则 null
   */
  getRtpSenderById(id: string): RTCRtpSender | null {
    return this.rtpHandlers.getRtpSenderById(id);
  }

  /**
   * 按 id 查找 RTP 接收器。
   * @param id 接收器 id
   * @returns 找到则返回 RTCRtpReceiver，否则 null
   */
  getRtpReceiverById(id: string): RTCRtpReceiver | null {
    return this.rtpHandlers.getRtpReceiverById(id);
  }

  // 保持公开可见性，以兼容当前外部调用方式并与 Android 端行为一致。
  /**
   * 按 trackId 查找关联的 transceiver 轨道。
   * @param trackId 轨道 id
   * @returns 找到则返回 MediaStreamTrack，否则 null
   */
  getTransceiversTrack(trackId: string): MediaStreamTrack | null {
    return this.rtpHandlers.getTransceiversTrack(trackId);
  }

  /**
   * 获取当前所有 transceiver 列表并通过 result 返回。
   * @param result 回调句柄
   */
  getTransceivers(result: MethodResult): void {
    this.rtpHandlers.getTransceivers(result);
  }

  /**
   * 获取当前所有 RTP 发送器列表并通过 result 返回。
   * @param result 回调句柄
   */
  getSenders(result: MethodResult): void {
    this.rtpHandlers.getSenders(result);
  }

  /**
   * 获取当前所有 RTP 接收器列表并通过 result 返回。
   * @param result 回调句柄
   */
  getReceivers(result: MethodResult): void {
    this.rtpHandlers.getReceivers(result);
  }

  /**
   * 新增 transceiver（基于轨道或媒体类型）。
   * @param trackOrKind 轨道或媒体类型字符串
   * @param result 回调句柄
   * @param transceiverInit 可选的 transceiver 初始化参数
   * @param streams 可选的关联媒体流
   */
  addTransceiver(trackOrKind: MediaStreamTrack | string, result: MethodResult,
    transceiverInit?: DataMap, streams?: MediaStream[]): void {
    this.rtpHandlers.addTransceiver(trackOrKind, result, transceiverInit, streams);
  }

  /**
   * 向 PeerConnection 添加轨道。
   * @param track 媒体轨道
   * @param streams 关联的媒体流数组
   * @param result 回调句柄
   */
  addTrack(track: MediaStreamTrack, streams: MediaStream[], result: MethodResult): void {
    this.rtpHandlers.addTrack(track, streams, result);
  }

  /**
   * 移除指定发送器关联的轨道。
   * @param senderId 发送器 id
   * @param result 回调句柄
   */
  removeTrack(senderId: string, result: MethodResult): void {
    this.rtpHandlers.removeTrack(senderId, result);
  }

  /**
   * 异步设置 RTP 发送器的参数。
   * @param rtpSenderId 发送器 id
   * @param parameters 参数 Map
   * @param result 回调句柄
   */
  async rtpSenderSetParameters(rtpSenderId: string, parameters: DataMap,
    result: MethodResult): Promise<void> {
    await this.rtpHandlers.rtpSenderSetParameters(rtpSenderId, parameters, result);
  }

  /**
   * 异步设置 RTP 发送器关联的轨道（支持 replace 语义）。
   * @param rtpSenderId 发送器 id
   * @param track 新轨道，可为 null
   * @param result 回调句柄
   * @param replace 是否以 replaceTrack 语义执行
   */
  async rtpSenderSetTrack(rtpSenderId: string, track: MediaStreamTrack | null,
    result: MethodResult, replace: boolean): Promise<void> {
    await this.rtpHandlers.rtpSenderSetTrack(rtpSenderId, track, result, replace);
  }

  /**
   * 获取 PeerConnection 的统计信息并通过 result 返回。
   * @param result 回调句柄
   * @param selector 可选的轨道选择器，用于限定统计范围
   */
  getStats(result: MethodResult, selector?: MediaStreamTrack): void {
    this.statsHandlers.getStats(result, selector);
  }

  /**
   * 按 trackId 查找对应的 sender 或 receiver 并获取其统计信息。
   * @param trackId 轨道 id
   * @param result 回调句柄
   */
  getStatsForTrack(trackId: string, result: MethodResult): void {
    this.statsHandlers.getStatsForTrack(trackId, result);
  }

  /**
   * 生成下一个数据通道 UUID。
   * @returns 新的数据通道 UUID 字符串
   */
  getNextDataChannelUUID(): string {
    return this.dcHandlers.getNextDataChannelUUID();
  }

  /**
   * 设置发送器关联的媒体流列表。
   * @param rtpSenderId 发送器 id
   * @param streams 媒体流列表
   * @param result 回调句柄
   */
  rtpSenderSetStreams(rtpSenderId: string, streams: MediaStream[], result: MethodResult): void {
    this.rtpHandlers.rtpSenderSetStreams(rtpSenderId, streams, result);
  }

  /**
   * 获取 transceiver 当前的协商方向。
   * @param transceiverId transceiver id
   * @param result 回调句柄
   */
  rtpTransceiverGetCurrentDirection(transceiverId: string, result: MethodResult): void {
    this.rtpHandlers.rtpTransceiverGetCurrentDirection(transceiverId, result);
  }

  /**
   * 停止指定 transceiver。
   * @param transceiverId transceiver id
   * @param result 回调句柄
   */
  rtpTransceiverStop(transceiverId: string, result: MethodResult): void {
    this.rtpHandlers.rtpTransceiverStop(transceiverId, result);
  }

  /**
   * 设置 transceiver 的方向。
   * @param direction 目标方向
   * @param transceiverId transceiver id
   * @param result 回调句柄
   */
  rtpTransceiverSetDirection(direction: RTCRtpTransceiverDirection, transceiverId: string,
    result: MethodResult): void {
    this.rtpHandlers.rtpTransceiverSetDirection(direction, transceiverId, result);
  }

  /**
   * 获取 transceiver 的方向。
   * @param transceiverId transceiver id
   * @param result 回调句柄
   */
  rtpTransceiverGetDirection(transceiverId: string, result: MethodResult): void {
    this.rtpHandlers.rtpTransceiverGetDirection(transceiverId, result);
  }

  /**
   * 设置 transceiver 的编解码器优先级。
   * @param transceiverId transceiver id
   * @param codecs 编解码器列表
   * @param result 回调句柄
   */
  /*
   * Sets the priority of the encoder (codec) used in this transmitter for the sender and receiver.
   * */
  rtpTransceiverSetCodecPreferences(transceiverId: string, codecs: DataArray, result: MethodResult): void {
    this.rtpHandlers.rtpTransceiverSetCodecPreferences(transceiverId, codecs, result);
  }
}
