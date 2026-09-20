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

import { MediaStream, MediaStreamTrack, PeerConnectionFactory } from 'libohos_webrtc.so';
import { BinaryMessenger } from '@ohos/flutter_ohos';
import type { Observer } from './WebRTCTypeAliases';
import { UIAbility, common } from '@kit.AbilityKit';

export default interface StateProvider {
  /** Registers a local stream. */
  putLocalStream(streamId: string, stream: MediaStream): boolean;

  /** Registers a local track. */
  putLocalTrack(trackId: string, track: MediaStreamTrack): boolean;

  /** Looks up a local track. */
  getLocalTrack(trackId: string): MediaStreamTrack | undefined;

  /** Allocates a unique stream id. */
  getNextStreamUUID(): string;

  /** Allocates a unique track id. */
  getNextTrackUUID(): string;

  /** Returns the lazily initialized peer connection factory. */
  getPeerConnectionFactory(): PeerConnectionFactory;

  /** Looks up a peer connection observer. */
  getPeerConnectionObserver(peerConnectionId: string): Observer | undefined;

  /** Returns the currently attached ability. */
  getAbility(): UIAbility | null;

  /** Returns the application context when attached. */
  getApplicationContext(): common.ApplicationContext | undefined;

  /** Returns the Flutter binary messenger. */
  getMessenger(): BinaryMessenger;
}
