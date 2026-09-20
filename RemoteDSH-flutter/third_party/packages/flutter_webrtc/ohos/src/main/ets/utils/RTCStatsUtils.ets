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
 
import { Log, MethodResult } from '@ohos/flutter_ohos';
import { RTCRtpReceiver, RTCRtpSender, RTCStats, RTCStatsReport, RTCPeerConnection } from 'libohos_webrtc.so';
import { ConstraintsArray } from './ConstraintsArray';
import { ConstraintsMap } from './ConstraintsMap';
import { DataMap, MethodChannelValue } from './ObjectType';

const TAG: string = 'FlutterWebRTCPlugin-RTCStatsUtils';

/**
 * Serializes a native stats report and completes the Flutter method call.
 * @param report 原生 RTCStatsReport
 * @param result Flutter 回调句柄
 */
export function returnStatsReport(report: RTCStatsReport, result: MethodResult): void {
  let stats: ConstraintsArray = new ConstraintsArray();
  report.stats.forEach((value: RTCStats, key: string) => {
    let reportMap: DataMap = new Map();
    reportMap.set('id', value.id);
    reportMap.set('type', value.type);
    reportMap.set('timestamp', value.timestamp);
    reportMap.set('values', value.values ?? new Map<string, MethodChannelValue>());
    stats.pushMap(reportMap);
  });
  let params: ConstraintsMap = new ConstraintsMap();
  params.putArray('stats', stats.toArrayList());
  Log.i(TAG, 'stats = ' + Array.from(params.toMap().entries()));
  result.success(params.toMap());
}

/** 按 trackId 匹配到的 RTP sender/receiver。 */
export interface RtpStatTarget {
  sender?: RTCRtpSender;
  receiver?: RTCRtpReceiver;
}

/**
 * 在 PeerConnection 的 senders/receivers 中按 trackId 查找统计目标。
 * @param peerConnection PeerConnection 实例
 * @param trackId 轨道 id
 * @returns 命中的 sender/receiver（未命中则两者均为空）
 */
export function findStatsTargetByTrackId(
  peerConnection: RTCPeerConnection, trackId: string): RtpStatTarget {
  let target: RtpStatTarget = {};
  for (let s of peerConnection.getSenders()) {
    if (s.track !== null && trackId === s.track.id) {
      target.sender = s;
      break;
    }
  }
  if (target.sender === undefined) {
    for (let r of peerConnection.getReceivers()) {
      if (r.track !== null && trackId === r.track.id) {
        target.receiver = r;
        break;
      }
    }
  }
  return target;
}

