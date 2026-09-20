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

/** 网络适配器类型枚举，用于标识设备的网络接口类型。 */
export enum AdapterType {
  /** 未知适配器类型 */
  ADAPTER_TYPE_UNKNOWN = 0,
  /** 以太网适配器 */
  ADAPTER_TYPE_ETHERNET = 1,
  /** Wi-Fi 适配器 */
  ADAPTER_TYPE_WIFI = 2,
  /** 蜂窝网络适配器 */
  ADAPTER_TYPE_CELLULAR = 4,
  /** VPN 适配器 */
  ADAPTER_TYPE_VPN = 8,
  /** 回环适配器 */
  ADAPTER_TYPE_LOOPBACK = 16,
  /** 任意类型适配器 */
  ADAPTER_TYPE_ANY = 32
}