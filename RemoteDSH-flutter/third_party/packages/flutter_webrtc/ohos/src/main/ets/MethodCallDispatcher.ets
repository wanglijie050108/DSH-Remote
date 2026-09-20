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
import { MethodCall, MethodResult } from '@ohos/flutter_ohos';
// 2. 第三方库导入
// 3. 本地模块导入
import AudioMethodHandlers from './AudioMethodHandlers';
import { CapabilityMiscHandlers } from './CapabilityMiscHandlers';
import { DataChannelConnectionHandlers } from './DataChannelConnectionHandlers';
import DeviceEnumerationHandlers from './DeviceEnumerationHandlers';
import { MediaCaptureHandlers } from './MediaCaptureHandlers';
import { MediaStreamHandlers } from './MediaStreamHandlers';
import { MethodHandler } from './MethodHandlers';
import { RtpTransceiverHandlers } from './RtpTransceiverHandlers';
import { SignalingHandlers } from './SignalingHandlers';
import { TrackControlHandlers } from './TrackControlHandlers';
import { VideoRendererHandlers } from './VideoRendererHandlers';
import { getPeerConnectionId } from './utils/CallUtils';

/** Handler 依赖集合，由 MethodCallHandlerImpl 装配后传入分发器构建方法路由表。 */
export interface MethodCallDispatcherDependencies {
  initialize: MethodHandler;
  createPeerConnection: MethodHandler;
  audio: AudioMethodHandlers;
  capability: CapabilityMiscHandlers;
  connection: DataChannelConnectionHandlers;
  device: DeviceEnumerationHandlers;
  capture: MediaCaptureHandlers;
  mediaStream: MediaStreamHandlers;
  rtp: RtpTransceiverHandlers;
  signaling: SignalingHandlers;
  track: TrackControlHandlers;
  videoRenderer: VideoRendererHandlers;
}

/** 注册媒体采集/设备枚举/媒体流相关方法到分发映射表。 */
function addMediaMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('initialize', deps.initialize);
  map.set('createPeerConnection', deps.createPeerConnection);
  map.set('getUserMedia', (call: MethodCall, result: MethodResult) => deps.capture.getUserMedia(call, result));
  map.set('createLocalMediaStream', (call: MethodCall, result: MethodResult) =>
    deps.capture.createLocalMediaStream(call, result));
  map.set('getDisplayMedia', (call: MethodCall, result: MethodResult) => deps.capture.getDisplayMedia(call, result));
  map.set('requestCapturePermission', (call: MethodCall, result: MethodResult) =>
    deps.capture.requestCapturePermission(call, result));
  map.set('getSources', (call: MethodCall, result: MethodResult) => deps.device.getSources(call, result));
  map.set('mediaStreamGetTracks', (call: MethodCall, result: MethodResult) =>
    deps.mediaStream.mediaStreamGetTracks(call, result));
  map.set('addStream', (call: MethodCall, result: MethodResult) => deps.mediaStream.addStream(call, result));
  map.set('removeStream', (call: MethodCall, result: MethodResult) => deps.mediaStream.removeStream(call, result));
  map.set('streamDispose', (call: MethodCall, result: MethodResult) => deps.mediaStream.streamDispose(call, result));
  map.set('mediaStreamAddTrack', (call: MethodCall, result: MethodResult) =>
    deps.mediaStream.mediaStreamAddTrack(call, result));
  map.set('mediaStreamRemoveTrack', (call: MethodCall, result: MethodResult) =>
    deps.mediaStream.mediaStreamRemoveTrack(call, result));
  map.set('trackDispose', (call: MethodCall, result: MethodResult) => deps.mediaStream.trackDispose(call, result));
}

/** 注册 SDP/ICE/连接状态等信令相关方法到分发映射表。 */
function addSignalingMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('createOffer', (call: MethodCall, result: MethodResult) => deps.signaling.createOffer(call, result));
  map.set('createAnswer', (call: MethodCall, result: MethodResult) => deps.signaling.createAnswer(call, result));
  map.set('setLocalDescription', (call: MethodCall, result: MethodResult) =>
    deps.signaling.setLocalDescription(call, result));
  map.set('setRemoteDescription', (call: MethodCall, result: MethodResult) =>
    deps.signaling.setRemoteDescription(call, result));
  map.set('addCandidate', (call: MethodCall, result: MethodResult) => deps.signaling.addCandidate(call, result));
  map.set('getStats', (call: MethodCall, result: MethodResult) => deps.signaling.getStats(call, result));
  map.set('getLocalDescription', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getLocalDescription(call, result));
  map.set('getRemoteDescription', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getRemoteDescription(call, result));
  map.set('setConfiguration', (call: MethodCall, result: MethodResult) =>
    deps.signaling.setConfiguration(call, result));
  map.set('getSignalingState', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getSignalingState(call, result));
  map.set('getIceGatheringState', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getIceGatheringState(call, result));
  map.set('getIceConnectionState', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getIceConnectionState(call, result));
  map.set('getConnectionState', (call: MethodCall, result: MethodResult) =>
    deps.signaling.getConnectionState(call, result));
}

/** 注册数据通道/PeerConnection 生命周期/视频渲染器相关方法到分发映射表。 */
function addConnectionMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('sendDtmf', (call: MethodCall, result: MethodResult) => deps.connection.sendDtmf(call, result));
  map.set('canInsertDtmf', (call: MethodCall, result: MethodResult) => deps.connection.canInsertDtmf(call, result));
  map.set('createDataChannel', (call: MethodCall, result: MethodResult) =>
    deps.connection.createDataChannel(call, result));
  map.set('dataChannelSend', (call: MethodCall, result: MethodResult) => deps.connection.dataChannelSend(call, result));
  map.set('dataChannelClose', (call: MethodCall, result: MethodResult) =>
    deps.connection.dataChannelClose(call, result));
  map.set('restartIce', (call: MethodCall, result: MethodResult) => deps.connection.restartIce(call, result));
  map.set('peerConnectionClose', (call: MethodCall, result: MethodResult) =>
    deps.connection.peerConnectionClose(call, result));
  map.set('peerConnectionDispose', (call: MethodCall, result: MethodResult) =>
    deps.connection.peerConnectionDispose(call, result, getPeerConnectionId(call)));
  map.set('createVideoRenderer', (call: MethodCall, result: MethodResult) =>
    deps.videoRenderer.createVideoRenderer(call, result));
  map.set('videoRendererDispose', (call: MethodCall, result: MethodResult) =>
    deps.videoRenderer.videoRendererDispose(call, result));
  map.set('videoRendererSetSrcObject', (call: MethodCall, result: MethodResult) =>
    deps.videoRenderer.videoRendererSetSrcObject(call, result));
}

/** 注册音频设备/轨道控制相关方法到分发映射表。 */
function addDeviceMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('mediaStreamTrackSetEnable', (call: MethodCall, result: MethodResult) =>
    deps.track.mediaStreamTrackSetEnable(call, result));
  map.set('mediaStreamTrackHasTorch', (call: MethodCall, result: MethodResult) =>
    deps.track.mediaStreamTrackHasTorch(call, result));
  map.set('mediaStreamTrackSetTorch', (call: MethodCall, result: MethodResult) =>
    deps.track.mediaStreamTrackSetTorch(call, result));
  map.set('mediaStreamTrackSetZoom', (call: MethodCall, result: MethodResult) =>
    deps.track.mediaStreamTrackSetZoom(call, result));
  map.set('mediaStreamTrackSwitchCamera', (call: MethodCall, result: MethodResult) =>
    deps.track.mediaStreamTrackSwitchCamera(call, result));
  map.set('setVolume', (call: MethodCall, result: MethodResult) => deps.audio.setVolume(call, result));
  map.set('selectAudioOutput', (call: MethodCall, result: MethodResult) => deps.audio.selectAudioOutput(call, result));
  map.set('setMicrophoneMute', (call: MethodCall, result: MethodResult) => deps.audio.setMicrophoneMute(call, result));
  map.set('selectAudioInput', (call: MethodCall, result: MethodResult) => deps.audio.selectAudioInput(call, result));
  map.set('ensureAudioSession', (call: MethodCall, result: MethodResult) =>
    deps.audio.ensureAudioSession(call, result));
  map.set('setOhosAudioConfiguration', (call: MethodCall, result: MethodResult) =>
    deps.audio.setOhosAudioConfiguration(call, result));
  map.set('enableSpeakerphone', (call: MethodCall, result: MethodResult) =>
    deps.audio.enableSpeakerphone(call, result));
  map.set('enableSpeakerphoneButPreferBluetooth', (call: MethodCall, result: MethodResult) =>
    deps.audio.enableSpeakerphoneButPreferBluetooth(call, result));
  map.set('setSpeakerMute', (call: MethodCall, result: MethodResult) => deps.audio.setSpeakerMute(call, result));
  map.set('setNoiseSuppressorEnabled', (call: MethodCall, result: MethodResult) =>
    deps.audio.setNoiseSuppressorEnabled(call, result));
  map.set('isBuiltInAcousticEchoCancelerSupported', (call: MethodCall, result: MethodResult) =>
    deps.audio.isBuiltInAcousticEchoCancelerSupported(call, result));
  map.set('isBuiltInNoiseSuppressorSupported', (call: MethodCall, result: MethodResult) =>
    deps.audio.isBuiltInNoiseSuppressorSupported(call, result));
}

/** 注册 RTP Sender/Receiver/Transceiver 相关方法到分发映射表。 */
function addRtpMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('addTrack', (call: MethodCall, result: MethodResult) => deps.rtp.addTrack(call, result));
  map.set('removeTrack', (call: MethodCall, result: MethodResult) => deps.rtp.removeTrack(call, result));
  map.set('addTransceiver', (call: MethodCall, result: MethodResult) => deps.rtp.addTransceiver(call, result));
  map.set('rtpTransceiverSetDirection', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpTransceiverSetDirection(call, result));
  map.set('rtpTransceiverGetDirection', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpTransceiverGetDirection(call, result));
  map.set('rtpTransceiverGetCurrentDirection', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpTransceiverGetCurrentDirection(call, result));
  map.set('rtpTransceiverStop', (call: MethodCall, result: MethodResult) => deps.rtp.rtpTransceiverStop(call, result));
  map.set('rtpSenderSetParameters', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpSenderSetParameters(call, result));
  map.set('rtpSenderReplaceTrack', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpSenderReplaceTrack(call, result));
  map.set('rtpSenderSetTrack', (call: MethodCall, result: MethodResult) => deps.rtp.rtpSenderSetTrack(call, result));
  map.set('rtpSenderSetStreams', (call: MethodCall, result: MethodResult) =>
    deps.rtp.rtpSenderSetStreams(call, result));
  map.set('getSenders', (call: MethodCall, result: MethodResult) => deps.rtp.getSenders(call, result));
  map.set('getReceivers', (call: MethodCall, result: MethodResult) => deps.rtp.getReceivers(call, result));
  map.set('getTransceivers', (call: MethodCall, result: MethodResult) => deps.rtp.getTransceivers(call, result));
  map.set('setCodecPreferences', (call: MethodCall, result: MethodResult) =>
    deps.rtp.setCodecPreferences(call, result));
}

/** 注册录制/抓帧/编解码能力查询相关方法到分发映射表。 */
function addCapabilityMethods(map: Map<string, MethodHandler>, deps: MethodCallDispatcherDependencies): void {
  map.set('startRecordToFile', (call: MethodCall, result: MethodResult) =>
    deps.capability.startRecordToFile(call, result));
  map.set('stopRecordToFile', (call: MethodCall, result: MethodResult) =>
    deps.capability.stopRecordToFile(call, result));
  map.set('captureFrame', (call: MethodCall, result: MethodResult) => deps.capability.captureFrame(call, result));
  map.set('setPreferredInputDevice', (call: MethodCall, result: MethodResult) =>
    deps.capability.setPreferredInputDevice(call, result));
  map.set('getRtpSenderCapabilities', (call: MethodCall, result: MethodResult) =>
    deps.capability.getRtpSenderCapabilities(call, result));
  map.set('getRtpReceiverCapabilities', (call: MethodCall, result: MethodResult) =>
    deps.capability.getRtpReceiverCapabilities(call, result));
}

/** Builds the Flutter method-channel dispatch table from cohesive handler objects. */
export function createMethodCallDispatcher(deps: MethodCallDispatcherDependencies): Map<string, MethodHandler> {
  let map: Map<string, MethodHandler> = new Map();
  addMediaMethods(map, deps);
  addSignalingMethods(map, deps);
  addConnectionMethods(map, deps);
  addDeviceMethods(map, deps);
  addRtpMethods(map, deps);
  addCapabilityMethods(map, deps);
  return map;
}
