/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the 'Software'), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import { DataMap } from './ObjectType';
import { MediaStreamTrack } from 'libohos_webrtc.so';

/**
 * 将 MediaStreamTrack 序列化为 Flutter 期望的 Map。
 * label 统一使用 track.id（与 Android/iOS 对齐，不再按 remote 分支取 kind）；
 * readyState 统一标准化为 'live' / 'ended'，避免直接透传 native 枚举或 undefined。
 * @param track 媒体轨道
 * @param remote 是否为远端轨道，默认 false
 * @returns 序列化后的轨道 Map
 */
export function mediaStreamTrackToMap(track: MediaStreamTrack, remote: boolean = false): DataMap {
  let trackMap: DataMap = new Map();
  trackMap.set('enabled', track.enabled);
  trackMap.set('id', track.id);
  trackMap.set('kind', track.kind);
  // 与 Android/iOS 对齐：label 一律使用 track.id（唯一标识），而非 kind
  trackMap.set('label', track.id);
  trackMap.set('readyState', normalizeReadyState(track.readyState));
  trackMap.set('remote', remote);
  return trackMap;
}

/**
 * 将 native 轨道 readyState 标准化为 Flutter 期望的 'live' / 'ended'。
 * @param readyState native 就绪状态（可能为字符串或枚举）
 * @returns 标准化后的 'live' 或 'ended'
 */
function normalizeReadyState(readyState: string): string {
  if (readyState === 'ended') {
    return 'ended';
  }
  return 'live';
}
