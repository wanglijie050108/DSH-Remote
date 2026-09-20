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
 
// 1. 系统 / Kit 导入
import { HashMap, JSON, PlainArray } from '@kit.ArkTS';
// 2. 第三方库导入（flutter_ohos / libohos_webrtc）
import { Log } from '@ohos/flutter_ohos';
import { MediaStream, MediaStreamTrack, PeerConnectionFactory } from 'libohos_webrtc.so';
// 3. 本地模块导入
import FlutterRTCFrameCryptor from './FlutterRTCFrameCryptor';
import FlutterRTCVideoRenderer from './FlutterRTCVideoRenderer';
import GetUserMediaImpl from './GetUserMediaImpl';
import { MediaStreamHandlers } from './MediaStreamHandlers';
import PeerConnectionObserver from './PeerConnectionObserver';
import { releaseCamera, resetCameraState } from './utils/CameraStateManager';

const TAG: string = 'FlutterWebRTCPlugin-PluginResourceDisposer';

export interface PluginResources {
  renders: PlainArray<FlutterRTCVideoRenderer>;
  localStreams: HashMap<string, MediaStream>;
  localTracks: HashMap<string, MediaStreamTrack>;
  peerConnections: HashMap<string, PeerConnectionObserver>;
  mediaStreamHandlers: MediaStreamHandlers | null;
  factory: PeerConnectionFactory | null;
  frameCryptor: FlutterRTCFrameCryptor;
  userMedia: GetUserMediaImpl | null;
}

/** Releases plugin-owned native resources in dependency order. */
export async function disposePluginResources(resources: PluginResources): Promise<void> {
  releaseRenderers(resources);
  for (let stream of resources.localStreams.values()) {
    resources.mediaStreamHandlers?.handleStreamDispose(undefined, stream);
  }
  for (let track of resources.localTracks.values()) {
    try {
      track.enabled = false;
      track.stop();
    } catch (error) {
      Log.e(TAG, 'track stop failed: ' + JSON.stringify(error));
    }
  }
  resources.localStreams.clear();
  resources.localTracks.clear();
  releasePeerConnections(resources);
  // PeerConnectionFactory 释放：libohos_webrtc.so 的 PeerConnectionFactory 接口
  // 仅暴露 startAecDump/stopAecDump，未提供 dispose/release 回收钩子（与 Android
  // 的 PeerConnectionFactory.dispose() 不同）。此处先停止 AEC dump 落盘，原生工厂
  // 的线程池/编解码器工厂等资源由 libohos_webrtc.so 在 ETS 引用断开后随 GC 回收；
  // 工厂引用本身的置空在 MethodCallHandlerImpl.dispose() 中完成。
  try {
    resources.factory?.stopAecDump();
  } catch (error) {
    Log.e(TAG, 'stopAecDump failed: ' + JSON.stringify(error));
  }
  // 相机 session 的 stop/release 为异步操作，必须 await 完成后再返回，
  // 否则 Ability 销毁后 cameraInput 的 error 回调可能访问已释放的 session 对象。
  try {
    await releaseCamera();
  } catch (error) {
    Log.e(TAG, 'releaseCamera failed: ' + JSON.stringify(error));
  }
  // 相机资源释放后丢弃模块级相机状态单例，避免引擎重新挂载时携带 stale 引用。
  resetCameraState();
  resources.frameCryptor.dispose();
  resources.userMedia?.dispose();
}

/**
 * 遍历并释放全部视频渲染器，随后清空 renders 缓存。
 * 单个渲染器 dispose 失败不影响其它渲染器的释放。
 * @param resources 插件资源集合
 */
function releaseRenderers(resources: PluginResources): void {
  for (let i = 0; i < resources.renders.length; i++) {
    let renderer: FlutterRTCVideoRenderer | undefined = resources.renders.getValueAt(i);
    if (renderer) {
      try {
        renderer.dispose();
      } catch (error) {
        Log.e(TAG, 'renderer dispose failed: ' + JSON.stringify(error));
      }
    }
  }
  resources.renders.clear();
}

/**
 * 遍历并释放全部 PeerConnection 观察者，随后清空 peerConnections 缓存。
 * 单个连接 dispose 失败不影响其它连接的释放。
 * @param resources 插件资源集合
 */
function releasePeerConnections(resources: PluginResources): void {
  for (let connection of resources.peerConnections.values()) {
    if (connection) {
      try {
        connection.dispose();
      } catch (error) {
        Log.e(TAG, 'peerConnection dispose failed: ' + JSON.stringify(error));
      }
    }
  }
  resources.peerConnections.clear();
}
