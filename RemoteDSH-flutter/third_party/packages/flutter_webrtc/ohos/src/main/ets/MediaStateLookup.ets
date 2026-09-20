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
 
import { HashMap, JSON } from '@kit.ArkTS';
import { Log } from '@ohos/flutter_ohos';
import { MediaStream, MediaStreamTrack } from 'libohos_webrtc.so';
import PeerConnectionObserver from './PeerConnectionObserver';

const TAG: string = 'FlutterWebRTCPlugin-MediaStateLookup';

/** Resolves local and remote media objects without exposing cache traversal to callers. */
export class MediaStateLookup {
  private localStreams: HashMap<string, MediaStream>;
  private localTracks: HashMap<string, MediaStreamTrack>;
  private peerConnections: HashMap<string, PeerConnectionObserver>;

  /**
   * 构造媒体状态查找器：注入本地流/轨道/PeerConnection 映射，供跨模块查找媒体对象。
   */
  constructor(
    localStreams: HashMap<string, MediaStream>,
    localTracks: HashMap<string, MediaStreamTrack>,
    peerConnections: HashMap<string, PeerConnectionObserver>
  ) {
    this.localStreams = localStreams;
    this.localTracks = localTracks;
    this.peerConnections = peerConnections;
  }

  /**
   * 根据流ID和可选的PeerConnection ID查找MediaStream。
   * 如果指定了peerConnectionId，则仅在对应的远端流中查找；
   * 如果peerConnectionId为空字符串，则遍历所有PeerConnection的远端流；
   * 远端未找到时回退到本地流缓存中查找。
   * @param id - 要查找的媒体流ID。
   * @param peerConnectionId - PeerConnection的ID，传空字符串表示遍历所有PeerConnection。
   * @returns 找到的MediaStream对象，未找到时返回null。
   */
  getStream(id: string, peerConnectionId: string): MediaStream | null {
    try {
      let stream: MediaStream | null = null;
      if (peerConnectionId.length > 0) {
        let observer: PeerConnectionObserver | undefined = this.peerConnections.get(peerConnectionId);
        if (observer !== undefined) {
          stream = observer.remoteStreams.get(id);
        }
      } else {
        for (let entry of this.peerConnections.entries()) {
          stream = entry[1].remoteStreams.get(id);
          if (stream !== null && stream !== undefined) {
            break;
          }
        }
      }
      return stream ?? this.localStreams.get(id) ?? null;
    } catch (error) {
      Log.e(TAG, `getStream(${id}) failed: ${JSON.stringify(error)}`);
      return null;
    }
  }

  /**
   * 根据轨道ID查找MediaStreamTrack，优先从本地轨道缓存查找。
   * 本地未找到时遍历所有PeerConnection的远端轨道；
   * 如果指定了peerConnectionId，则仅查找匹配该ID的PeerConnection下的远端轨道。
   * @param trackId - 要查找的媒体轨道ID。
   * @param peerConnectionId - 可选的PeerConnection ID，用于限定查找范围。
   * @returns 找到的MediaStreamTrack对象，未找到时返回null。
   */
  getTrack(trackId: string, peerConnectionId?: string): MediaStreamTrack | null {
    try {
      let track: MediaStreamTrack | null = this.localTracks.get(trackId) ?? null;
      if (track !== null) {
        return track;
      }
      for (let key of this.peerConnections.keys()) {
        if (peerConnectionId !== undefined && key.localeCompare(peerConnectionId) !== 0) {
          continue;
        }
        let observer: PeerConnectionObserver | undefined = this.peerConnections.get(key);
        if (observer === undefined) {
          continue;
        }
        track = observer.remoteTracks.get(trackId) ?? observer.getTransceiversTrack(trackId);
        if (track !== null) {
          return track;
        }
      }
      return null;
    } catch (error) {
      Log.e(TAG, `getTrack(${trackId}) failed: ${JSON.stringify(error)}`);
      return null;
    }
  }
}
