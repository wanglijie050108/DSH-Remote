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

import type { ComponentHandler } from '../WebRTCTypeAliases';
import { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import { VideoRenderController } from './VideoRenderController';
import { Log } from '@ohos/flutter_ohos';

const TAG: string = 'FlutterWebRTCPlugin-[VideoRender]';

@Component
export struct VideoRender {
  @Prop params: Params
  // platformView stores the ComponentHandler; cast is safe in WebRTC video render context
  videoRenderHandler: ComponentHandler = this.params.platformView as ComponentHandler;
  private xComponentController: VideoRenderController = new VideoRenderController();

  /** ArkUI 生命周期：组件实例创建时触发，预留用于初始化。 */
  aboutToAppear(): void {
    // onSurfaceDestroyed 仅表示 XComponent SurfaceTexture 被销毁（旋转/配置变更），
    // 不代表 PlatformView 本身销毁。不应在此释放 methodChannel，
    // 否则新 SurfaceTexture 重建后 sendMessage 无法下发 surfaceId 到 Dart。
    this.xComponentController.setSurfaceDestroyedCallback((): void => {
      Log.d(TAG, 'onSurfaceDestroyed: SurfaceTexture destroyed (likely rotation), keeping methodChannel alive');
    });
  }

  /** ArkUI 生命周期：构建组件 UI 树，挂载 XComponent 并回调 surfaceId。 */
  build() {
    Column() {
      XComponent({
        type: XComponentType.SURFACE,
        controller: this.xComponentController
      })
        .width('100%')
        .height('100%')
        .onLoad((context?: object) => {
          this.videoRenderHandler.sendMessage(this.xComponentController.getXComponentSurfaceId());
        })
        .onDestroy(() => {
          Log.d(TAG, 'onDestroy');
          this.releaseResources();
        })
    }
    .height('100%')
    .width('100%')
  }

  /** Releases the platform-view channel and the controller callback. */
  private releaseResources(): void {
    this.xComponentController.setSurfaceDestroyedCallback(null);
    this.videoRenderHandler.dispose();
  }
}
