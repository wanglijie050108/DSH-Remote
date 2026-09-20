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

import common from '@ohos.app.ability.common';
import { BinaryMessenger, PlatformView, PlatformViewFactory, StandardMessageCodec } from '@ohos/flutter_ohos';
import { VideoRenderHandler } from './VideoRenderHandler';

export class VideoRenderFactory extends PlatformViewFactory {
  private messenger: BinaryMessenger;

  /**
   * 构造视频渲染 PlatformView 工厂：调用父类构造注册 StandardMessageCodec，并缓存 BinaryMessenger，
   * 供后续 create() 创建 VideoRenderHandler 时建立方法通道通信。
   * @param messenger Flutter 二进制信使，透传给工厂产出的 VideoRenderHandler
   */
  constructor(messenger: BinaryMessenger) {
    super(StandardMessageCodec.INSTANCE);
    this.messenger = messenger;
  }

  /**
   * 创建视频渲染 PlatformView 实例。
   * 由 Flutter 框架在首次嵌入 RTCVideoRenderer 时回调，工厂注入 BinaryMessenger，
   * 供返回的 VideoRenderHandler 建立与方法通道的通信。
   * @param context Ability 上下文
   * @param viewId PlatformView 标识（同时用于拼接方法通道名）
   * @param args Dart 侧透传的创建参数
   * @returns VideoRenderHandler 实例
   */
  public create(context: common.Context, viewId: number, args: Object): PlatformView {
    return new VideoRenderHandler(context, this.messenger, viewId, args);
  }
}
