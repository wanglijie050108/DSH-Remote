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

import { Log } from '@ohos/flutter_ohos';

const TAG: string = 'FlutterWebRTCPlugin-[VideoRenderController]';

export class VideoRenderController extends XComponentController {
  private surfaceDestroyedCallback: (() => void) | null = null;

  /**
   * Registers the idempotent cleanup invoked when the XComponent SurfaceTexture is destroyed.
   * @param callback cleanup callback, or null to release the previous callback
   */
  setSurfaceDestroyedCallback(callback: (() => void) | null): void {
    this.surfaceDestroyedCallback = callback;
  }

  /**
   * XComponent 表面创建成功回调，surfaceId 可用于关联渲染图层。
   * @param surfaceId - XComponent 表面唯一标识符
   */
  onSurfaceCreated(surfaceId: string): void {
    Log.d(TAG, `onSurfaceCreated surfaceId: ${surfaceId}`);
  }

  /**
   * XComponent 表面尺寸变化回调。
   * @param surfaceId - XComponent 表面唯一标识符
   * @param rect - 新的表面尺寸和位置信息
   */
  onSurfaceChanged(surfaceId: string, rect: SurfaceRect): void {
    Log.d(TAG, `onSurfaceChanged surfaceId: ${surfaceId}, rect: ${JSON.stringify(rect)}`);
  }

  /**
   * XComponent 表面销毁回调，可在此释放关联的渲染资源。
   * @param surfaceId - XComponent 表面唯一标识符
   */
  onSurfaceDestroyed(surfaceId: string): void {
    Log.d(TAG, `onSurfaceDestroyed surfaceId: ${surfaceId}`);
    let callback: (() => void) | null = this.surfaceDestroyedCallback;
    this.surfaceDestroyedCallback = null;
    callback?.();
  }
}
