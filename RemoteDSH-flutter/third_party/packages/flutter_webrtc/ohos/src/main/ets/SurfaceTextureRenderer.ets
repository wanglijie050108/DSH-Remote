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

import { TextureRegistry, SurfaceTextureEntry, Log } from '@ohos/flutter_ohos';
import { MediaStream, NativeVideoRenderer, MediaStreamTrack } from 'libohos_webrtc.so';
import {
  beginConfig,
  getCameraDevices,
  getCameraInput,
  getCameraManager,
  getCaptureSession,
  getPreviewOutput,
  getSupportedOutputCapability,
  setSessionCameraInput,
  setSessionPreviewOutput,
  startSession,
  stopSession,
  releaseCamera,
  isTorchSupported,
  setTorchMode,
  switchCamera
} from './utils/CameraStateManager';
import { common } from '@kit.AbilityKit';
import StateProvider from './StateProvider';

const TAG: string = 'FlutterWebRTCPlugin-SurfaceTextureRenderer';

export default class SurfaceTextureRenderer extends NativeVideoRenderer {
  private textures: TextureRegistry | null = null;
  private id: number = -1;
  private mediaStream: MediaStream | null = null;
  private ownerTag: string = '';
  private stateProvider: StateProvider | null = null;
  private surfaceTextureEntry: SurfaceTextureEntry | null = null;
  private renderer: NativeVideoRenderer | null = null;
  // dispose 标志：dispose 后拦截 setVideoTrack/startRender 等调用，
  // 避免操作已释放的原生渲染对象（与 FlutterRTCVideoRenderer 的保护模式一致）。
  private disposed: boolean = false;

  /**
   * 构造 SurfaceTextureRenderer：调用父类 NativeVideoRenderer 构造方法初始化原生渲染器骨架。
   * 实际的纹理入口、surfaceId 与渲染器实例在 surfaceCreated / startSession 时延迟绑定。
   * @param name 可选的渲染器名称（保留参数，当前实现未使用）
   */
  constructor(name?: string) {
    super();
  }

  /**
   * 设置状态提供者，用于向 Dart 层上报渲染器状态变更。
   * @param stateProvider - 状态提供者实例
   */
  setStateProvider(stateProvider: StateProvider): void {
    this.stateProvider = stateProvider;
  }

  /**
   * 响应创建事件，保存 SurfaceTextureEntry 并记录 surfaceId 日志。
   * @param entry - 由 Flutter 引擎创建的纹理入口对象
   */
  surfaceCreated(entry: SurfaceTextureEntry): void {
    this.surfaceTextureEntry = entry;
    try {
      let surfaceId: string = entry.getSurfaceId().toString();
      Log.d(TAG, 'surfaceCreated surfaceId: ' + surfaceId);
    } catch (error) {
      Log.e(TAG, 'surfaceCreated failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 设置要渲染的视频轨道。若渲染器已 dispose 则忽略调用。
   * @param track - 待渲染的 MediaStreamTrack，传 null 表示清除视频轨道
   */
  setVideoTrack(track: MediaStreamTrack | null): void {
    if (this.disposed) {
      Log.w(TAG, 'setVideoTrack ignored: renderer already disposed');
      return;
    }
    Log.d(TAG, 'setVideoTrack track.id: ' + track?.id);
    try {
      this.renderer?.setVideoTrack(track);
    } catch (error) {
      Log.e(TAG, 'setVideoTrack failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 开始渲染：启动相机采集会话。若渲染器已 dispose 则忽略调用。
   */
  startRender(): void {
    if (this.disposed) {
      Log.w(TAG, 'startRender ignored: renderer already disposed');
      return;
    }
    this.startSession();
  }

  /**
   * 停止渲染：停止相机采集会话并释放原生渲染器。
   */
  stopRender(): void {
    this.stopSession();
    try {
      this.renderer?.release();
    } catch (error) {
      Log.e(TAG, 'stopRender renderer release failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 释放 SurfaceTextureRenderer 持有的全部资源：停止渲染会话并置空对
   * surfaceTextureEntry、renderer、mediaStream、stateProvider 的引用，
   * 避免插件销毁后 native 资源与回调悬挂导致内存泄漏。
   * 父类 NativeVideoRenderer 为接口且未声明 dispose/release 回收钩子，
   * 故此处无需 super 调用，仅清理本类自身引用。
   * 幂等：重复调用直接返回。
   */
  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    try {
      this.stopRender();
    } catch (error) {
      Log.e(TAG, 'dispose stopRender failed: ' + JSON.stringify(error));
    }
    // SurfaceTextureEntry 的生命周期由 Flutter OHOS TextureRegistry 管理，
    // 此处置 null 移除本类对纹理入口的引用，由 TextureRegistry 在引擎卸载时统一回收。
    this.surfaceTextureEntry = null;
    this.renderer = null;
    this.mediaStream = null;
    this.stateProvider = null;
  }

  private startSession(): void {
    Log.d(TAG, `startSession`);
    try {
      getCameraManager(getContext());
    } catch (error) {
      Log.e(TAG, 'startSession getCameraManager failed: ' + JSON.stringify(error));
    }
    if (!this.surfaceTextureEntry) {
      Log.w(TAG, 'startSession skipped: surfaceTexture has not been created');
      return;
    }
    try {
      switchCamera(0, this.surfaceTextureEntry.getSurfaceId().toString(), 0);
    } catch (error) {
      Log.e(TAG, 'startSession switchCamera failed: ' + JSON.stringify(error));
    }
  }

  private stopSession(): void {
    Log.d(TAG, `stopSession`);
    try {
      releaseCamera();
    } catch (error) {
      Log.e(TAG, 'stopSession releaseCamera failed: ' + JSON.stringify(error));
    }
  }
}
