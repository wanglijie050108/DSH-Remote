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

import { DataMap } from './ObjectType';
import { DataArray, ObjectType, MethodChannelValue } from './ObjectType';

/**
 * 约束集合 Array 封装类。
 *
 * 对底层 `DataArray`（`Array<MethodChannelValue>`）做类型安全的读写封装，
 * 供 MethodChannel 数组消息解析与序列化使用。所有取值方法均假设索引存在。
 */
export class ConstraintsArray {
  private innerArray: DataArray;

  /**
   * 构造一个约束数组。
   * @param array 可选的初始数组；未提供时创建空数组。
   */
  constructor(array?: DataArray) {
    if (array) {
      this.innerArray = array;
    } else {
      this.innerArray = new Array<MethodChannelValue>();
    }
  }

  /** 返回数组元素个数。 */
  public size(): number {
    return this.innerArray.length;
  }

  /**
   * 判断指定索引处的值是否为 null。
   * @param index 索引
   */
  public isNull(index: number): boolean {
    return this.innerArray[index] === null;
  }

  /**
   * 获取布尔值。
   * @param index 索引
   */
  public getBoolean(index: number): boolean {
    const value: MethodChannelValue = this.innerArray[index];
    return typeof value === 'boolean' ? value : false;
  }

  /**
   * 获取数值。
   * @param index 索引
   */
  public getNumber(index: number): number {
    const value: MethodChannelValue = this.innerArray[index];
    return typeof value === 'number' ? value : 0;
  }

  /**
   * 获取字符串。
   * @param index 索引
   */
  public getString(index: number): string {
    const value: MethodChannelValue = this.innerArray[index];
    return typeof value === 'string' ? value : '';
  }

  /**
   * 获取字节（Uint8Array）。
   * @param index 索引
   */
  public getByte(index: number): Uint8Array {
    const value: MethodChannelValue = this.innerArray[index];
    return value instanceof Uint8Array ? value : new Uint8Array();
  }

  /**
   * 获取子数组。
   * @param index 索引
   */
  public getArray(index: number): ConstraintsArray {
    const value: MethodChannelValue = this.innerArray[index];
    return new ConstraintsArray(value instanceof Array ? value : []);
  }

  /**
   * 获取子 Map。
   * @param index 索引
   */
  public getMap(index: number): DataMap {
    const value: MethodChannelValue = this.innerArray[index];
    return value instanceof Map ? value : new Map<string, MethodChannelValue>();
  }

  /**
   * 获取指定索引处值的类型枚举。
   * @param index 索引
   */
  public getType(index: number): ObjectType {
    const object: MethodChannelValue = this.innerArray[index];
    if (object === null) {
      return ObjectType.NULL;
    } else if (object instanceof Boolean || typeof object === 'boolean') {
      return ObjectType.BOOLEAN;
    } else if (object instanceof Number || typeof object === 'number') {
      return ObjectType.NUMBER;
    } else if (object instanceof String || typeof object === 'string') {
      return ObjectType.STRING;
    } else if (object instanceof Array) {
      return ObjectType.ARRAY;
    } else if (object instanceof Map) {
      return ObjectType.MAP;
    } else if (object instanceof Uint8Array) {
      return ObjectType.BYTE;
    }
    return ObjectType.NULL;
  }

  /** 返回底层数组（不拷贝）。 */
  public toArrayList(): DataArray {
    return this.innerArray;
  }

  /** 追加 null。 */
  public pushNull(): void {
    this.innerArray.push(null);
  }

  /**
   * 追加布尔值。
   * @param value 布尔值
   */
  public pushBoolean(value: boolean): void {
    this.innerArray.push(value);
  }

  /**
   * 追加数值。
   * @param value 数值
   */
  public pushNumber(value: number): void {
    this.innerArray.push(value);
  }

  /**
   * 追加字符串。
   * @param value 字符串
   */
  public pushString(value: string): void {
    this.innerArray.push(value);
  }

  /**
   * 追加子数组。
   * @param array 子数组
   */
  public pushArray(array: ConstraintsArray): void {
    this.innerArray.push(array.toArrayList());
  }

  /**
   * 追加字节（Uint8Array）。
   * @param value 字节数组
   */
  public pushByte(value: Uint8Array): void {
    this.innerArray.push(value);
  }

  /**
   * 追加子 Map。
   * @param map 子 Map
   */
  public pushMap(map: DataMap): void {
    this.innerArray.push(map);
  }

  /** 序列化为 JSON 字符串。 */
  public toString(): string {
    return `${JSON.stringify(this.innerArray)}`;
  }
}
