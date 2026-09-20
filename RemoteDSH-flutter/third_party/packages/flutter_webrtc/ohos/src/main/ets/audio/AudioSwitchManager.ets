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

import { audio } from '@kit.AudioKit';
import { Log } from '@ohos/flutter_ohos';
import { JSON } from '@kit.ArkTS';
import { DataMap, ObjectType } from '../utils/ObjectType';
import {
  AudioCapturerSamplesReadyEvent,
  AudioDeviceModule,
  AudioDeviceModuleOptions,
  AudioErrorEvent,
  AudioStateChangeEvent
} from 'libohos_webrtc.so';
import { isNotEmpty } from '../utils/Utils';
import { ConstraintsMap } from '../utils/ConstraintsMap';
import { BusinessError } from '@kit.BasicServicesKit';
import { resolveSourceType, resolveStreamUsage } from './AudioConfigurationMapper';
import { common } from '@kit.AbilityKit';

const TAG: string = 'AudioSwitchManager';

export default class AudioSwitchManager {
  private static instance: AudioSwitchManager | null = null;
  private audioManager: audio.AudioManager;
  private audioRoutingManager: audio.AudioRoutingManager;
  private audioRenderer: audio.AudioRenderer | null = null;
  private audioCapturer: audio.AudioCapturer | null = null;
  private activeCount: number = 0;
  private activeOwners: Set<string> = new Set<string>();
  private rendererOperationInProgress: boolean = false;
  private rendererStarted: boolean = false;
  private interruptSubscribed: boolean = false;
  private preferOutputSubscribed: boolean = false;
  private audioInterruptCallback: ((interruptEvent: audio.InterruptEvent) => void) | null = null;
  private preferOutputCallback: ((desc: audio.AudioDeviceDescriptors) => void) | null = null;
  private context?: common.Context;
  private adm?: AudioDeviceModule;
  // 构造器中 createAudioRenderer/createAudioCapturer 是异步的，追踪其完成 Promise，
  // 供 createAudioDeviceModule 等依赖点 await，避免在 renderer/capturer 就绪前访问。
  private readyPromise: Promise<void>;
  // 异步初始化（renderer/capturer）失败时记录错误，whenReady() 时重新抛出，
  // 供 createAudioDeviceModule → initialize 路径将初始化失败传播到 Flutter 层，
  // 避免音频功能静默不可用。
  private initError: Error | null = null;
  // destroy() 可能与异步 renderer/capturer 创建交错。销毁标志与代次号确保
  // 迟到的 Promise 结果不会重新写回已释放实例，并会立即释放刚创建的系统资源。
  private destroyed: boolean = false;
  private rendererGeneration: number = 0;
  private capturerGeneration: number = 0;
  private audioStreamInfo: audio.AudioStreamInfo = {
    samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_48000,
    channels: audio.AudioChannel.CHANNEL_2,
    sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
    encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
  };
  private audioRendererInfo: audio.AudioRendererInfo = {
    usage: audio.StreamUsage.STREAM_USAGE_UNKNOWN,
    rendererFlags: 0
  };
  private audioCapturerInfo: audio.AudioCapturerInfo = {
    source: audio.SourceType.SOURCE_TYPE_MIC,
    capturerFlags: 0
  };

  /**
   * 构造 AudioSwitchManager：同步获取 AudioManager / AudioRoutingManager，
   * 并异步创建 AudioRenderer 与 AudioCapturer（Promise.all 追踪完成状态）。
   *
   * 注意：构造器本身不能声明为 async，因此异步初始化的完成/失败通过 whenReady() 暴露——
   * 依赖 renderer/capturer 就绪的访问点（如 createAudioDeviceModule）必须先 await whenReady()，
   * 否则首次访问可能命中 null 时序窗口。
   * @throws 初始化失败不在此处抛出；错误记录到 initError，由 whenReady() 重新抛出。
   *           调用方必须通过 whenReady() 检查初始化结果，避免静默失败。
   */
  constructor() {
    this.audioManager = audio.getAudioManager();
    this.audioRoutingManager = this.audioManager.getRoutingManager();
    // 异步创建 renderer/capturer，用 Promise.all 追踪完成状态。
    // start()/stop()/createAudioDeviceModule() 等访问点均已对 null 做防护，
    // 且 createAudioDeviceModule 会 await whenReady()，确保 ADM 创建前就绪。
    this.readyPromise = Promise.all([this.createAudioRenderer(), this.createAudioCapturer()])
      .then((): void => {
        Log.d(TAG, 'AudioSwitchManager initialized: renderer & capturer ready');
      })
      .catch((error: BusinessError): void => {
        Log.e(TAG, 'AudioSwitchManager init failed: ' + JSON.stringify(error));
        this.initError = new Error('AudioSwitchManager init failed: ' + JSON.stringify(error));
      });
  }

  /**
   * 等待构造器中异步创建的 renderer/capturer 完成。
   * 依赖 audioRenderer/audioCapturer 的操作（如 createAudioDeviceModule）应先 await 此方法，
   * 消除首次访问时可能为 null 的时序窗口。
   * @returns 初始化完成的 Promise
   */
  whenReady(): Promise<void> {
    // 初始化失败时重新抛出存储的错误，使 createAudioDeviceModule → initialize
    // 调用链将音频初始化失败传播到 Flutter 层。
    if (this.initError) {
      return Promise.reject(this.initError);
    }
    return this.readyPromise;
  }

  /** Returns the process-wide audio manager instance. */
  /**
   * 获取进程级单例实例。
   *
   * ArkTS 运行在单线程事件循环模型中，check-then-act 模式天然安全——不存在
   * 并发 getInstance() 调用交错的风险。在多 Flutter Engine 场景下（未来扩展），
   * 应通过 Engine 级别的音频管理器替代此进程单例；当前单 Engine 架构下本实现安全。
   * @returns AudioSwitchManager 单例实例
   */
  public static getInstance(): AudioSwitchManager {
    if (!AudioSwitchManager.instance) {
      AudioSwitchManager.instance = new AudioSwitchManager();
    }
    return AudioSwitchManager.instance;
  }

  /**
   * 设置应用上下文。修复此前 `this.context = this.context` 自赋值
   * 导致传入 context 被丢弃的缺陷。
   * @param context 应用上下文
   */
  setContext(context: common.Context): void {
    this.context = context;
  }

  /**
   * 返回当前实例但不触发创建，用于只在音频管理器已初始化时执行的可选操作。
   * @returns 已创建的实例，尚未初始化时返回 null
   */
  static getExistingInstance(): AudioSwitchManager | null {
    return AudioSwitchManager.instance;
  }

  /** Returns the current WebRTC audio device module. */
  getAudioDeviceModule(): AudioDeviceModule | undefined {
    return this.adm;
  }

  /**
   * 创建 AudioRenderer 并订阅音频打断事件。
   * 创建新实例前先取消旧实例的事件订阅并 release，避免重复注册与资源泄漏。
   */
  async createAudioRenderer(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    let generation: number = ++this.rendererGeneration;
    // 先清理旧的 renderer 及其事件订阅
    this.releaseAudioRenderer();
    let audioRendererOptions: audio.AudioRendererOptions = {
      streamInfo: this.audioStreamInfo,
      rendererInfo: this.audioRendererInfo
    };
    try {
      let renderer: audio.AudioRenderer = await audio.createAudioRenderer(audioRendererOptions);
      if (this.destroyed || generation !== this.rendererGeneration) {
        await this.releaseDetachedRenderer(renderer);
        return;
      }
      this.audioRenderer = renderer;
      this.rendererStarted = false;
      this.onAudioInterrupt();
      this.reconcileRendererState();
    } catch (error) {
      Log.e(TAG, 'createAudioRenderer error , msg: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建 AudioCapturer。创建新实例前先 release 旧实例，避免资源泄漏。
   */
  async createAudioCapturer(): Promise<void> {
    if (this.destroyed) {
      return;
    }
    let generation: number = ++this.capturerGeneration;
    this.releaseAudioCapturer();
    let audioCapturerOptions: audio.AudioCapturerOptions = {
      streamInfo: this.audioStreamInfo,
      capturerInfo: this.audioCapturerInfo
    };
    try {
      let capturer: audio.AudioCapturer = await audio.createAudioCapturer(audioCapturerOptions);
      if (this.destroyed || generation !== this.capturerGeneration) {
        await this.releaseDetachedCapturer(capturer);
        return;
      }
      this.audioCapturer = capturer;
    } catch (error) {
      Log.e(TAG, 'createAudioCapturer error , msg: ' + JSON.stringify(error));
    }
  }

  /** 取消订阅并释放 AudioRenderer。 */
  private releaseAudioRenderer(): void {
    this.unsubscribePreferredOutput();
    if (this.audioRenderer) {
      let interruptCallback: ((interruptEvent: audio.InterruptEvent) => void) | null = this.audioInterruptCallback;
      if (this.interruptSubscribed && interruptCallback) {
        try {
          this.audioRenderer.off('audioInterrupt', interruptCallback);
        } catch (error) {
          Log.e(TAG, 'audioRenderer.off(audioInterrupt) error: ' + JSON.stringify(error));
        }
        this.interruptSubscribed = false;
        this.audioInterruptCallback = null;
      }
      try {
        this.audioRenderer.stop();
      } catch (error) {
        Log.e(TAG, 'audioRenderer.stop error: ' + JSON.stringify(error));
      }
      try {
        this.audioRenderer.release();
      } catch (error) {
        Log.e(TAG, 'audioRenderer.release error: ' + JSON.stringify(error));
      }
      this.audioRenderer = null;
      this.rendererStarted = false;
      this.rendererOperationInProgress = false;
    }
  }

  /** 停止并释放 AudioCapturer。 */
  private releaseAudioCapturer(): void {
    if (this.audioCapturer) {
      try {
        this.audioCapturer.stop();
      } catch (error) {
        Log.e(TAG, 'audioCapturer.stop error: ' + JSON.stringify(error));
      }
      try {
        this.audioCapturer.release();
      } catch (error) {
        Log.e(TAG, 'audioCapturer.release error: ' + JSON.stringify(error));
      }
      this.audioCapturer = null;
    }
  }

  /** 取消首选输出设备订阅；与 onPreferOutputDeviceChangeForRendererInfo() 严格成对。 */
  private unsubscribePreferredOutput(): void {
    let callback: ((desc: audio.AudioDeviceDescriptors) => void) | null = this.preferOutputCallback;
    if (this.preferOutputSubscribed && callback) {
      try {
        this.audioRoutingManager.off('preferOutputDeviceChangeForRendererInfo', callback);
      } catch (error) {
        Log.e(TAG, 'off preferOutputDeviceChangeForRendererInfo error: ' + JSON.stringify(error));
      }
    }
    this.preferOutputSubscribed = false;
    this.preferOutputCallback = null;
  }

  /** 释放一个尚未挂载到当前实例的迟到 AudioRenderer。 */
  private async releaseDetachedRenderer(renderer: audio.AudioRenderer): Promise<void> {
    try {
      await renderer.stop();
    } catch (error) {
      Log.w(TAG, 'late audioRenderer.stop failed: ' + JSON.stringify(error));
    }
    try {
      await renderer.release();
    } catch (error) {
      Log.e(TAG, 'late audioRenderer.release failed: ' + JSON.stringify(error));
    }
  }

  /** 释放一个尚未挂载到当前实例的迟到 AudioCapturer。 */
  private async releaseDetachedCapturer(capturer: audio.AudioCapturer): Promise<void> {
    try {
      await capturer.stop();
    } catch (error) {
      Log.w(TAG, 'late audioCapturer.stop failed: ' + JSON.stringify(error));
    }
    try {
      await capturer.release();
    } catch (error) {
      Log.e(TAG, 'late audioCapturer.release failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建 AudioDeviceModule 并注册 5 个回调。
   * 回调改为静态命名函数，不在闭包中捕获 this，避免形成
   * AudioSwitchManager -> adm -> 回调(闭包) -> AudioSwitchManager 的循环引用。
   * 创建新实例前先释放旧实例及其回调。
   */
  async createAudioDeviceModule(): Promise<void> {
    // 确保 renderer/capturer 已就绪，消除首次访问时序窗口
    await this.whenReady();
    this.releaseAudioDeviceModule();
    let options: AudioDeviceModuleOptions = {
      useStereoInput: true,
      useStereoOutput: true,
      useHardwareAcousticEchoCanceler: true,
      useHardwareNoiseSuppressor: true
    };
    this.adm = new AudioDeviceModule(options);
    this.adm.oncapturererror = AudioSwitchManager.onCapturerError;
    this.adm.oncapturerstatechange = AudioSwitchManager.onCapturerStateChange;
    this.adm.oncapturersamplesready = AudioSwitchManager.onCapturerSamplesReady;
    this.adm.onrenderererror = AudioSwitchManager.onRendererError;
    this.adm.onrendererstatechange = AudioSwitchManager.onRendererStateChange;
    Log.d(TAG, 'this.adm: ' + JSON.stringify(this.adm));
  }

  /** 释放 AudioDeviceModule 及其回调。 */
  private releaseAudioDeviceModule(): void {
    if (this.adm) {
      this.adm.oncapturererror = null;
      this.adm.oncapturerstatechange = null;
      this.adm.oncapturersamplesready = null;
      this.adm.onrenderererror = null;
      this.adm.onrendererstatechange = null;
      this.adm = undefined;
    }
  }

  // ---- ADM 回调：静态方法，不捕获 this，仅记录日志 ----
  /** Logs native audio capturer errors. */
  static onCapturerError(event: AudioErrorEvent): void {
    Log.e(TAG, 'oncapturererror: ' + JSON.stringify(event));
  }

  /** Logs native audio capturer state changes. */
  static onCapturerStateChange(event: AudioStateChangeEvent): void {
    Log.e(TAG, 'oncapturerstatechange: ' + JSON.stringify(event));
  }

  /** Receives native capturer sample notifications. */
  static onCapturerSamplesReady(event: AudioCapturerSamplesReadyEvent): void {
    Log.e(TAG, 'oncapturersamplesready: ' + JSON.stringify(event));
  }

  /** Logs native audio renderer errors. */
  static onRendererError(event: AudioErrorEvent): void {
    Log.e(TAG, 'onrenderererror: ' + JSON.stringify(event));
  }

  /** Logs native audio renderer state changes. */
  static onRendererStateChange(event: AudioStateChangeEvent): void {
    Log.e(TAG, 'onrendererstatechange: ' + JSON.stringify(event));
  }

  /**
   * 启动音频渲染。使用引用计数，仅当首个 PeerConnection 调用时真正 start，
   * 避免多 PC 场景下重复启动或提前停止导致音频状态不一致。
   * @param ownerId 唯一的本地或远端音频轨道所有者标识
   */
  start(ownerId: string): void {
    if (this.destroyed || this.activeOwners.has(ownerId)) {
      return;
    }
    this.activeOwners.add(ownerId);
    this.activeCount = this.activeOwners.size;
    this.reconcileRendererState();
  }

  /**
   * 停止音频渲染。仅当最后一个活跃 PeerConnection 调用时真正 stop。
   * @param ownerId 与 start 时一致的音频轨道所有者标识
   */
  stop(ownerId: string): void {
    this.activeOwners.delete(ownerId);
    this.activeCount = this.activeOwners.size;
    this.reconcileRendererState();
  }

  /**
   * 将异步 start/stop 串行化，并在操作完成后重新核对期望状态。
   * 即使 start 过程中收到 stop（或反向交错），最终状态也与 activeOwners 一致。
   */
  private reconcileRendererState(): void {
    let renderer: audio.AudioRenderer | null = this.audioRenderer;
    if (this.destroyed || !renderer || this.rendererOperationInProgress) {
      return;
    }
    let shouldStart: boolean = this.activeOwners.size > 0;
    if (shouldStart === this.rendererStarted) {
      return;
    }
    this.rendererOperationInProgress = true;
    let operation: Promise<void> = shouldStart ? renderer.start() : renderer.stop();
    operation.then((): void => {
      // renderer 可能已在等待期间被重建；仅更新仍为当前实例的状态。
      if (this.audioRenderer === renderer) {
        this.rendererStarted = shouldStart;
      }
      this.rendererOperationInProgress = false;
      this.reconcileRendererState();
    }).catch((error: BusinessError): void => {
      Log.e(TAG, `Renderer ${shouldStart ? 'start' : 'stop'} error: ${JSON.stringify(error)}`);
      this.rendererOperationInProgress = false;
      // 失败时仅在等待期间期望状态发生反转才继续协调，避免硬件持续失败时
      // 形成无延迟 Promise 重试循环。
      let desiredStateChanged: boolean = (this.activeOwners.size > 0) !== shouldStart;
      if (desiredStateChanged) {
        this.reconcileRendererState();
      }
    });
  }

  /**
   * 完整释放单例持有的所有资源（audioRenderer/audioCapturer/ADM）并将静态 instance 置空。
   * 应在插件 onDetachedFromEngine 时调用，确保引擎重新附加时不会携带过期状态。
   */
  static destroy(): void {
    if (AudioSwitchManager.instance) {
      let mgr: AudioSwitchManager = AudioSwitchManager.instance;
      // 先阻止所有 pending Promise 回写，再释放当前已经挂载的资源。
      mgr.destroyed = true;
      mgr.rendererGeneration++;
      mgr.capturerGeneration++;
      mgr.releaseAudioRenderer();
      mgr.releaseAudioCapturer();
      // 释放 ADM 及其回调，断开 adm -> 回调 -> this 循环引用
      mgr.releaseAudioDeviceModule();
      mgr.activeOwners.clear();
      mgr.activeCount = 0;
      mgr.rendererOperationInProgress = false;
    }
    AudioSwitchManager.instance = null;
  }

  /**
   * 设置麦克风静音状态。
   * @param mute true 静音，false 取消静音
   */
  setMicrophoneMute(mute: boolean): void {
    if (!this.adm) {
      Log.w(TAG, 'setMicrophoneMute: ADM is null, operation skipped');
      return;
    }
    try {
      this.adm.setMicrophoneMute(mute);
    } catch (error) {
      Log.e(TAG, 'setMicrophoneMute: adm call failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 设置扬声器静音状态。
   * @param mute true 静音，false 取消静音
   * @returns ADM 为空时返回 false 表示操作未执行
   */
  setSpeakerMute(mute: boolean): boolean {
    if (!this.adm) {
      Log.w(TAG, 'setSpeakerMute: ADM is null, operation skipped');
      return false;
    }
    try {
      this.adm.setSpeakerMute(mute);
    } catch (error) {
      Log.e(TAG, 'setSpeakerMute: adm.setSpeakerMute failed: ' + JSON.stringify(error));
      return false;
    }
    return true;
  }

  /**
   * Enables or disables the native noise suppressor.
   * @param enabled true to enable native noise suppression
   * @returns whether the native module accepted the requested state
   */
  setNoiseSuppressorEnabled(enabled: boolean): boolean {
    if (!this.adm) {
      Log.w(TAG, 'setNoiseSuppressorEnabled: ADM still null after lazy init');
      return false;
    }
    try {
      return this.adm.setNoiseSuppressorEnabled(enabled);
    } catch (error) {
      Log.e(TAG, 'setNoiseSuppressorEnabled: adm call failed: ' + JSON.stringify(error));
      return false;
    }
  }

  /** Reports native acoustic echo cancellation support. */
  isBuiltInAcousticEchoCancelerSupported(): boolean {
    // AudioDeviceModule 的 isBuiltIn* 方法为静态方法，无需 adm 实例
    try {
      return AudioDeviceModule.isBuiltInAcousticEchoCancelerSupported();
    } catch (error) {
      Log.e(TAG, 'isBuiltInAcousticEchoCancelerSupported error: ' + JSON.stringify(error));
      return false;
    }
  }

  /** Reports native noise suppression support. */
  isBuiltInNoiseSuppressorSupported(): boolean {
    // AudioDeviceModule 的 isBuiltIn* 方法为静态方法，无需 adm 实例
    try {
      return AudioDeviceModule.isBuiltInNoiseSuppressorSupported();
    } catch (error) {
      Log.e(TAG, 'isBuiltInNoiseSuppressorSupported error: ' + JSON.stringify(error));
      return false;
    }
  }

  /**
   * 获取音频输出设备列表。
   * @returns 输出设备描述符数组
   */
  getAudioOutputDevices(): audio.AudioDeviceDescriptors {
    return this.audioRoutingManager?.getDevicesSync(audio.DeviceFlag.OUTPUT_DEVICES_FLAG);
  }

  /**
   * 获取全部音频设备列表（输入+输出）。
   * @returns 全部设备描述符数组
   */
  getAllAudioDevices(): audio.AudioDeviceDescriptors {
    return this.audioRoutingManager?.getDevicesSync(audio.DeviceFlag.ALL_DEVICES_FLAG);
  }

  /**
   * 选择音频输出设备：按 deviceId 查找设备后切换通信设备。
   * @param deviceId 目标输出设备 id
   */
  selectAudioOutput(deviceId: number): void {
    let device: audio.AudioDeviceDescriptor | undefined =
      this.getAudioOutputDevices()?.find((d: audio.AudioDeviceDescriptor) => d.id === deviceId);
    if (!device) {
      Log.w(TAG, 'selectAudioOutput, Device with id ' + deviceId + ' not found');
      return;
    }
    Log.d(TAG, 'selectAudioOutput deviceType = ' + device.deviceType);
    this.setCommunicationDevice(device.deviceType);
  }

  /**
   * 设置当前通信设备（路由到指定 deviceType）。
   * @param deviceType 目标设备类型
   */
  setCommunicationDevice(deviceType: number): void {
    this.audioRoutingManager?.setCommunicationDevice(deviceType, this.activeCount > 0).then(() => {
      Log.d(TAG, 'setCommunicationDevice then deviceType=' + deviceType);
    }).catch(() => {
      Log.e(TAG, 'setCommunicationDevice catch deviceType=' + deviceType);
    });
  }

  /**
   * 启用/禁用扬声器：启用时路由到扬声器，禁用时切回首个非扬声器设备。
   * @param enable true 启用扬声器，false 切回其它输出设备
   */
  enableSpeakerphone(enable: boolean): void {
    if (enable) {
      this.setCommunicationDevice(audio.DeviceType.SPEAKER);
    } else {
      let devices: audio.AudioDeviceDescriptors = this.getAudioOutputDevices();
      if (!devices || devices.length === 0) {
        Log.e(TAG, 'enableSpeakerphone, no devices found');
        return;
      }
      let device: audio.AudioDeviceDescriptor | undefined =
        devices?.find((d: audio.AudioDeviceDescriptor) => d.deviceType !== audio.DeviceType.SPEAKER);
      this.setCommunicationDevice(device?.deviceType ?? devices[0].deviceType);
    }
  }

  /**
   * 启用扬声器但优先选择蓝牙/有线耳机：存在蓝牙 SCO 或有线耳机时切到该设备，
   * 否则保持当前输出。
   */
  enableSpeakerButPreferBluetooth(): void {
    let devices: audio.AudioDeviceDescriptors = this.getAllAudioDevices();
    if (!devices || devices.length === 0) {
      Log.w(TAG, 'enableSpeakerButPreferBluetooth, No audio devices available');
      return;
    }
    let audioDevice: audio.AudioDeviceDescriptor | undefined =
      devices.find((d: audio.AudioDeviceDescriptor) => d.deviceType === audio.DeviceType.BLUETOOTH_SCO ||
        d.deviceType === audio.DeviceType.WIRED_HEADSET);
    if (audioDevice) {
      // selectAudioOutput 按 deviceId 查找设备，必须传设备 id 而非 deviceType，
      // 否则按 deviceType 当作 id 查找会失败而静默放弃切换。
      this.selectAudioOutput(audioDevice.id);
    }
  }

  /**
   * 获取音频输入设备列表。
   * @returns 输入设备描述符数组
   */
  getAudioInputDevices(): audio.AudioDeviceDescriptors {
    return this.audioRoutingManager?.getDevicesSync(audio.DeviceFlag.INPUT_DEVICES_FLAG);
  }

  /**
   * 选择音频输入设备：按 deviceId 查找输入设备后切换通信设备。
   * 对应 Dart 层 selectAudioInput / setPreferredInputDevice。
   * @param deviceId 目标输入设备 id
   */
  selectAudioInput(deviceId: number): void {
    let device: audio.AudioDeviceDescriptor | undefined =
      this.getAudioInputDevices()?.find((d: audio.AudioDeviceDescriptor) => d.id === deviceId);
    if (!device) {
      return;
    }
    Log.d(TAG, 'selectAudioInput deviceType = ' + device.deviceType);
    this.setCommunicationDevice(device.deviceType);
  }

  /**
   * Applies OHOS audio renderer and capturer configuration.
   * @param configuration 约束集合，含 ohosStreamUsage、ohosSourceType 等 OHOS 音频配置键
   */
  setAudioConfiguration(configuration: ConstraintsMap): void {
    if (configuration.getType('ohosStreamUsage') === ObjectType.STRING) {
      this.setStreamUsage(configuration.getString('ohosStreamUsage'));
    }
    if (configuration.getType('ohosSourceType') === ObjectType.STRING) {
      this.setSourceType(configuration.getString('ohosSourceType'));
    }

    // createAudioRenderer/createAudioCapturer 是异步重建，内部已 try-catch 并记录错误，
    // 这里将重建 Promise 串入 readyPromise 链并附加 .catch，避免 fire-and-forget
    // 导致 ready 状态与重建完成不同步。
    let rendererP: Promise<void> = this.createAudioRenderer();
    let capturerP: Promise<void> = this.createAudioCapturer();
    // renderer/capturer 重建后必须重建 ADM，否则 ADM 内部 native 指针仍指向
    // 已释放的旧 renderer/capturer，后续 setSpeakerMute 等调用会导致 SIGSEGV。
    this.readyPromise = Promise.all([rendererP, capturerP])
      .then(async () => {
        await this.createAudioDeviceModule();
      })
      .catch((error: BusinessError) => {
        Log.e(TAG, 'setAudioConfiguration recreate failed: ' + JSON.stringify(error));
      });
  }

  /** Applies a native renderer stream usage when the name is recognized. */
  setStreamUsage(value: string): void {
    let streamUsage: audio.StreamUsage | undefined = resolveStreamUsage(value);
    if (streamUsage !== undefined) {
      this.audioRendererInfo.usage = streamUsage;
    }
  }

  /** Applies a native capturer source type when the name is recognized. */
  setSourceType(value: string): void {
    let sourceType: audio.SourceType | undefined = resolveSourceType(value);
    if (sourceType !== undefined) {
      this.audioCapturerInfo.source = sourceType;
    }
  }

  /** 注册一次音频打断监听。 */
  async onAudioInterrupt(): Promise<void> {
    if (!this.audioRenderer || this.interruptSubscribed) {
      return;
    }
    this.audioInterruptCallback = (interruptEvent: audio.InterruptEvent) => {
      // 在发生音频打断事件时，audioRenderer 收到 interruptEvent 回调，
      // 此处可根据其内容做相应处理。
      Log.d(TAG, `onAudioInterrupt: interruptEvent.forceType=${interruptEvent.forceType}`);
      Log.d(TAG, `onAudioInterrupt: interruptEvent.hintType=${interruptEvent.hintType}`);
    };
    this.audioRenderer.on('audioInterrupt', this.audioInterruptCallback);
    this.interruptSubscribed = true;
  }

  /** 注册一次首选输出设备变更监听。 */
  async onPreferOutputDeviceChangeForRendererInfo(): Promise<void> {
    if (!this.audioRoutingManager || this.preferOutputSubscribed) {
      return;
    }
    this.preferOutputCallback = (desc: audio.AudioDeviceDescriptors) => {
      Log.d(TAG, `onPreferOutputDeviceChangeForRendererInfo device change To : ${desc[0].deviceType}`);
    };
    this.audioRoutingManager.on('preferOutputDeviceChangeForRendererInfo', this.audioRendererInfo,
      this.preferOutputCallback);
    this.preferOutputSubscribed = true;
  }
}
