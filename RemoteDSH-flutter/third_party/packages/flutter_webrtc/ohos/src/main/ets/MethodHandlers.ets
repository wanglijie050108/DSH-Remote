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

import { MethodCall, MethodResult } from '@ohos/flutter_ohos';

/**
 * 单个 MethodCall 处理函数的类型别名，供 methodHandlers 映射与分发使用。
 */
export type MethodHandler = (call: MethodCall, result: MethodResult) => void;

/**
 * Flutter MethodChannel 方法处理契约集合，声明插件对外暴露的全部方法签名，
 * 供 MethodCallHandlerImpl 实现并分发。
 */
export interface MethodHandlers {
  initialize: (call: MethodCall, result: MethodResult) => void,
  createPeerConnection: (call: MethodCall, result: MethodResult) => void,
  getUserMedia: (call: MethodCall, result: MethodResult) => void,
  createLocalMediaStream: (call: MethodCall, result: MethodResult) => void,
  getSources: (call: MethodCall, result: MethodResult) => void,
  createOffer: (call: MethodCall, result: MethodResult) => void,
  createAnswer: (call: MethodCall, result: MethodResult) => void,
  mediaStreamGetTracks: (call: MethodCall, result: MethodResult) => void,
  addStream: (call: MethodCall, result: MethodResult) => void,
  removeStream: (call: MethodCall, result: MethodResult) => void,
  setLocalDescription: (call: MethodCall, result: MethodResult) => void,
  setRemoteDescription: (call: MethodCall, result: MethodResult) => void,
  sendDtmf: (call: MethodCall, result: MethodResult) => void,
  canInsertDtmf: (call: MethodCall, result: MethodResult) => void,
  addCandidate: (call: MethodCall, result: MethodResult) => void,
  getStats: (call: MethodCall, result: MethodResult) => void,
  createDataChannel: (call: MethodCall, result: MethodResult) => void,
  dataChannelSend: (call: MethodCall, result: MethodResult) => void,
  dataChannelClose: (call: MethodCall, result: MethodResult) => void,
  streamDispose: (call: MethodCall, result: MethodResult) => void,
  mediaStreamTrackSetEnable: (call: MethodCall, result: MethodResult) => void,
  mediaStreamAddTrack: (call: MethodCall, result: MethodResult) => void,
  mediaStreamRemoveTrack: (call: MethodCall, result: MethodResult) => void,
  trackDispose: (call: MethodCall, result: MethodResult) => void,
  restartIce: (call: MethodCall, result: MethodResult) => void,
  peerConnectionClose: (call: MethodCall, result: MethodResult) => void,
  peerConnectionDispose: (call: MethodCall, result: MethodResult) => void,
  createVideoRenderer: (call: MethodCall, result: MethodResult) => void,
  videoRendererDispose: (call: MethodCall, result: MethodResult) => void,
  videoRendererSetSrcObject: (call: MethodCall, result: MethodResult) => void,
  mediaStreamTrackHasTorch: (call: MethodCall, result: MethodResult) => void,
  mediaStreamTrackSetTorch: (call: MethodCall, result: MethodResult) => void,
  mediaStreamTrackSetZoom: (call: MethodCall, result: MethodResult) => void,
  mediaStreamTrackSwitchCamera: (call: MethodCall, result: MethodResult) => void,
  setVolume: (call: MethodCall, result: MethodResult) => void,
  selectAudioOutput: (call: MethodCall, result: MethodResult) => void,
  setMicrophoneMute: (call: MethodCall, result: MethodResult) => void,
  selectAudioInput: (call: MethodCall, result: MethodResult) => void,
  setOhosAudioConfiguration: (call: MethodCall, result: MethodResult) => void,
  enableSpeakerphone: (call: MethodCall, result: MethodResult) => void,
  enableSpeakerphoneButPreferBluetooth: (call: MethodCall, result: MethodResult) => void,
  getDisplayMedia: (call: MethodCall, result: MethodResult) => void,
  startRecordToFile: (call: MethodCall, result: MethodResult) => void,
  stopRecordToFile: (call: MethodCall, result: MethodResult) => void,
  captureFrame: (call: MethodCall, result: MethodResult) => void,
  getLocalDescription: (call: MethodCall, result: MethodResult) => void,
  getRemoteDescription: (call: MethodCall, result: MethodResult) => void,
  setConfiguration: (call: MethodCall, result: MethodResult) => void,
  addTrack: (call: MethodCall, result: MethodResult) => void,
  removeTrack: (call: MethodCall, result: MethodResult) => void,
  addTransceiver: (call: MethodCall, result: MethodResult) => void,
  rtpTransceiverSetDirection: (call: MethodCall, result: MethodResult) => void,
  rtpTransceiverGetDirection: (call: MethodCall, result: MethodResult) => void,
  rtpTransceiverGetCurrentDirection: (call: MethodCall, result: MethodResult) => void,
  rtpTransceiverStop: (call: MethodCall, result: MethodResult) => void,
  rtpSenderSetParameters: (call: MethodCall, result: MethodResult) => void,
  rtpSenderReplaceTrack: (call: MethodCall, result: MethodResult) => void,
  rtpSenderSetTrack: (call: MethodCall, result: MethodResult) => void,
  rtpSenderSetStreams: (call: MethodCall, result: MethodResult) => void,
  getSenders: (call: MethodCall, result: MethodResult) => void,
  getReceivers: (call: MethodCall, result: MethodResult) => void,
  getTransceivers: (call: MethodCall, result: MethodResult) => void,
  setPreferredInputDevice: (call: MethodCall, result: MethodResult) => void,
  getRtpSenderCapabilities: (call: MethodCall, result: MethodResult) => void,
  getRtpReceiverCapabilities: (call: MethodCall, result: MethodResult) => void,
  setCodecPreferences: (call: MethodCall, result: MethodResult) => void,
  getSignalingState: (call: MethodCall, result: MethodResult) => void,
  getIceGatheringState: (call: MethodCall, result: MethodResult) => void,
  getIceConnectionState: (call: MethodCall, result: MethodResult) => void,
  getConnectionState: (call: MethodCall, result: MethodResult) => void,
  setNoiseSuppressorEnabled: (call: MethodCall, result: MethodResult) => void,
  isBuiltInAcousticEchoCancelerSupported: (call: MethodCall, result: MethodResult) => void,
  isBuiltInNoiseSuppressorSupported: (call: MethodCall, result: MethodResult) => void,
  setSpeakerMute: (call: MethodCall, result: MethodResult) => void,
  requestCapturePermission: (call: MethodCall, result: MethodResult) => void,
}

/**
 * 帧加密（FrameCryptor）相关方法处理契约集合，供 FlutterRTCFrameCryptor 实现并分发。
 */
export interface CryptorMethodHandlers {
  frameCryptorFactoryCreateFrameCryptor: (call: MethodCall, result: MethodResult) => void,
  frameCryptorSetKeyIndex: (call: MethodCall, result: MethodResult) => void,
  frameCryptorGetKeyIndex: (call: MethodCall, result: MethodResult) => void,
  frameCryptorSetEnabled: (call: MethodCall, result: MethodResult) => void,
  frameCryptorGetEnabled: (call: MethodCall, result: MethodResult) => void,
  frameCryptorDispose: (call: MethodCall, result: MethodResult) => void,
  frameCryptorFactoryCreateKeyProvider: (call: MethodCall, result: MethodResult) => void,
  keyProviderSetSharedKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderRatchetSharedKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderExportSharedKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderSetKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderRatchetKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderExportKey: (call: MethodCall, result: MethodResult) => void,
  keyProviderSetSifTrailer: (call: MethodCall, result: MethodResult) => void,
  keyProviderDispose: (call: MethodCall, result: MethodResult) => void,
}