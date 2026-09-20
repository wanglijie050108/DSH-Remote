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

/**
 * MethodChannel 桥接数据的值联合类型。
 *
 * Flutter MethodChannel 在运行时传递的数据本质上是动态类型的，每个键的值可能是
 * 标量、字节缓冲、嵌套 Map 或嵌套数组。此处用具体联合类型替代 ESObject，
 * 在保留运行时多态性的同时为调用方提供编译期类型边界，便于静态分析与重构。
 * 当值类型无法预先确定时，调用方仍需通过运行时 instanceof / typeof 收窄类型。
 */
export type MethodChannelValue = number | string | boolean | Uint8Array | DataMap | DataArray | null;

/**
 * MethodChannel 数据 Map。值类型为 MethodChannelValue 联合类型，替代 ESObject。
 */
export type DataMap = Map<string, MethodChannelValue>;

/**
 * MethodChannel 数据数组。元素类型为 MethodChannelValue 联合类型，替代 ESObject。
 */
export type DataArray = Array<MethodChannelValue>;

/**
 * MethodChannel 传输数据的运行时类型标识枚举。
 *
 * 用于在 Dart 与 OpenHarmony 之间标记通过 MethodChannel 传递的数据的实际类型，
 * 与 MethodChannelValue 联合类型相互配合，支持编解码时按标识分派处理逻辑。
 */
export enum ObjectType {
  NULL = 'Null',
  NUMBER = 'Number',
  STRING = 'String',
  BOOLEAN = 'Boolean',
  MAP = 'Map',
  ARRAY = 'Array',
  BYTE = 'Byte'
}

/**
 * WebRTC 数据通道连接状态码枚举。
 *
 * 对应 W3C RTCDataChannelState 规范定义的四种连接状态，
 * 用于在 Native 层与 Flutter 层之间传递数据通道的当前状态。
 */
export enum DataChannelStateCode {
  CONNECTING = 'connecting',
  OPEN = 'open',
  CLOSING = 'closing',
  CLOSED = 'closed'
}
