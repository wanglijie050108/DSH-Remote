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
import { DataMap } from "./ObjectType";

/**
 * 判断给定字节缓冲是否包含二进制数据（即非纯文本）。
 *
 * 遍历缓冲区每个字节，若发现 ASCII 控制字符（0-31）或删除字符（127），
 * 则认为缓冲区包含二进制内容。
 *
 * @param buffer - 待检查的字节数组
 * @returns 若缓冲区包含二进制数据返回 true，否则返回 false
 */
export function isBinaryBuffer(buffer: Uint8Array): boolean {
  for (let i = 0; i < buffer.length; i++) {
    const byte: number = buffer[i];
    // 检查是否为 ASCII 控制字符（0-31）或删除字符（127）
    if ((byte >= 0 && byte <= 31) || byte === 127) {
      return true;
    }
  }
  return false;
}

/**
 * 判断给定对象是否为 null 或 undefined。
 *
 * @param obj - 待检查的对象
 * @returns 若对象为 null 或 undefined 返回 true，否则返回 false
 */
export function isEmpty(obj: Object | null | undefined): boolean {
  return obj === null || obj === undefined;
}

/**
 * 判断给定对象是否既非 null 也非 undefined。
 *
 * 该函数是 isEmpty 的逻辑取反，语义上等同于"对象存在且有值"。
 *
 * @param obj - 待检查的对象
 * @returns 若对象既非 null 也非 undefined 返回 true，否则返回 false
 */
export function isNotEmpty(obj: Object | null | undefined): boolean {
  return !isEmpty(obj);
}

/**
 * 将 DataMap 转换为 JSON 字符串。
 *
 * 先将 Map 转换为普通对象（通过 Object.fromEntries），再序列化为 JSON 字符串。
 *
 * @param map - 待转换的 DataMap 实例
 * @returns Map 内容的 JSON 字符串表示
 */
export function dataMapToString(map: DataMap): string {
  return `${JSON.stringify(Object.fromEntries(map))}`;
}
