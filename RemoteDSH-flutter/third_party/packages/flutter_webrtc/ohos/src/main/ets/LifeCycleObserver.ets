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

import { AbilityLifecycleCallback, UIAbility } from '@kit.AbilityKit';
import { Log } from '@ohos/flutter_ohos';
import MethodCallHandlerImpl from './MethodCallHandlerImpl';

const TAG: string = 'FlutterWebRTCPlugin-LifeCycleObserver';

export default class LifeCycleObserver extends AbilityLifecycleCallback {
  private methodCallHandler: MethodCallHandlerImpl | null = null;
  // 幂等标志：避免 onAbilityDestroy 与 stopListening 双重触发时重复 dispose
  private disposed: boolean = false;

  constructor() {
    super();
  }

  /**
   * 设置方法调用处理器，用于将 Flutter 端的方法调用转发到指定实现。
   * @param methodCallHandler - 方法调用处理器实例，传 null 可解除绑定。
   */
  setMethodCallHandler(methodCallHandler: MethodCallHandlerImpl | null): void {
    this.methodCallHandler = methodCallHandler;
    // 绑定新的 handler 时重置幂等标志，保证新实例可被正常释放
    if (methodCallHandler !== null) {
      this.disposed = false;
    }
  }

  /**
   * Ability 创建时的回调，由系统在 UIAbility 启动时调用。
   * @param ability - 当前 UIAbility 实例。
   */
  onAbilityCreate(ability: UIAbility): void {
    Log.d(TAG, 'onAbilityCreate');
  }

  /**
   * Ability 即将创建时的回调，由系统在 UIAbility 启动前调用。
   * @param ability - 当前 UIAbility 实例。
   */
  onAbilityWillCreate?(ability: UIAbility): void {
    Log.d(TAG, 'onAbilityWillCreate');
  }

  /**
   * Ability 销毁时的回调，由系统在 UIAbility 销毁时调用。
   * 在此回调中释放插件持有的资源（PeerConnection、渲染器、相机等），
   * 防止 Ability 上下文失效后资源泄漏。
   * 包含幂等保护：与 stopListening 双重触发时避免重复释放。
   * @param ability - 当前 UIAbility 实例。
   */
  onAbilityDestroy(ability: UIAbility): void {
    Log.d(TAG, 'onAbilityDestroy');
    // Ability 销毁时主动释放插件持有的资源，防止 Ability 上下文失效后
    // PeerConnection/渲染器/相机等资源仍被持有而无法回收。
    // 幂等保护：onAbilityDestroy 与 FlutterWebRTCPlugin.stopListening 可能
    // 在配置变更等场景下同时触发，避免对已 dispose 的对象二次释放。
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    try {
      this.methodCallHandler?.dispose();
    } catch (error) {
      Log.e(TAG, 'onAbilityDestroy dispose error: ' + JSON.stringify(error));
    }
    this.methodCallHandler = null;
  }

  /**
   * Ability 即将销毁时的回调，由系统在 UIAbility 销毁前调用。
   * @param ability - 当前 UIAbility 实例。
   */
  onAbilityWillDestroy?(ability: UIAbility): void {
    Log.d(TAG, 'onAbilityWillDestroy');
  }

  /**
   * Ability 进入后台时的回调，由系统在 UIAbility 切换到后台时调用。
   * @param ability - 当前 UIAbility 实例。
   */
  onAbilityBackground(ability: UIAbility): void {
    Log.d(TAG, 'onAbilityBackground');
  }
}
