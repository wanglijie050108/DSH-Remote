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
 
import { MethodResult } from '@ohos/flutter_ohos';
import { BusinessError } from '@ohos.base';
import {
  MediaStreamTrack,
  RTCPeerConnection,
  RTCRtpReceiver,
  RTCRtpSender
} from 'libohos_webrtc.so';
import { findStatsTargetByTrackId, returnStatsReport, RtpStatTarget } from './utils/RTCStatsUtils';

export type StatsErrorHandler = (method: string, error: string, result: MethodResult) => void;

/** Owns asynchronous PeerConnection statistics lookup and error propagation. */
export class PeerConnectionStatsHandlers {
  private peerConnection: RTCPeerConnection;
  private resultError: StatsErrorHandler;

  /**
   * 构造统计处理器：注入 PeerConnection 与错误回调，用于 getStats/getStatsForTrack。
   */
  constructor(peerConnection: RTCPeerConnection, resultError: StatsErrorHandler) {
    this.peerConnection = peerConnection;
    this.resultError = resultError;
  }

  /** Updates the connection after PeerConnectionObserver replaces its native object. */
  setPeerConnection(peerConnection: RTCPeerConnection): void {
    this.peerConnection = peerConnection;
  }

  /** Requests aggregate or track-scoped PeerConnection statistics. */
  getStats(result: MethodResult, selector?: MediaStreamTrack): void {
    let request = selector ? this.peerConnection.getStats(selector) : this.peerConnection.getStats();
    request.then((report): void => {
      returnStatsReport(report, result);
    }).catch((error: BusinessError): void => {
      this.resultError('peerConnectionGetStats', `getStats failed: ${JSON.stringify(error)}`, result);
    });
  }

  /** Resolves a sender or receiver by track id before requesting its statistics. */
  getStatsForTrack(trackId: string, result: MethodResult): void {
    if (trackId === '') {
      this.resultError('peerConnectionGetStats', 'MediaStreamTrack not found for id: ' + trackId, result);
      return;
    }
    let target: RtpStatTarget = findStatsTargetByTrackId(this.peerConnection, trackId);
    let statTarget: RTCRtpSender | RTCRtpReceiver | undefined = target.sender ?? target.receiver;
    if (!statTarget) {
      this.resultError('peerConnectionGetStats', 'MediaStreamTrack not found for id: ' + trackId, result);
      return;
    }
    statTarget.getStats().then((report): void => {
      returnStatsReport(report, result);
    }).catch((error: BusinessError): void => {
      this.resultError('peerConnectionGetStats', `getStats failed: ${JSON.stringify(error)}`, result);
    });
  }
}
