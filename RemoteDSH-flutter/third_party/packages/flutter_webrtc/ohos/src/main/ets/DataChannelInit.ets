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

import { RTCDataChannelInit } from 'libohos_webrtc.so';

const TAG: string = 'FlutterWebRTCPlugin-DataChannelInit';

export class DataChannelInit implements RTCDataChannelInit {
  public ordered: boolean = true;
  public maxPacketLifeTime: number = -1;
  public maxRetransmits: number = -1;
  public protocol: string = '';
  public negotiated: boolean = false;
  public id: number = -1;

  /** 构造数据通道初始化配置，所有字段使用默认值。 */
  constructor() {
  }

  /**
   * 获取 ordered 属性值，指示数据通道是否保证消息按序传递。
   * 向后兼容访问器：public 字段 ordered 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns ordered 属性值
   */
  getOrdered(): boolean {
    return this.ordered;
  }

  /**
   * 获取 maxPacketLifeTime 属性值，指示数据包最大生存时间（毫秒）。
   * 向后兼容访问器：public 字段 maxPacketLifeTime 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns maxPacketLifeTime 属性值
   */
  getMaxPacketLifeTime(): number {
    return this.maxPacketLifeTime;
  }

  /**
   * 获取 maxRetransmits 属性值，指示最大重传次数。
   * 向后兼容访问器：public 字段 maxRetransmits 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns maxRetransmits 属性值
   */
  getMaxRetransmits(): number {
    return this.maxRetransmits;
  }

  /**
   * 获取 protocol 属性值，指示数据通道使用的子协议名称。
   * 向后兼容访问器：public 字段 protocol 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns protocol 属性值
   */
  getProtocol(): string {
    return this.protocol;
  }

  /**
   * 获取 negotiated 属性值，指示数据通道是否由应用协商创建。
   * 向后兼容访问器：public 字段 negotiated 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns negotiated 属性值
   */
  getNegotiated(): boolean {
    return this.negotiated;
  }

  /**
   * 获取 id 属性值，指示数据通道的唯一标识符。
   * 向后兼容访问器：public 字段 id 已直接暴露，此 getter 保留以兼容历史调用方。
   * @returns id 属性值
   */
  getId(): number {
    return this.id;
  }
}

