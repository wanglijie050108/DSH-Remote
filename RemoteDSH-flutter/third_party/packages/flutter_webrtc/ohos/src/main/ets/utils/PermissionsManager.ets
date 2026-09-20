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
 
/**
 * PermissionsManager — OHOS 权限管理工具类。
 * 文件名与导出的 PermissionsManager 保持一致，便于按职责定位。
 */

// 1. 系统/Kit 导入
import bundleManager from '@ohos.bundle.bundleManager';
import abilityAccessCtrl, { PermissionRequestResult, Permissions } from '@ohos.abilityAccessCtrl';
import { BusinessError } from '@ohos.base';
import { Log } from '@ohos/flutter_ohos';
import common from '@ohos.app.ability.common';
// 2. 第三方库导入
// 3. 本地模块导入
import { ConstraintsMap } from './ConstraintsMap';

const TAG: string = 'FlutterWebRTCPlugin-PermissionsManager';

export type ResultCallback = (errCode: string | null, errDesc: string | null) => void;

export class PermissionsManager {
  private static instance: PermissionsManager | null = null;
  private commonContext: common.UIAbilityContext | null = null;
  private readonly microphone: Permissions = 'ohos.permission.MICROPHONE';
  private readonly camera: Permissions = 'ohos.permission.CAMERA';

  constructor() {
  }

  /**
   * 获取权限管理器单例。若实例不存在则创建，否则返回已有实例。
   * @returns 权限管理器单例
   */
  static getInstance(): PermissionsManager {
    if (!PermissionsManager.instance) {
      PermissionsManager.instance = new PermissionsManager();
    }
    return PermissionsManager.instance;
  }

  /**
   * 初始化权限管理器，缓存当前 Ability 上下文用于请求权限。
   * @param context UIAbility 上下文
   */
  public init(context: common.UIAbilityContext): void {
    this.commonContext = context;
  }

  /**
   * 清理缓存的 Ability 上下文。应在 onDetachedFromAbility 时调用，
   * 避免单例在 Ability 分离后仍持有 stale context。
   */
  public clearContext(): void {
    this.commonContext = null;
  }

  /**
   * 销毁单例：清理上下文引用并释放静态单例，避免插件卸载后单例持续驻留。
   * 应在 FlutterWebRTCPlugin.onDetachedFromEngine 中调用。
   */
  public destroy(): void {
    this.commonContext = null;
    PermissionsManager.instance = null;
  }

  /**
   * 请求权限：若已授予则直接回调，否则唤起系统授权弹窗。
   * @param permissionsList 需请求的权限列表
   * @param callback 结果回调
   */
  public async requestPermissions(permissionsList: Array<Permissions>, callback: ResultCallback): Promise<void> {
    Log.i(TAG, `requestPermissions start:${JSON.stringify(permissionsList)}`);
    if (!this.commonContext) {
      callback('-1', 'permission context is not initialized');
      return;
    }
    let context: common.UIAbilityContext = this.commonContext;
    const hasCameraPermission: boolean = await this.checkPermissions(permissionsList);
    Log.i(TAG, `hasCameraPermission:${hasCameraPermission}`);
    if (hasCameraPermission) {
      callback(null, null);
      return;
    }
    // requestPermissionsFromUser会判断权限的授权状态来决定是否唤起弹窗
    abilityAccessCtrl.createAtManager()
      .requestPermissionsFromUser(context, permissionsList)
      .then((data: PermissionRequestResult) => {
        Log.i(TAG, `grantStatus:${JSON.stringify(data)}`);
        let grantStatus: number[] = data.authResults;
        let length: number = grantStatus.length;
        for (let i = 0; i < length; i++) {
          if (grantStatus[i] !== 0) {
            // 用户拒绝授权，提示用户必须授权才能访问当前页面的功能，
            // 并引导用户到系统设置中打开相应的权限
            callback('-1', '未授权相机权限');
            return;
          }
        }
        callback(null, null);
      })
      .catch((error: BusinessError) => {
        Log.e(TAG, `Failed to request permissions from user. error: ${JSON.stringify(error)}`);
        callback(String(error.code), error.message);
      });
  }

  /**
   * 批量校验权限列表中所有权限，全部已授权返回 true，任一未授权返回 false。
   * @param permissionsList 待校验的权限列表
   * @returns 全部已授权返回 true，否则返回 false
   */
  public async checkPermissions(permissionsList: Array<Permissions>): Promise<boolean> {
    // 无需请求任何权限时直接视为已授权，避免访问空数组下标 0 导致 undefined crash
    if (!permissionsList || permissionsList.length === 0) {
      return true;
    }
    // 校验列表中所有权限，任一未授权即返回 false（原实现仅检查 [0]）
    for (let i = 0; i < permissionsList.length; i++) {
      let grantStatus: abilityAccessCtrl.GrantStatus = await this.checkAccessToken(permissionsList[i]);
      if (grantStatus !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
        return false;
      }
    }
    return true;
  }

  /**
   * 校验单个权限的授权状态。通过 tokenId 查询 AtManager 获取授权结果。
   * @param permission 待校验的权限标识
   * @returns 权限授权状态
   */
  public async checkAccessToken(permission: Permissions): Promise<abilityAccessCtrl.GrantStatus> {
    // 获取应用程序的accessTokenID
    let tokenId: number = 0;
    let grantStatus: abilityAccessCtrl.GrantStatus = abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    try {
      let bundleInfo: bundleManager.BundleInfo = await bundleManager.getBundleInfoForSelf(
        bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_APPLICATION);
      let appInfo: bundleManager.ApplicationInfo = bundleInfo.appInfo;
      tokenId = appInfo.accessTokenId;
      Log.i(TAG, `checkAccessToken tokenId: ${tokenId}`);
    } catch (error) {
      Log.e(TAG, `checkAccessToken Failed to get bundle info for self. error: ${JSON.stringify(error)}`);
      return abilityAccessCtrl.GrantStatus.PERMISSION_DENIED;
    }
    // 注：AtManager 由 abilityAccessCtrl.createAtManager() 创建，OHOS 未提供显式 release API；
    // 该对象为轻量级句柄（内部委托给 ATM 服务），作用域局限于此方法，无需手动释放。
    const atManager: abilityAccessCtrl.AtManager = abilityAccessCtrl.createAtManager();
    // 校验应用是否被授予权限
    try {
      grantStatus = await atManager.checkAccessToken(tokenId, permission);
      Log.i(TAG, `checkAccessToken grantStatus: ${grantStatus}`);
    } catch (error) {
      Log.e(TAG, `checkAccessToken Failed to check access token. error: ${JSON.stringify(error)}`);
    }
    return grantStatus;
  }

  /**
   * 根据 getUserMedia/getDisplayMedia 约束解析所需权限并请求。
   * @param constraints 媒体约束
   * @param callback 结果回调
   */
  public async processPermissions(constraints: ConstraintsMap, callback: ResultCallback): Promise<void> {
    let permissionsList: Permissions[] = [];
    if (constraints.hasKey('audio')) {
      permissionsList.push(this.microphone);
    }
    if (constraints.hasKey('video')) {
      permissionsList.push(this.camera);
    }
    this.requestPermissions(permissionsList, (code, err) => {
      callback(code, err);
    });
  }
}
