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

import { ConstraintsMap } from './ConstraintsMap';
import { DataArray, DataMap } from './ObjectType';
import {
  MediaStreamTrack,
  RTCDTMFSender,
  RTCIceCandidate,
  RTCRtpCapabilities,
  RTCRtpCodec,
  RTCRtpHeaderExtensionCapability,
  RTCRtpCodecParameters,
  RTCRtpReceiver,
  RTCRtpSender,
  RTCRtpSendParameters,
  RTCRtpTransceiver
} from 'libohos_webrtc.so';
import { ConstraintsArray } from './ConstraintsArray';
import { isNotEmpty } from './Utils';

/**
 * Serializes RTP capabilities for the Flutter method channel.
 * @param capabilities 原生 RTP 能力对象
 * @returns 可跨方法通道传输的 Map
 */
export function capabilitiesToMap(capabilities: RTCRtpCapabilities): DataMap {
  let params: DataMap = new Map();
  let fecMechanismsArr: ConstraintsArray = new ConstraintsArray();
  let codecs: DataArray = [];
  capabilities.codecs.forEach((codec: RTCRtpCodec) => codecs.push(codecCapabilityToMap(codec)));
  let headerExtensions: DataArray = [];
  capabilities.headerExtensions.forEach((extension: RTCRtpHeaderExtensionCapability) => {
    let extensionMap: DataMap = new Map();
    extensionMap.set('uri', extension.uri);
    headerExtensions.push(extensionMap);
  });
  params.set('codecs', codecs);
  params.set('headerExtensions', headerExtensions);
  params.set('fecMechanisms', fecMechanismsArr.toArrayList());
  return params;
}

/** 将原生 codec capability 转换为 MethodChannel 可安全传输的 Map。 */
function codecCapabilityToMap(codec: RTCRtpCodec): DataMap {
  let codecMap: DataMap = new Map();
  codecMap.set('mimeType', codec.mimeType);
  codecMap.set('clockRate', codec.clockRate);
  codecMap.set('payloadType', codec.payloadType ?? null);
  codecMap.set('channels', codec.channels ?? null);
  codecMap.set('sdpFmtpLine', codec.sdpFmtpLine ?? null);
  return codecMap;
}

/**
 * Serializes an ICE candidate, preserving null values for absent fields.
 * @param candidate ICE 候选（可选）
 * @returns 包含 sdpMLineIndex/sdpMid/candidate 的 Map
 */
export function candidateToMap(candidate?: RTCIceCandidate): DataMap {
  let params: DataMap = new Map();
  params.set('sdpMLineIndex', candidate?.sdpMLineIndex ?? null);
  params.set('sdpMid', candidate?.sdpMid ?? null);
  params.set('candidate', candidate?.candidate ?? null);
  return params;
}

/**
 * Serializes a transceiver and its sender/receiver state.
 * @param transceiverId transceiver 的 flutterId
 * @param transceiver 原生 transceiver
 * @returns 包含方向、sender、receiver 的 Map
 */
export function transceiverToMap(transceiverId: string, transceiver: RTCRtpTransceiver): DataMap {
  let params: DataMap = new Map();
  params.set('transceiverId', transceiverId);
  params.set('mid', transceiver.mid ?? '');
  params.set('direction', transceiver.direction);
  params.set('sender', rtpSenderToMap(transceiver.sender));
  params.set('receiver', rtpReceiverToMap(transceiver.receiver));
  return params;
}

function rtcpToMap(rtpParameters: RTCRtpSendParameters): DataMap {
  let rtcp: ConstraintsMap = new ConstraintsMap();
  if (isNotEmpty(rtpParameters.rtcp.cname)) {
    rtcp.putString('cname', rtpParameters.rtcp.cname);
  }
  if (isNotEmpty(rtpParameters.rtcp.reducedSize)) {
    rtcp.putBoolean('reducedSize', rtpParameters.rtcp.reducedSize);
  }
  return rtcp.toMap();
}

function headerExtensionsToArray(rtpParameters: RTCRtpSendParameters): ConstraintsArray {
  let headerExtensions: ConstraintsArray = new ConstraintsArray();
  for (let extension of rtpParameters.headerExtensions) {
    let map: DataMap = new Map();
    map.set('uri', extension.uri);
    map.set('id', extension.id);
    map.set('encrypted', extension.encrypted ?? false);
    headerExtensions.pushMap(map);
  }
  return headerExtensions;
}

function encodingsToArray(rtpParameters: RTCRtpSendParameters): ConstraintsArray {
  let encodings: ConstraintsArray = new ConstraintsArray();
  for (let encoding of rtpParameters.encodings) {
    let map: DataMap = new Map();
    // 注意：OHOS native RTCRtpEncodingParameters 仅暴露 rid/active/maxBitrate/maxFramerate/
    // scaleResolutionDownBy，未定义 minBitrate / numTemporalLayers / ssrc 字段，故此处无法回传，
    // 属鸿蒙平台限制（见 webrtc.d.ts RTCRtpEncodingParameters）。
    if (isNotEmpty(encoding.active)) {
      map.set('active', encoding.active ?? null);
    }
    if (isNotEmpty(encoding.rid)) {
      map.set('rid', encoding.rid ?? null);
    }
    if (isNotEmpty(encoding.maxBitrate)) {
      map.set('maxBitrate', encoding.maxBitrate ?? null);
    }
    if (isNotEmpty(encoding.maxFramerate)) {
      map.set('maxFramerate', encoding.maxFramerate ?? null);
    }
    if (isNotEmpty(encoding.scaleResolutionDownBy)) {
      map.set('scaleResolutionDownBy', encoding.scaleResolutionDownBy ?? null);
    }
    encodings.pushMap(map);
  }
  return encodings;
}

function codecsToArray(rtpParameters: RTCRtpSendParameters): ConstraintsArray {
  let codecs: ConstraintsArray = new ConstraintsArray();
  rtpParameters.codecs.forEach((codec: RTCRtpCodecParameters) => {
    let map: DataMap = new Map();
    // 与 WebRTC 标准 RTCRtpCodecParameters 对齐：补全 mimeType、channels、sdpFmtpLine
    map.set('payloadType', codec.payloadType);
    map.set('clockRate', codec.clockRate);
    map.set('mimeType', codec.mimeType);
    if (isNotEmpty(codec.channels)) {
      map.set('channels', codec.channels ?? null);
    }
    if (isNotEmpty(codec.sdpFmtpLine)) {
      map.set('sdpFmtpLine', codec.sdpFmtpLine);
    }
    codecs.pushMap(map);
  });

  return codecs;
}

/**
 * Serializes RTP send parameters into method-channel-safe values.
 * @param rtpParameters 原生 RTP 发送参数
 * @returns 包含 rtcp/headerExtensions/encodings/codecs 的 Map
 */
export function rtpParametersToMap(rtpParameters: RTCRtpSendParameters): DataMap {
  let info: ConstraintsMap = new ConstraintsMap();
  info.putString('transactionId', rtpParameters.transactionId);
  info.putMap('rtcp', rtcpToMap(rtpParameters));
  info.putArray('headerExtensions', headerExtensionsToArray(rtpParameters).toArrayList());
  info.putArray('encodings', encodingsToArray(rtpParameters).toArrayList());
  info.putArray('codecs', codecsToArray(rtpParameters).toArrayList());
  return info.toMap();
}

/**
 * Serializes an RTP sender and its associated track and parameters.
 * @param sender 原生 RTP 发送器
 * @returns 包含 senderId/track/rtpParameters/dtmfSender 的 Map
 */
export function rtpSenderToMap(sender: RTCRtpSender): DataMap {
  let params: DataMap = new Map();
  params.set('senderId', sender.id ?? 'senderId');
  params.set('ownsTrack', true);
  params.set('dtmfSender', dtmfSenderToMap(sender.dtmf, sender.id));
  params.set('rtpParameters', rtpParametersToMap(sender.getParameters()));
  params.set('track', mediaTrackToMap(sender.track));
  return params;
}

/**
 * Serializes an RTP receiver and marks its track as remote.
 * @param receiver 原生 RTP 接收器
 * @returns 包含 receiverId/track/rtpParameters 的 Map
 */
export function rtpReceiverToMap(receiver: RTCRtpReceiver): DataMap {
  let params: DataMap = new Map();
  params.set('receiverId', receiver.id);
  // receiver 关联的轨道为远端轨道，标记 remote=true 与 Android/iOS 行为对齐
  params.set('track', mediaTrackToMap(receiver.track, true));
  params.set('rtpParameters', rtpParametersToMap(receiver.getParameters()));
  return params;
}

/**
 * 将 MediaStreamTrack 序列化为 Map。
 * @param track 媒体轨道（可能为空）
 * @param remote 是否为远端轨道，默认 false
 */
export function mediaTrackToMap(track: MediaStreamTrack | null, remote: boolean = false): DataMap {
  let params: DataMap = new Map();
  if (!track) {
    return params;
  }
  params.set('id', track.id);
  params.set('label', track.kind === 'video' ? 'video' : 'audio');
  params.set('kind', track.kind);
  params.set('enabled', track.enabled);
  params.set('readyState', track.readyState);
  params.set('remote', remote);
  return params;
}

/**
 * 将 RTCDTMFSender 序列化为 Map，与 Android/iOS 行为对齐。
 * 包含 dtmfSenderId 与 DTMF 能力标记 canInsertDTMF。
 * @param dtmfSender DTMF 发送器（可能为空）
 * @param id 关联的 sender id
 */
export function dtmfSenderToMap(dtmfSender: RTCDTMFSender | null, id: string | null): DataMap {
  let params: DataMap = new Map();
  params.set('dtmfSenderId', id ?? '');
  if (dtmfSender) {
    params.set('canInsertDTMF', dtmfSender.canInsertDTMF);
  }
  return params;
}
