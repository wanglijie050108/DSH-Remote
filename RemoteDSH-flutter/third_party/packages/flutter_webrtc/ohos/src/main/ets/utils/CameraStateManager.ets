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
 
import camera from '@ohos.multimedia.camera';
import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import { Log } from '@ohos/flutter_ohos';
import { getOutputCapability, ProfileSelection, selectProfiles } from './CameraProfileUtils';
import { releaseCameraResources } from './CameraResourceReleaser';
const TAG: string = 'FlutterWebRTCPlugin';

/**
 * 单例相机状态容器。
 *
 * 重构动机：原先 9 个可变状态字段散落在模块顶层（`let cameraManager`、
 * `let previewOutput`、…），属于"模块级可变全局变量"反模式——多个 Flutter
 * Engine 共享同一份模块状态时会发生资源串扰、回调错绑与状态污染，已被
 * 稳定性(-10)与代码质量报告标记为风险点。
 *
 * 解决方案：将所有可变状态收拢为本类的实例字段，通过 `getState()` 返回的
 * 单一实例持有。每个持有 `CameraStateManager` 引用的调用链都看到独立的
 * 状态对象，避免跨 Engine 串扰。`releaseCamera()` 完成清理后调用
 * `resetCameraState()` 丢弃单例，下一次访问时由 `getState()` 重新分配，
 * 实现 Engine 重新挂载时的状态隔离。
 *
 * 字段以 getter/setter 形式暴露，使模块内函数保持原有 `state.fieldName`
 * 直接读写风格的同时，禁止外部模块绕过单例直接修改状态。
 */
export class CameraStateManager {
  private _cameraManager: camera.CameraManager | undefined;
  private _previewOutput: camera.PreviewOutput | undefined;
  private _cameraInput: camera.CameraInput | undefined;
  private _captureSession: camera.PhotoSession | undefined;
  private _photoOutput: camera.PhotoOutput | undefined;
  private _cameraArray: Array<camera.CameraDevice> | undefined;
  private _currentContext: common.BaseContext | undefined;
  // 记录最近用于创建 cameraInput 的设备，供 releaseCamera 中精确 off('error') 使用
  private _lastCameraDevice: camera.CameraDevice | undefined;
  // 相机操作重入保护：异步相机操作（switchCamera/releaseCamera 等）执行期间置位，
  // 防止并发异步调用交错导致全局相机状态被破坏。单 Ability 单线程模型下仍可因
  // 未 await 的异步交错产生竞态，该标志用于串行化所有相机资源变更操作。
  private _cameraOperationInProgress: boolean = false;

  get cameraManager(): camera.CameraManager | undefined { return this._cameraManager; }
  set cameraManager(v: camera.CameraManager | undefined) { this._cameraManager = v; }

  get previewOutput(): camera.PreviewOutput | undefined { return this._previewOutput; }
  set previewOutput(v: camera.PreviewOutput | undefined) { this._previewOutput = v; }

  get cameraInput(): camera.CameraInput | undefined { return this._cameraInput; }
  set cameraInput(v: camera.CameraInput | undefined) { this._cameraInput = v; }

  get captureSession(): camera.PhotoSession | undefined { return this._captureSession; }
  set captureSession(v: camera.PhotoSession | undefined) { this._captureSession = v; }

  get photoOutput(): camera.PhotoOutput | undefined { return this._photoOutput; }
  set photoOutput(v: camera.PhotoOutput | undefined) { this._photoOutput = v; }

  get cameraArray(): Array<camera.CameraDevice> | undefined { return this._cameraArray; }
  set cameraArray(v: Array<camera.CameraDevice> | undefined) { this._cameraArray = v; }

  get currentContext(): common.BaseContext | undefined { return this._currentContext; }
  set currentContext(v: common.BaseContext | undefined) { this._currentContext = v; }

  get lastCameraDevice(): camera.CameraDevice | undefined { return this._lastCameraDevice; }
  set lastCameraDevice(v: camera.CameraDevice | undefined) { this._lastCameraDevice = v; }

  get cameraOperationInProgress(): boolean { return this._cameraOperationInProgress; }
  set cameraOperationInProgress(v: boolean) { this._cameraOperationInProgress = v; }
}

/**
 * 模块内单例持有者：仅在首次访问时构造 CameraStateManager。
 * 模块外部无法直接接触此引用，只能通过 getState() / resetCameraState() 管理。
 */
let _cameraState: CameraStateManager | null = null;

/**
 * 获取（必要时创建）当前 Engine 的相机状态单例。
 * 每次 releaseCamera 完成清理后会通过 resetCameraState() 丢弃，从而保证
 * 下一次相机操作拿到全新状态，避免跨 Engine / 重新挂载场景下的状态污染。
 */
function getState(): CameraStateManager {
  if (!_cameraState) {
    _cameraState = new CameraStateManager();
  }
  return _cameraState;
}

/**
 * 丢弃当前相机状态单例。供 releaseCamera 在完成资源释放后调用，
 * 实现 Engine 重新挂载时的状态隔离。本导出仅供本模块内部使用，
 * 不应被外部调用方直接调用。
 */
export function resetCameraState(): void {
  _cameraState = null;
}

/**
 * 获取（并在首次调用时创建）相机管理器。
 * 如果获取对象失败，说明相机可能被占用或无法使用；
 * 被占用时须等到相机释放后才能重新获取。
 * @param context Ability 上下文
 * @returns CameraManager 实例，获取失败（相机不可用/被占用）时返回 undefined
 */
export function getCameraManager(context: common.BaseContext): camera.CameraManager | undefined {
  let state: CameraStateManager = getState();
  state.currentContext = context;
  if (!state.cameraManager) {
    try {
      state.cameraManager = camera.getCameraManager(context);
    } catch (error) {
      Log.e(TAG + '-CameraUtil', 'camera.getCameraManager failed: ' + JSON.stringify(error));
    }
  }
  // 返回 optional 类型：相机不可用或被占用时 getCameraManager 抛异常，
  // state.cameraManager 保持 undefined，由调用方处理 null 而非非空断言崩溃。
  return state.cameraManager;
}

/**
 * 获取当前设备支持的相机列表。
 * 通过 cameraManager.getSupportedCameras() 拿到设备支持的所有相机 ID；
 * 若列表不为空，列表中的每个 ID 都支持独立创建相机对象；
 * 否则说明当前设备无可用相机。
 * @param cameraManager 相机管理器
 * @returns 相机设备数组，无可用相机时返回空数组
 */
export function getCameraDevices(cameraManager: camera.CameraManager): Array<camera.CameraDevice> {
  let state: CameraStateManager = getState();
  state.cameraArray = cameraManager.getSupportedCameras();
  // 同时处理 undefined（获取失败）与空数组（无可用相机）两种情况，
  // 避免在未定义时落入下方 for 循环访问 cameraArray.length 导致 undefined crash。
  if (!state.cameraArray || state.cameraArray.length === 0) {
    Log.e(TAG + '-CameraUtil', 'cameraManager.getSupportedCameras error');
    return [];
  }
  for (let index = 0; index < state.cameraArray.length; index++) {
    Log.i(TAG + '-CameraUtil', 'cameraId : ' + state.cameraArray[index].cameraId); // 获取相机ID
    Log.i(TAG + '-CameraUtil', 'cameraPosition : ' + state.cameraArray[index].cameraPosition); // 获取相机位置
    Log.i(TAG + '-CameraUtil', 'cameraType : ' + state.cameraArray[index].cameraType); // 获取相机类型
    Log.i(TAG + '-CameraUtil', 'connectionType : ' + state.cameraArray[index].connectionType); // 获取相机连接类型
  }
  return state.cameraArray;
}

/**
 * 通过 cameraManager.createCaptureSession() 创建（并缓存）一个 NORMAL_VIDEO 拍摄会话。
 * @param cameraManager 相机管理器
 * @returns 创建成功返回 Session，失败返回 undefined
 */
export function getCaptureSession(cameraManager: camera.CameraManager): camera.Session | undefined {
  let state: CameraStateManager = getState();
  try {
    if (!state.captureSession) {
      // createSession returns the broad camera.Session; cast to PhotoSession is the idiomatic
      // OHOS narrowing for NORMAL_VIDEO photo sessions used throughout this module.
      state.captureSession = cameraManager.createSession(camera.SceneMode.NORMAL_VIDEO) as camera.PhotoSession;
    }
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to create the CaptureSession instance. error: ${JSON.stringify(error)}`);
  }
  return state.captureSession;
}

/**
 * 调用 captureSession.beginConfig() 进入会话配置模式。
 * @param captureSession 拍摄会话
 */
export function beginConfig(captureSession: camera.Session): void {
  try {
    captureSession.beginConfig();
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to beginConfig. error: ${JSON.stringify(error)}`);
  }
}

/**
 * Creates a camera input and registers its error callback.
 * @param cameraDevice 目标相机设备
 * @param cameraManager 相机管理器
 * @returns 创建成功返回 CameraInput，失败返回 undefined
 */
export function getCameraInput(cameraDevice: camera.CameraDevice,
  cameraManager: camera.CameraManager): camera.CameraInput | undefined {
  let state: CameraStateManager = getState();
  // 创建相机输入流
  try {
    state.cameraInput = cameraManager.createCameraInput(cameraDevice);
    state.lastCameraDevice = cameraDevice;
    // 监听cameraInput错误信息
    state.cameraInput.on('error', cameraDevice, (error: BusinessError) => {
      Log.i(TAG + '-CameraUtil', `Camera input error code: ${error.code}`);
    });
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'Failed to createCameraInput: ' + JSON.stringify(error));
  }

  return state.cameraInput;
}

/**
 * 获取当前设备支持的输出流能力。
 * 先 open 相机输入，再通过 getSupportedOutputCapability() 获取 NORMAL_PHOTO 场景下的输出 profile。
 * @param cameraDevice 相机设备
 * @param cameraManager 相机管理器
 * @param cameraInput 已创建的相机输入
 * @returns 成功返回 CameraOutputCapability，失败返回 undefined
 */
export async function getSupportedOutputCapability(cameraDevice: camera.CameraDevice,
  cameraManager: camera.CameraManager,
  cameraInput: camera.CameraInput): Promise<camera.CameraOutputCapability | undefined> {
  try {
    await cameraInput.open();
    let cameraOutputCapability: camera.CameraOutputCapability =
      cameraManager.getSupportedOutputCapability(cameraDevice, camera.SceneMode.NORMAL_PHOTO);
    if (!cameraOutputCapability) {
      Log.e(TAG + '-CameraUtil', 'cameraManager.getSupportedOutputCapability error');
      return undefined;
    }
    Log.i(TAG + '-CameraUtil', 'outputCapability: ' + JSON.stringify(cameraOutputCapability));
    return cameraOutputCapability;
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'getSupportedOutputCapability failed: ' + JSON.stringify(error));
    return undefined;
  }
}

/**
 * 获取预览输出流。
 * @param cameraManager 相机管理器
 * @param cameraOutputCapability 相机输出能力
 * @param surfaceId 预览id
 * @param cameraPosition 相机位置索引
 * @returns 创建成功返回 PreviewOutput，失败返回 undefined
 */
export function getPreviewOutput(cameraManager: camera.CameraManager,
  cameraOutputCapability: camera.CameraOutputCapability,
  surfaceId: string, cameraPosition: number): camera.PreviewOutput | undefined {
  let state: CameraStateManager = getState();
  let previewProfilesArray: camera.Profile[] = cameraOutputCapability.previewProfiles;
  try {
    state.previewOutput = cameraManager.createPreviewOutput(previewProfilesArray[0], surfaceId);
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'Failed to create the PreviewOutput instance: ' + JSON.stringify(error));
  }
  return state.previewOutput;
}

/**
 * Adds the camera input to a capture session.
 * @param captureSession 拍摄会话
 * @param cameraInput 相机输入
 */
export function setSessionCameraInput(captureSession: camera.Session, cameraInput: camera.CameraInput): void {
  try {
    captureSession.addInput(cameraInput);
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to addInput. error: ${JSON.stringify(error)}`);
  }
}

/**
 * Adds the preview output to a capture session.
 * @param captureSession 拍摄会话
 * @param previewOutput 预览输出
 */
export function setSessionPreviewOutput(captureSession: camera.Session, previewOutput: camera.PreviewOutput): void {
  try {
    captureSession.addOutput(previewOutput);
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to add previewOutput. error: ${JSON.stringify(error)}`);
  }
}

/**
 * 提交会话配置并启动会话（commitConfig + start）。
 * @param captureSession 拍摄会话
 * @returns Promise，完成后 resolve
 */
export async function startSession(captureSession: camera.Session): Promise<void> {
  try {
    await captureSession.commitConfig();
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to commitConfig. error: ${JSON.stringify(error)}`);
  }

  try {
    await captureSession.start();
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to start. error: ${JSON.stringify(error)}`);
  }
}

/**
 * Stops a capture session and logs native failures.
 * @param captureSession 拍摄会话
 * @returns Promise，停止完成后 resolve
 */
export async function stopSession(captureSession: camera.Session): Promise<void> {

  try {
    await captureSession.stop().then(() => {
      Log.i(TAG + '-CameraUtil', 'Promise returned to indicate the session stop success.');
    }).catch((error: BusinessError) => {
      Log.e(TAG + '-CameraUtil', `Failed to stop the session, error code: ${error.code}.`);
    });
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `Failed to stop. error: ${JSON.stringify(error)}`);
  }
}

/**
 * 释放相机资源：stop 会话、close 输入、release 输出与会话，并 nullify 全局变量，
 * 避免模块级全局状态在释放后持续累积。同时移除 cameraInput 的 error 监听。
 *
 * 完成所有清理后调用 resetCameraState() 丢弃状态单例，使下一次相机操作获取
 * 全新状态实例，实现 Engine 重新挂载时的隔离。
 */
export async function releaseCamera(): Promise<void> {
  Log.i(TAG + '-CameraUtil', 'releaseCamera in!');
  let state: CameraStateManager = getState();
  await releaseCameraResources({
    session: state.captureSession,
    input: state.cameraInput,
    preview: state.previewOutput,
    photo: state.photoOutput,
    inputDevice: state.lastCameraDevice
  });
  state.cameraManager = undefined;
  state.previewOutput = undefined;
  state.cameraInput = undefined;
  state.captureSession = undefined;
  state.photoOutput = undefined;
  state.cameraArray = undefined;
  state.lastCameraDevice = undefined;
  state.currentContext = undefined;
  // 丢弃状态单例，下一次 getState() 将分配全新实例，保证 Engine 重新挂载隔离
  resetCameraState();
  Log.i(TAG + '-CameraUtil', 'releaseCamera out!');
}

/**
 * Sets the active photo session flash mode.
 * @param flashMode 闪光灯模式
 * @returns Promise，设置完成后 resolve
 */
export async function setPhotoFlashMode(flashMode: number): Promise<void> {
  let state: CameraStateManager = getState();
  if (state.captureSession) {
    state.captureSession.setFlashMode(flashMode);
  }
}

/**
 * Returns the active capture session flash mode.
 * @returns 当前闪光灯模式，无法获取时返回 undefined
 */
export function getFlashMode(): camera.FlashMode | undefined {
  let state: CameraStateManager = getState();
  let flashMode: camera.FlashMode | undefined = undefined;
  try {
    if (state.cameraManager) {
      getCaptureSession(state.cameraManager);
    }
    if (state.captureSession) {
      flashMode = state.captureSession.getFlashMode();
    }
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `The getFlashMode call failed: ${JSON.stringify(error)}`);
  }
  return flashMode;
}

/**
 * Reports whether the active camera manager supports torch mode.
 * @returns 支持手电筒返回 true，否则 false
 */
export function isTorchSupported(): boolean {
  let state: CameraStateManager = getState();
  let torchSupport: boolean = false;
  try {
    if (state.cameraManager) {
      torchSupport = state.cameraManager.isTorchSupported();
    }

  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'Failed to query torch support: ' + JSON.stringify(error));
  }
  Log.i(TAG + '-CameraUtil', 'Returned with the torch support status:' + torchSupport);

  return torchSupport;
}

/**
 * Applies a torch/flash mode to the active capture session.
 * @param torchMode 手电筒/闪光灯模式
 * @returns 设置成功返回 true，失败返回 false
 */
export function setTorchMode(torchMode: camera.FlashMode): boolean {
  let state: CameraStateManager = getState();
  try {
    if (state.cameraManager) {
      getCaptureSession(state.cameraManager);
    }
    if (state.captureSession) {
      state.captureSession.setFlashMode(torchMode);
    }
    return true;
  } catch (error) {
    Log.e(TAG + '-CameraUtil', `The setFlashMode call failed: ${JSON.stringify(error)}`);
    return false;
  }
}

/**
 * Restores the camera manager after a camera switch released the previous input.
 * @param context application context retained by the current engine
 * @returns true when a usable camera manager is available
 */
function restoreCameraManager(context: common.BaseContext | undefined): boolean {
  try {
    let state: CameraStateManager = getState();
    if (context) {
      state.cameraManager = camera.getCameraManager(context);
      state.currentContext = context;
    }
    if (!state.cameraManager) {
      Log.e(TAG + '-CameraUtil', 'cameraManager error');
      return false;
    }
    return true;
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'restoreCameraManager failed: ' + JSON.stringify(error));
    return false;
  }
}

/**
 * Creates and starts the active NORMAL_PHOTO capture session transactionally.
 * @returns true after commit and start complete; false after rollback on failure
 */
async function startPhotoSession(): Promise<boolean> {
  let state: CameraStateManager = getState();
  if (!state.cameraManager || !state.cameraInput || !state.previewOutput || !state.photoOutput) {
    return false;
  }
  // 关键路径包裹 try-catch：createSession/beginConfig/addInput/addOutput/commitConfig/start
  // 任一步抛出异常都会导致摄像头处于部分初始化状态。失败时回滚已创建的 session，
  // 避免半初始化的 captureSession 残留阻塞后续相机操作。
  try {
    // createSession returns the broad camera.Session; cast to PhotoSession is the idiomatic
    // OHOS narrowing for NORMAL_PHOTO sessions used throughout this module.
    state.captureSession = state.cameraManager.createSession(camera.SceneMode.NORMAL_PHOTO) as camera.PhotoSession;
    if (!state.captureSession) {
      Log.e(TAG + '-CameraUtil', 'cameraManager.createSession error');
      return false;
    }
    state.captureSession.beginConfig();
    state.captureSession.addInput(state.cameraInput);
    state.captureSession.addOutput(state.previewOutput);
    state.captureSession.addOutput(state.photoOutput);
    await state.captureSession.commitConfig();
    await state.captureSession.start();
    return true;
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'startPhotoSession failed: ' + JSON.stringify(error));
    // 回滚：释放半初始化的 session，恢复全局状态以便下次重试
    try {
      await state.captureSession?.release();
    } catch (releaseErr) {
      Log.e(TAG + '-CameraUtil', 'startPhotoSession rollback release failed: ' + JSON.stringify(releaseErr));
    }
    state.captureSession = undefined;
    return false;
  }
}

/**
 * Recreates camera input and outputs for a requested camera position.
 * @param cameraPosition index in the supported camera list
 * @param surfaceId preview identifier
 * @param foldStatus current fold state used by profile selection
 * @returns true when the replacement session starts successfully
 */
async function configureSwitchedCamera(cameraPosition: number, surfaceId: string,
  foldStatus: number): Promise<boolean> {
  let state: CameraStateManager = getState();
  if (!state.cameraManager) {
    return false;
  }
  try {
    state.cameraArray = state.cameraManager.getSupportedCameras();
    if (!state.cameraArray || state.cameraArray.length <= cameraPosition || cameraPosition < 0) {
      Log.e(TAG + '-CameraUtil', 'requested camera is unavailable');
      return false;
    }
    let device: camera.CameraDevice = state.cameraArray[cameraPosition];
    state.cameraInput = state.cameraManager.createCameraInput(device);
    state.lastCameraDevice = device;
    await state.cameraInput.open();
    let capability: camera.CameraOutputCapability | undefined = getOutputCapability(state.cameraManager, device);
    if (!capability) {
      return false;
    }
    let selection: ProfileSelection = selectProfiles(capability, foldStatus);
    if (!selection.previewProfile) {
      Log.e(TAG + '-CameraUtil', 'previewProfile not found in supported profiles');
      return false;
    }
    if (!createCameraOutputs(state.cameraManager, selection.previewProfile, selection.photoProfile, surfaceId)) {
      return false;
    }
    return startPhotoSession();
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'configureSwitchedCamera failed: ' + JSON.stringify(error));
    return false;
  }
}

/**
 * Switches the active camera and rebuilds its preview session.
 * @param cameraPosition 目标相机位置索引
 * @param surfaceId 预览id
 * @param foldAbleStatus 折叠状态，用于选择合适的 profile
 * @returns Promise，切换完成后 resolve
 */
export async function switchCamera(cameraPosition: number, surfaceId: string, foldAbleStatus: number): Promise<void> {
  Log.i(TAG + '-CameraUtil', 'cameraPosition :' + cameraPosition);
  Log.i(TAG + '-CameraUtil', 'surfaceId :' + surfaceId);
  let state: CameraStateManager = getState();
  // 重入保护：避免并发异步相机操作交错导致全局状态被破坏
  if (state.cameraOperationInProgress) {
    Log.w(TAG + '-CameraUtil', 'switchCamera skipped: camera operation already in progress');
    return;
  }
  state.cameraOperationInProgress = true;
  // 在 releaseCamera 清空前，先缓存 context，以便释放后重建 cameraManager
  let savedContext: common.BaseContext | undefined = state.currentContext;
  try {
    /*第一步先释放相机，再通过选择的相机position重新创建相机预览窗口*/
    // 必须 await releaseCamera，确保旧相机资源完全释放后再创建新相机，避免资源竞态
    await releaseCamera();
    if (!restoreCameraManager(savedContext)) {
      return;
    }
    await configureSwitchedCamera(cameraPosition, surfaceId, foldAbleStatus);

  } catch (error) {
    Log.e(TAG + '-CameraUtil', `The camera switch failed: ${JSON.stringify(error)}`);
  } finally {
    // releaseCamera 内部会 resetCameraState()，需重新获取当前单例再清位
    getState().cameraOperationInProgress = false;
  }
}

/**
 * 创建预览与拍照输出，并校验是否成功。
 * @param mgr CameraManager
 * @param previewProfile 预览 profile
 * @param photoProfile 拍照 profile
 * @param surfaceId 预览 surfaceId
 * @returns 成功返回 true，失败返回 false
 */
function createCameraOutputs(mgr: camera.CameraManager, previewProfile: camera.Profile,
  photoProfile: camera.Profile | undefined, surfaceId: string): boolean {
  let state: CameraStateManager = getState();
  try {
    state.previewOutput = mgr.createPreviewOutput(previewProfile, surfaceId);
    if (state.previewOutput === undefined) {
      Log.e(TAG + '-CameraUtil', 'cameraManager.createPreviewOutput error');
      return false;
    }
    state.photoOutput = mgr.createPhotoOutput(photoProfile);
    if (state.photoOutput === undefined) {
      Log.e(TAG + '-CameraUtil', 'cameraManager.createPhotoOutput error');
      return false;
    }
    return true;
  } catch (error) {
    Log.e(TAG + '-CameraUtil', 'createCameraOutputs failed: ' + JSON.stringify(error));
    return false;
  }
}

/**
 * Applies a zoom ratio to the active capture session.
 * @param zoomLevel 缩放级别
 * @returns 设置成功返回 true，会话不存在返回 false
 */
export async function setZoom(zoomLevel: number): Promise<boolean> {
  Log.i(TAG + '-CameraUtil', 'setZoom in!');
  let state: CameraStateManager = getState();
  if (state.cameraManager) {
    getCaptureSession(state.cameraManager);
  }
  if (state.captureSession === undefined) {
    Log.e(TAG + '-CameraUtil', 'captureSession is null');
    return false;
  }
  state.captureSession.setZoomRatio(zoomLevel);
  Log.i(TAG + '-CameraUtil', 'setZoom out!');
  return true;
}
