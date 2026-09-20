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
 
import { Log } from '@ohos/flutter_ohos';
import webrtc, {
  MediaStreamTrack,
  RTCPeerConnection,
  MediaStream,
  RTCRtpTransceiver,
  RTCPeerConnectionIceEvent,
  Event,
  RTCDataChannelEvent,
  RTCTrackEvent,
} from 'libohos_webrtc.so';
import { HashMap } from '@kit.ArkTS';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataArray, DataMap } from './utils/ObjectType';
import AudioSwitchManager from './audio/AudioSwitchManager';
import { candidateToMap, mediaTrackToMap, rtpReceiverToMap, transceiverToMap } from './utils/PCOUtils';
import { mediaStreamTrackToMap } from './utils/TrackUtils';

const TAG: string = 'FlutterWebRTCPlugin-PeerConnectionObserver';

/**
 * PeerConnection 事件回调处理器的依赖注入配置对象，将多个构造参数收敛为单一对象，
 * 避免构造函数参数数量超标（沿用 PeerConnectionDataChannels/RtpHandlers 的 Options 模式）。
 */
export interface PeerConnectionEventHandlersOptions {
  getPeerConnection: () => RTCPeerConnection;
  remoteStreams: HashMap<string, MediaStream>;
  remoteTracks: HashMap<string, MediaStreamTrack>;
  id: string;
  sendEvent: (event: DataMap) => void;
  findTransceiver: (predicate: (transceiver: RTCRtpTransceiver) => boolean) => RTCRtpTransceiver | undefined;
  onDataChannel: (event: RTCDataChannelEvent) => void;
  getNextStreamUUID: () => string;
}

/**
 * 抽离自 PeerConnectionObserver 的 WebRTC native 事件回调集合。
 *
 * 承载 PeerConnection 的 8 个 native 事件（onIceCandidate / onIceConnectionStateChange /
 * onIceGatheringStateChange / onTrack / onNegotiationNeeded / onSignalingStateChange /
 * onConnectionStateChange / onDataChannel）及其回调注册/清除逻辑，降低宿主类复杂度。
 * 通过构造函数注入共享的 remoteStreams/remoteTracks 映射与 sendEvent/findTransceiver/
 * onDataChannel/getNextStreamUUID 回调，与原实现保持等价行为。
 */
export class PeerConnectionEventHandlers {
  private peerConnection: RTCPeerConnection;
  private remoteStreams: HashMap<string, MediaStream>;
  private remoteTracks: HashMap<string, MediaStreamTrack>;
  private id: string;
  private sendEventFn: (event: DataMap) => void;
  private findTransceiverFn: (predicate: (transceiver: RTCRtpTransceiver) => boolean) => RTCRtpTransceiver | undefined;
  private onDataChannelFn: (event: RTCDataChannelEvent) => void;
  private getNextStreamUUIDFn: () => string;

  /**
   * 构造事件回调处理器：注入 PeerConnection 获取器、远端流/轨道映射、事件发送与 transceiver 查找回调。
   */
  constructor(options: PeerConnectionEventHandlersOptions) {
    this.peerConnection = options.getPeerConnection();
    this.remoteStreams = options.remoteStreams;
    this.remoteTracks = options.remoteTracks;
    this.id = options.id;
    this.sendEventFn = options.sendEvent;
    this.findTransceiverFn = options.findTransceiver;
    this.onDataChannelFn = options.onDataChannel;
    this.getNextStreamUUIDFn = options.getNextStreamUUID;
  }

  /** Breaks every injected callback that may capture the owning PeerConnectionObserver. */
  dispose(): void {
    this.sendEventFn = (event: DataMap): void => {};
    this.findTransceiverFn = (predicate: (transceiver: RTCRtpTransceiver) => boolean):
      RTCRtpTransceiver | undefined => undefined;
    this.onDataChannelFn = (event: RTCDataChannelEvent): void => {};
    this.getNextStreamUUIDFn = (): string => '';
  }

  /** Updates the native PeerConnection used by event registration and state callbacks. */
  setPeerConnection(peerConnection: RTCPeerConnection): void {
    this.peerConnection = peerConnection;
  }

  /** 向底层 PeerConnection 注册所有 WebRTC 事件回调，转发到对应的 on* 方法。 */
  setPeerConnectionCallback(): void {
    let peerConnection: RTCPeerConnection = this.peerConnection;
    if (!peerConnection) {
      Log.w(TAG, 'setPeerConnectionCallback: peerConnection is null, skip');
      return;
    }
    try {
      peerConnection.onicecandidate = (data: RTCPeerConnectionIceEvent) => this.onIceCandidate(data);
      peerConnection.oniceconnectionstatechange = (data: Event) => this.onIceConnectionStateChange(data);
      peerConnection.onicegatheringstatechange = (data: Event) => this.onIceGatheringStateChange(data);
      peerConnection.ontrack = (data: RTCTrackEvent) => this.onTrack(data);
      peerConnection.onnegotiationneeded = (data: Event) => this.onNegotiationNeeded(data);
      peerConnection.onsignalingstatechange = (data: Event) => this.onSignalingStateChange(data);
      peerConnection.onconnectionstatechange = (data: Event) => this.onConnectionStateChange(data);
      peerConnection.ondatachannel = (data: RTCDataChannelEvent) => this.onDataChannel(data);
    } catch (error) {
      // 属性赋值异常时记录日志，避免回调链断裂导致后续事件丢失
      Log.e(TAG, 'setPeerConnectionCallback failed: ' + JSON.stringify(error));
      // 将回调注册失败传播到 Flutter 层，避免后续 PC 事件静默丢失
      this.sendErrorEvent('setPeerConnectionCallback', error);
    }
  }

  /**
   * 清除 PeerConnection 上注册的所有回调，打破 peerConnection -> callback -> this 的循环引用，
   * 并确保 PC 关闭后不会触发已失效的回调。
   */
  clearPeerConnectionCallback(): void {
    let peerConnection: RTCPeerConnection = this.peerConnection;
    if (!peerConnection) {
      return;
    }
    peerConnection.onicecandidate = null;
    peerConnection.oniceconnectionstatechange = null;
    peerConnection.onicegatheringstatechange = null;
    peerConnection.ontrack = null;
    peerConnection.onnegotiationneeded = null;
    peerConnection.onsignalingstatechange = null;
    peerConnection.onconnectionstatechange = null;
    peerConnection.ondatachannel = null;
  }

  /**
   * ICE 候选生成回调，将候选转发到 Flutter 层。
   * @param event ICE 事件
   */
  onIceCandidate(event: RTCPeerConnectionIceEvent): void {
    // native 回调路径加 try-catch：PeerConnection 已关闭但回调仍触发时，
    // 访问 candidate 属性可能抛异常，导致事件被 native 静默吞掉。
    try {
      Log.d(TAG, `onIceCandidate: ${event.candidate?.toJSON()}`);
      let params: DataMap = new Map();
      params.set('event', 'onCandidate');
      params.set('candidate', candidateToMap(event.candidate));
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onIceCandidate error: ' + JSON.stringify(error));
      this.sendErrorEvent('onCandidateError', error);
    }
  }

  /**
   * ICE 连接状态变化回调，推送新状态到 Flutter 层。
   * @param event 事件对象
   */
  onIceConnectionStateChange(event: Event): void {
    try {
      Log.d(TAG, `onIceConnectionStateChange: ${this.peerConnection.iceConnectionState}`);
      let params: DataMap = new Map();
      params.set('event', 'iceConnectionState');
      params.set('state', this.peerConnection.iceConnectionState);
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onIceConnectionStateChange error: ' + JSON.stringify(error));
      this.sendErrorEvent('iceConnectionStateError', error);
    }
  }

  /**
   * ICE 收集状态变化回调，推送新状态到 Flutter 层。
   * @param event 事件对象
   */
  onIceGatheringStateChange(event: Event): void {
    try {
      Log.d(TAG, `onIceGatheringStateChange: ${this.peerConnection.iceGatheringState}`);
      let params: DataMap = new Map();
      params.set('event', 'iceGatheringState');
      params.set('state', this.peerConnection.iceGatheringState);
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onIceGatheringStateChange error: ' + JSON.stringify(error));
      this.sendErrorEvent('iceGatheringStateError', error);
    }
  }

  /**
   * 收到远端轨道回调：缓存远端流/轨道、发送 onAddTrack 与 onTrack 事件，
   * 并匹配对应 transceiver 信息一并发送。
   * @param event 轨道事件
   */
  onTrack(event: RTCTrackEvent): void {
    // onTrack 为 native 回调关键路径，包含多次 map 操作与 transceiver 查找，
    // 任一步骤抛异常都会导致后续 onAddTrack/onTrack 事件丢失，整体包裹 try-catch。
    try {
      Log.d(TAG, 'onTrack : ' + JSON.stringify(event.track));
      this.sendLegacyAddTrackEvents(event);
      let params: ConstraintsMap = this.buildUnifiedTrackEvent(event);
      Log.d(TAG, `onTrack params: ${params.toString()}`);
      this.sendEventFn(params.toMap());
    } catch (error) {
      Log.e(TAG, 'onTrack error: ' + JSON.stringify(error));
      this.sendErrorEvent('onTrackError', error);
    }
  }

  /** Emits legacy onAddTrack events and registers each remote stream/track before dispatch. */
  private sendLegacyAddTrackEvents(event: RTCTrackEvent): void {
    let track: MediaStreamTrack = event.receiver.track;
    let isNewTrack: boolean = !this.remoteTracks.hasKey(track.id);
    for (let stream of event.streams) {
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('event', 'onAddTrack');
      params.putString('streamId', stream.id);
      params.putString('ownerTag', this.id);
      params.putString('trackId', track.id);
      params.putMap('track', mediaStreamTrackToMap(track, true));
      this.remoteStreams.set(stream.id, stream);
      this.remoteTracks.set(track.id, track);
      this.sendEventFn(params.toMap());
    }
    if (track.kind === 'audio' && isNewTrack) {
      AudioSwitchManager.getExistingInstance()?.start(`remote:${this.id}:${track.id}`);
    }
  }

  /** Builds the Unified Plan onTrack payload including its matching transceiver. */
  private buildUnifiedTrackEvent(event: RTCTrackEvent): ConstraintsMap {
    let params: ConstraintsMap = new ConstraintsMap();
    let streams: DataMap[] = [];
    for (let stream of event.streams) {
      streams.push(this.mediaStreamToMap(stream, true));
      this.remoteStreams.set(stream.id, stream);
    }
    params.putString('event', 'onTrack');
    params.putArray('streams', streams);
    params.putMap('track', mediaTrackToMap(event.receiver.track, true));
    params.putMap('receiver', rtpReceiverToMap(event.receiver));
    let matched: RTCRtpTransceiver | undefined = this.findTransceiverFn(
      (transceiver: RTCRtpTransceiver): boolean =>
        transceiver.receiver !== null && event.receiver.id === transceiver.receiver.id
    );
    if (!matched) {
      Log.w(TAG, 'onTrack: no matching transceiver found for receiver');
      return params;
    }
    let transceiverId: string = (matched.mid && matched.mid.length > 0)
      ? matched.mid
      : this.getNextStreamUUIDFn();
    params.putMap('transceiver', transceiverToMap(transceiverId, matched));
    return params;
  }

  /**
   * 需要重新协商回调，通知 Flutter 层触发 onRenegotiationNeeded。
   * @param event 事件对象
   */
  onNegotiationNeeded(event: Event): void {
    try {
      Log.d(TAG, 'onNegotiationNeeded');
      let params: DataMap = new Map();
      params.set('event', 'onRenegotiationNeeded');
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onNegotiationNeeded error: ' + JSON.stringify(error));
      this.sendErrorEvent('onRenegotiationNeededError', error);
    }
  }

  /**
   * 信令状态变化回调，推送新状态到 Flutter 层。
   * @param event 事件对象
   */
  onSignalingStateChange(event: Event): void {
    try {
      Log.d(TAG, `onSignalingStateChange: ${this.peerConnection.signalingState}`);
      let params: DataMap = new Map();
      params.set('event', 'signalingState');
      params.set('state', this.peerConnection.signalingState);
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onSignalingStateChange error: ' + JSON.stringify(error));
      this.sendErrorEvent('signalingStateError', error);
    }
  }

  /**
   * PeerConnection 连接状态变化回调，推送新状态到 Flutter 层。
   * @param event 事件对象
   */
  onConnectionStateChange(event: Event): void {
    try {
      Log.d(TAG, `onConnectionStateChange: ${this.peerConnection.connectionState}`);
      let params: DataMap = new Map();
      params.set('event', 'peerConnectionState');
      params.set('state', this.peerConnection.connectionState);
      this.sendEventFn(params);
    } catch (error) {
      Log.e(TAG, 'onConnectionStateChange error: ' + JSON.stringify(error));
      this.sendErrorEvent('peerConnectionStateError', error);
    }
  }

  /**
   * 远端建立数据通道回调，委托给数据通道处理器处理。
   * @param event 数据通道事件
   */
  onDataChannel(event: RTCDataChannelEvent): void {
    try {
      this.onDataChannelFn(event);
    } catch (error) {
      Log.e(TAG, 'onDataChannel error: ' + JSON.stringify(error));
      // 将 DataChannel 创建错误传播到 Flutter 层，避免错误被静默吞没。
      this.sendErrorEvent('onDataChannel', error);
    }
  }

  /**
   * 向 Flutter 层推送一个 native 回调错误事件，使 Flutter 端能感知 WebRTC
   * native 层抛出的异常（避免 catch 仅 Log.e 导致 Flutter Future 挂起或状态不一致）。
   * @param eventName 触发错误的回调事件名（如 'onCandidateError'）
   * @param error 被捕获的异常对象
   */
  private sendErrorEvent(eventName: string, error: Error): void {
    try {
      let params: DataMap = new Map();
      params.set('event', eventName);
      params.set('error', JSON.stringify(error));
      this.sendEventFn(params);
    } catch (err) {
      Log.e(TAG, `sendErrorEvent(${eventName}) failed: ` + JSON.stringify(err));
    }
  }

  /**
   * 将 MediaStream 序列化为 Map。
   * @param stream 媒体流
   * @param remote 是否为远端流，默认 false；远端流内部的轨道也会标记 remote=true
   * @returns 序列化后的流 Map
   */
  mediaStreamToMap(stream: MediaStream, remote: boolean = false): DataMap {
    let params: DataMap = new Map();
    params.set('streamId', stream.id);
    params.set('ownerTag', this.id);
    let audioTracks: DataArray = [];
    let videoTracks: DataArray = [];
    for (let track of stream.getAudioTracks()) {
      audioTracks.push(mediaTrackToMap(track, remote));
    }
    for (let track of stream.getVideoTracks()) {
      videoTracks.push(mediaTrackToMap(track, remote));
    }
    params.set('audioTracks', audioTracks);
    params.set('videoTracks', videoTracks);
    return params;
  }
}
