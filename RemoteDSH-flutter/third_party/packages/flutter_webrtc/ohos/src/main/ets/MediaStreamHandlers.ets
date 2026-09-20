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
import { HashMap, PlainArray } from '@kit.ArkTS';
import {
  MediaStream,
  MediaStreamTrack,
  RTCRtpSender,
  RTCPeerConnection,
  VideoTrack,
  AudioTrack,
} from 'libohos_webrtc.so';
import { DataArray, DataMap } from './utils/ObjectType';
import { mediaStreamTrackToMap } from './utils/TrackUtils';
import { getStreamId, getTrackId } from './utils/CallUtils';
import PeerConnectionObserver from './PeerConnectionObserver';
import FlutterRTCVideoRenderer from './FlutterRTCVideoRenderer';
import AudioSwitchManager from './audio/AudioSwitchManager';

const TAG: string = 'FlutterWebRTCPlugin-MediaStreamHandlers';

/**
 * 媒体流与轨道 CRUD、释放相关方法集合。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调与共享的
 * localStreams / localTracks / renders 映射，与原实现保持等价行为。
 */

/**
 * 媒体流处理器的依赖注入配置对象，将多个构造参数收敛为单一对象，
 * 避免构造函数参数数量超标。
 */
export interface MediaStreamHandlersOptions {
  getMediaStream: (call: MethodCall, result: MethodResult, errorMsg?: string) => MediaStream | undefined;
  getMediaStreamTrack: (call: MethodCall, result: MethodResult) => MediaStreamTrack | null;
  getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null;
  getStreamForId: (id: string, peerConnectionId: string) => MediaStream | null;
  getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null;
  getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null;
  resultError: (method: string, error: string, result: MethodResult) => void;
  localStreams: HashMap<string, MediaStream>;
  localTracks: HashMap<string, MediaStreamTrack>;
  renders: PlainArray<FlutterRTCVideoRenderer>;
  textureIdGetter: () => number;
  removeVideoCapturer: (trackId: string) => void;
}

export class MediaStreamHandlers {
  private getMediaStream: (call: MethodCall, result: MethodResult, errorMsg?: string) => MediaStream | undefined;
  private getMediaStreamTrack: (call: MethodCall, result: MethodResult) => MediaStreamTrack | null;
  private getTrackForId: (trackId: string, peerConnectionId?: string) => MediaStreamTrack | null;
  private getStreamForId: (id: string, peerConnectionId: string) => MediaStream | null;
  private getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null;
  private getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private localStreams: HashMap<string, MediaStream>;
  private localTracks: HashMap<string, MediaStreamTrack>;
  private renders: PlainArray<FlutterRTCVideoRenderer>;
  private textureIdGetter: () => number;
  private removeVideoCapturer: (trackId: string) => void;

  /**
   * 构造媒体流处理器：注入 host 回调与共享的 localStreams/localTracks/renders 映射。
   */
  constructor(options: MediaStreamHandlersOptions) {
    this.getMediaStream = options.getMediaStream;
    this.getMediaStreamTrack = options.getMediaStreamTrack;
    this.getTrackForId = options.getTrackForId;
    this.getStreamForId = options.getStreamForId;
    this.getPeerConnection = options.getPeerConnection;
    this.getPCO = options.getPCO;
    this.resultError = options.resultError;
    this.localStreams = options.localStreams;
    this.localTracks = options.localTracks;
    this.renders = options.renders;
    this.textureIdGetter = options.textureIdGetter;
    this.removeVideoCapturer = options.removeVideoCapturer;
  }

  /**
   * 获取媒体流的音视频轨道列表，并缓存轨道到 localTracks。
   * @param call 方法调用（参数：streamId）
   * @param result 回调句柄，返回 { audioTracks, videoTracks }
   */
  mediaStreamGetTracks(call: MethodCall, result: MethodResult): void {
    try {
      let streamId: string = getStreamId(call);
      Log.d(TAG, 'mediaStreamGetTracks streamId= ' + streamId);
      let stream: MediaStream | null = this.getStreamForId(streamId, '');
      if (!stream) {
        this.resultError(call.method, 'mediaStreamGetTracks() stream [' + streamId + '] is null', result);
        return;
      }
      let resultMap: DataMap = new Map();
      let audioTracks: DataArray = [];
      let videoTracks: DataArray = [];
      stream.getAudioTracks().forEach((track: MediaStreamTrack) => {
        this.localTracks.set(track.id, track);
        audioTracks.push(mediaStreamTrackToMap(track));
      });
      stream.getVideoTracks().forEach((track: MediaStreamTrack) => {
        this.localTracks.set(track.id, track);
        videoTracks.push(mediaStreamTrackToMap(track));
      });
      resultMap.set('audioTracks', audioTracks);
      resultMap.set('videoTracks', videoTracks);
      result.success(resultMap);
    } catch (error) {
      this.resultError(call.method, 'mediaStreamGetTracks failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 添加整流（已废弃，内部以 addTrack 实现）。
   * @param call 方法调用（参数：streamId）
   * @param result 回调句柄
   */
  addStream(call: MethodCall, result: MethodResult): void {
    try {
      let mediaStream: MediaStream | undefined = this.getMediaStream(call, result);
      if (!mediaStream) {
        return;
      }
      let peerConnection: RTCPeerConnection | null = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      //addStream,新webrtc的最新规范中被废弃，建议使用 addTrack 方法作为替代。
      //对整流的每个轨道调用 addTrack，而非仅添加首轨道，保证完整流语义一致。
      let tracks: MediaStreamTrack[] = mediaStream.getTracks();
      if (tracks !== null && tracks.length > 0) {
        for (let track of tracks) {
          peerConnection.addTrack(track, mediaStream);
        }
      }
      Log.d(TAG, 'addStream' + result);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'addStream failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 移除整流（已废弃，内部以 removeTrack 实现）。
   * @param call 方法调用（参数：streamId）
   * @param result 回调句柄
   */
  removeStream(call: MethodCall, result: MethodResult): void {
    try {
      let mediaStream: MediaStream | undefined = this.getMediaStream(call, result);
      if (!mediaStream) {
        return;
      }
      let peerConnection: RTCPeerConnection | null = this.getPeerConnection(call, result);
      if (!peerConnection) {
        return;
      }
      //removeStream,新webrtc的最新规范中被废弃，建议使用 removeTrack 方法作为替代。
      //对整流的每个轨道查找对应 sender 并 removeTrack，而非仅移除首轨道 sender。
      let tracks: MediaStreamTrack[] = mediaStream.getTracks();
      if (tracks !== null && tracks.length > 0) {
        let pco: PeerConnectionObserver | null = this.getPCO(call, result);
        for (let track of tracks) {
          let sender: RTCRtpSender | null = pco?.getRtpSenderById(track.id) ?? null;
          if (sender) {
            peerConnection.removeTrack(sender);
          }
        }
      }
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'removeStream failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 释放指定流及其轨道，并解除渲染器绑定。
   * @param call 方法调用（参数：streamId）
   * @param result 回调句柄
   */
  streamDispose(call: MethodCall, result: MethodResult): void {
    let disposeStreamId: string = getStreamId(call);
    Log.d(TAG, 'streamDispose streamId= ' + disposeStreamId);
    try {
      this.handleStreamDispose(disposeStreamId, undefined);
      Log.d(TAG, 'streamDispose end');
      result.success(null);
      Log.d(TAG, 'streamDispose result.success end');
    } catch (error) {
      // handleStreamDispose 清理异常时显式回错，而非吞没后无条件返回 success。
      this.resultError(call.method, 'streamDispose failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 向流中添加轨道，并同步到渲染器。
   * @param call 方法调用（参数：streamId、trackId）
   * @param result 回调句柄
   */
  mediaStreamAddTrack(call: MethodCall, result: MethodResult): void {
    try {
      let streamId: string = getStreamId(call);
      Log.d(TAG, 'mediaStreamAddTrack streamId= ' + streamId);
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamAddTrack trackId= ' + trackId);
      let mediaStream: MediaStream | undefined = this.getMediaStream(call, result);
      if (!mediaStream) {
        this.resultError('mediaStreamAddTrack', 'mediaStreamAddTrack() stream [' + streamId + '] is null', result);
        return;
      }
      let track: MediaStreamTrack | null = this.getTrackForId(trackId);
      if (!track) {
        this.resultError('mediaStreamAddTrack', 'mediaStreamAddTrack() track [' + trackId + '] is null', result);
        return;
      }
      let kind: string = track.kind;
      //TODO kind 无 audio，需要替换情况
      if (kind === 'audio') {
        mediaStream.addTrack(track);
        result.success(null);
      } else if (kind === 'video') {
        mediaStream.addTrack(track);
        result.success(null);
      } else {
        this.resultError('mediaStreamAddTrack',
          'mediaStreamAddTrack() track [' + trackId + '] has unsupported type: ' + kind, result);
      }

      for (let i = 0; i < this.renders.length; i++) {
        let renderer: FlutterRTCVideoRenderer = this.renders.getValueAt(i);
        if (renderer.checkMediaStream(streamId, 'local')) {
          renderer.setVideoTrack(this.localTracks.get(trackId) ?? null);
        }
      }
    } catch (error) {
      this.resultError(call.method, 'mediaStreamAddTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 从流中移除轨道，并解除渲染器绑定。
   * @param call 方法调用（参数：streamId、trackId）
   * @param result 回调句柄
   */
  mediaStreamRemoveTrack(call: MethodCall, result: MethodResult): void {
    try {
      let streamId: string = getStreamId(call);
      Log.d(TAG, 'mediaStreamRemoveTrack streamId= ' + streamId);
      let trackId: string = getTrackId(call);
      Log.d(TAG, 'mediaStreamRemoveTrack trackId= ' + trackId);
      this.handleMediaStreamRemoveTrack(streamId, trackId, result);
      this.removeStreamForRendererById(streamId);
    } catch (error) {
      this.resultError(call.method, 'mediaStreamRemoveTrack failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 释放指定轨道：停用、停止、解除渲染器绑定并从 localTracks 移除。
   * @param call 方法调用（参数：trackId）
   * @param result 回调句柄
   */
  trackDispose(call: MethodCall, result: MethodResult): void {
    let trackId: string = getTrackId(call);
    Log.d(TAG, 'trackDispose id : ' + trackId);
    let track: MediaStreamTrack | null = this.getMediaStreamTrack(call, result);
    if (!track) {
      return;
    }
    try {
      track.enabled = false;
      track.stop();
      if (track.kind === 'audio') {
        AudioSwitchManager.getExistingInstance()?.stop(`local:${trackId}`);
      }
      this.removeTrackForRendererById(trackId);

      if (track.kind === 'video') {
        this.removeVideoCapturer(trackId);
      }
      this.localTracks.remove(trackId);
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'trackDispose failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 递归释放流：先按 streamId 取出并释放其轨道，再移除本地映射与渲染器绑定。
   * @param streamId 流 id（可选）
   * @param stream 流实例（可选）
   */
  handleStreamDispose(streamId?: string, stream?: MediaStream): void {
    let streamL: MediaStream;
    Log.d(TAG, 'function streamDispose streamId= ' + streamId);
    if (streamId) {
      streamL = this.localStreams.get(streamId);
      if (streamL) {
        Log.i(TAG, 'function streamDispose streamL= ' + stream);
        this.handleStreamDispose(undefined, streamL);
        this.localStreams.remove(streamId);
        this.removeStreamForRendererById(streamId);
        return;
      } else {
        Log.d(TAG, 'streamDispose() streamL is null');
      }
    } else {
      Log.d(TAG, 'function streamDispose() streamId is null');
    }

    if (stream) {
      Log.d(TAG, 'function streamDispose stream= ' + stream);
      let videoTracks: VideoTrack[] = stream.getVideoTracks();
      Log.d(TAG, 'function streamDispose videoTracks.length= ' + videoTracks.length);
      for (let track of videoTracks) {
        track.enabled = false;
        track.stop();
        this.localTracks.remove(track.id);
        stream.removeTrack(track);
      }

      let audioTracks: AudioTrack[] = stream.getAudioTracks();
      Log.d(TAG, 'function streamDispose audioTracks.length= ' + audioTracks.length);
      for (let track of audioTracks) {
        track.enabled = false;
        track.stop();
        AudioSwitchManager.getExistingInstance()?.stop(`local:${track.id}`);
        this.localTracks.remove(track.id);
        stream.removeTrack(track);
      }
    } else {
      Log.d(TAG, 'function streamDispose() stream is null');
    }
  }

  /**
   * 解除指定流在所有渲染器上的绑定。
   * @param streamId 流 id
   */
  removeStreamForRendererById(streamId: string): void {
    Log.d(TAG, 'streamDispose removeStreamForRendererById ');
    let textureId: number = this.textureIdGetter();
    if (textureId) {
      Log.d(TAG, 'streamDispose removeStreamForRendererById textureId：' + textureId);
      Log.d(TAG, 'streamDispose removeStreamForRendererById this.renders.length：' + this.renders.length);
      let videoRender: FlutterRTCVideoRenderer | undefined = this.renders.get(textureId);
      if (videoRender === undefined) {
        Log.e(TAG, 'streamDispose removeStreamForRendererById videoRender [' + textureId + '] not found !');
        return;
      }
    }

    for (let i = 0; i < this.renders.length; i++) {
      let renderer: FlutterRTCVideoRenderer = this.renders.getValueAt(i);
      if (renderer.checkMediaStream(streamId, 'local')) {
        renderer.setStream(null, '');
      }
    }
  }

  /**
   * 解除指定轨道在所有渲染器上的绑定。
   * @param trackId 轨道 id
   */
  removeTrackForRendererById(trackId: string): void {
    for (let i = 0; i < this.renders.length; i++) {
      let renderer: FlutterRTCVideoRenderer = this.renders.getValueAt(i);
      if (renderer.checkVideoTrack(trackId, 'local')) {
        renderer.setStream(null, null);
      }
    }
  }

  /**
   * 从流中移除轨道的统一实现。
   * @param streamId 流 id
   * @param trackId 轨道 id
   * @param result 回调句柄
   */
  handleMediaStreamRemoveTrack(streamId: string, trackId: string, result: MethodResult): void {
    try {
      let mediaStream: MediaStream | undefined = this.localStreams.get(streamId);
      if (!mediaStream) {
        this.resultError('mediaStreamRemoveTrack',
          'mediaStreamRemoveTrack() stream [' + streamId + '] is null', result);
        return;
      }
      let track: MediaStreamTrack | null = this.getTrackForId(trackId);
      if (!track) {
        this.resultError('mediaStreamRemoveTrack',
          'mediaStreamRemoveTrack() track [' + trackId + '] is null', result);
        return;
      }
      let kind: string = track.kind;
      if (kind === 'audio') {
        mediaStream.removeTrack(track);
        result.success(null);
      } else if (kind === 'video') {
        mediaStream.removeTrack(track);
        result.success(null);
      } else {
        this.resultError('mediaStreamRemoveTrack',
          'mediaStreamRemoveTrack() track [' + trackId + '] has unsupported type: ' + kind, result);
      }
    } catch (error) {
      this.resultError('mediaStreamRemoveTrack',
        'handleMediaStreamRemoveTrack failed: ' + JSON.stringify(error), result);
    }
  }
}
 
