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

import { MethodCall } from "@ohos/flutter_ohos";
import { RTCRtpTransceiverDirection } from "libohos_webrtc.so";
import { ConstraintsMap } from "./ConstraintsMap";
import { DataMap } from "./ObjectType";

/**
 * Returns the peer connection id argument.
 * @param call 方法调用
 * @returns peerConnectionId 参数，缺失时返回空串
 */
export function getPeerConnectionId(call: MethodCall): string {
  return call.argument('peerConnectionId') ?? '';
}

/**
 * Returns the stream id argument.
 * @param call 方法调用
 * @returns streamId 参数，缺失时返回空串
 */
export function getStreamId(call: MethodCall): string {
  return call.argument('streamId') ?? '';
}

/**
 * Returns the label argument.
 * @param call 方法调用
 * @returns label 参数，缺失时返回空串
 */
export function getLabel(call: MethodCall): string {
  return call.argument('label') ?? '';
}

/**
 * Returns the track id argument.
 * @param call 方法调用
 * @returns trackId 参数，缺失时返回空串
 */
export function getTrackId(call: MethodCall): string {
  return call.argument('trackId') ?? '';
}

/**
 * Returns the data-channel id argument.
 * @param call 方法调用
 * @returns dataChannelId 参数，缺失时返回空串
 */
export function getDataChannelId(call: MethodCall): string {
  return call.argument('dataChannelId') ?? '';
}

/**
 * Returns the transceiver id argument.
 * @param call 方法调用
 * @returns transceiverId 参数，缺失时返回空串
 */
export function getTransceiverId(call: MethodCall): string {
  return call.argument('transceiverId') ?? '';
}

/**
 * Returns the RTP sender id argument.
 * @param call 方法调用
 * @returns rtpSenderId 参数，缺失时返回空串
 */
export function getRtpSenderId(call: MethodCall): string {
  return call.argument('rtpSenderId') ?? '';
}

/**
 * Returns the sender id argument.
 * @param call 方法调用
 * @returns senderId 参数，缺失时返回空串
 */
export function getSenderId(call: MethodCall): string {
  return call.argument('senderId') ?? '';
}

/**
 * Returns the type argument.
 * @param call 方法调用
 * @returns type 参数，缺失时返回空串
 */
export function getType(call: MethodCall): string {
  return call.argument('type') ?? '';
}

/**
 * Returns the DTMF tone argument.
 * @param call 方法调用
 * @returns tone 参数，缺失时返回空串
 */
export function getTone(call: MethodCall): string {
  return call.argument('tone') ?? '';
}

/**
 * Returns the requested transceiver direction.
 * @param call 方法调用
 * @returns direction 参数，缺失时默认 sendrecv
 */
export function getDirection(call: MethodCall): RTCRtpTransceiverDirection {
  return call.argument('direction') ?? 'sendrecv';
}

/**
 * Returns the stream-id list argument.
 * @param call 方法调用
 * @returns streamIds 参数，缺失时返回空数组
 */
export function getStreamIds(call: MethodCall): string[] {
  return call.argument('streamIds') ?? [];
}

/**
 * Returns the optional DTMF duration.
 * @param call 方法调用
 * @returns duration 参数，未提供或类型非法时为 undefined
 */
export function getDuration(call: MethodCall): number | undefined {
  let duration: number = call.argument('duration');
  // 运行时类型验证：duration 必须为 number（或未提供），非法类型返回 undefined
  if (duration === null || duration === undefined) {
    return undefined;
  }
  return typeof duration === 'number' && !isNaN(duration) ? duration : undefined;
}

/**
 * Returns the optional DTMF inter-tone gap.
 * @param call 方法调用
 * @returns gap 参数，未提供或类型非法时为 undefined
 */
export function getGap(call: MethodCall): number | undefined {
  let gap: number = call.argument('gap');
  // 运行时类型验证：gap 必须为 number（或未提供），非法类型返回 undefined
  if (gap === null || gap === undefined) {
    return undefined;
  }
  return typeof gap === 'number' && !isNaN(gap) ? gap : undefined;
}

/**
 * Returns the constraints argument as a safe wrapper.
 * @param call 方法调用
 * @returns constraints 参数包装后的 ConstraintsMap
 */
export function getConstraintsMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('constraints'));
}

/**
 * Returns the options argument as a safe wrapper.
 * @param call 方法调用
 * @returns options 参数包装后的 ConstraintsMap
 */
export function getOptionsMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('options'));
}

/**
 * Returns the RTC configuration argument as a safe wrapper.
 * @param call 方法调用
 * @returns configuration 参数包装后的 ConstraintsMap
 */
export function getConfigurationMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('configuration'));
}

/**
 * Returns the session description argument as a safe wrapper.
 * @param call 方法调用
 * @returns description 参数包装后的 ConstraintsMap
 */
export function getDescriptionMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('description'));
}

/**
 * Returns the ICE candidate argument as a safe wrapper.
 * @param call 方法调用
 * @returns candidate 参数包装后的 ConstraintsMap
 */
export function getCandidateMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('candidate'));
}

/**
 * Returns data-channel initialization options as a safe wrapper.
 * @param call 方法调用
 * @returns dataChannelDict 参数包装后的 ConstraintsMap
 */
export function getDataChannelDictMap(call: MethodCall): ConstraintsMap {
  return constructMap(call.argument('dataChannelDict'));
}

/**
 * Wraps method-channel data in a null-safe constraints accessor.
 * @param map 原始数据 Map
 * @returns 包装后的 ConstraintsMap
 */
export function constructMap(map: DataMap): ConstraintsMap {
  return new ConstraintsMap(map);
}
