/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the "Software"), to deal
* in the Software without restriction, including without limitation the rights to use, copy, modify, merge,
* publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
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

import { ConstraintsArray } from './ConstraintsArray';
import { DataMap, DataArray, ObjectType, MethodChannelValue } from './ObjectType';

/**
 * 约束集合 Map 封装类。
 *
 * 对底层 `DataMap`（`Map<string, MethodChannelValue>`）做类型安全的读写封装，
 * 供 MethodChannel 消息解析与序列化使用。所有取值方法均假设键存在，
 * 调用前应通过 {@link hasKey} / {@link getType} 确认。
 */
export class ConstraintsMap {
  private innerMap: DataMap;

  /**
   * 构造一个约束集合。
   * @param map 可选的初始 Map；未提供时创建空 Map。
   */
  constructor(map?: DataMap) {
    if (map) {
      this.innerMap = map;
    } else {
      this.innerMap = new Map<string, MethodChannelValue>();
    }
  }

  /** 返回底层数据 Map（不拷贝）。 */
  public toMap(): DataMap {
    return this.innerMap;
  }

  /**
   * 判断指定键是否存在。
   * @param name 键名
   */
  public hasKey(name: string): boolean {
    return this.innerMap.has(name);
  }

  /**
   * 判断指定键的值是否为 null。
   * @param name 键名
   */
  public isNull(name: string): boolean {
    return this.innerMap.get(name) === null;
  }

  /**
   * 获取指定键的原始值（MethodChannelValue）。
   * @param name 键名
   */
  public get(name: string): MethodChannelValue {
    return this.innerMap.get(name) ?? null;
  }

  /**
   * 获取布尔值。
   * @param name 键名
   */
  public getBoolean(name: string): boolean {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    return typeof value === 'boolean' ? value : false;
  }

  /**
   * 获取数值（double）。
   * @param name 键名
   */
  public getDouble(name: string): number {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    return typeof value === 'number' ? value : 0;
  }

  /**
   * 获取数值，若值为字符串则按十进制解析。
   * @param name 键名
   */
  public getNumber(name: string): number {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    if (typeof value === 'string') {
      return parseInt(value, 10);
    }
    return typeof value === 'number' ? value : 0;
  }

  /**
   * 获取字符串。
   * @param name 键名
   */
  public getString(name: string): string {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    return typeof value === 'string' ? value : '';
  }

  /**
   * 获取子 Map，键不存在时返回 null。
   * @param name 键名
   */
  public getMap(name: string): ConstraintsMap | null {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    if (!(value instanceof Map)) {
      return null;
    }
    return new ConstraintsMap(value);
  }

  /**
   * 获取指定键值的类型枚举。
   * @param name 键名
   */
  public getType(name: string): ObjectType {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    if (value === null) {
      return ObjectType.NULL;
    } else if (value instanceof Number || typeof value === 'number') {
      return ObjectType.NUMBER;
    } else if (value instanceof String || typeof value === 'string') {
      return ObjectType.STRING;
    } else if (value instanceof Boolean || typeof value === 'boolean') {
      return ObjectType.BOOLEAN;
    } else if (value instanceof Map) {
      return ObjectType.MAP;
    } else if (value instanceof Array) {
      return ObjectType.ARRAY;
    } else if (value instanceof Uint8Array) {
      return ObjectType.BYTE;
    } else {
      return ObjectType.NULL;
    }
  }

  /**
   * 写入布尔值。
   * @param key 键名
   * @param value 布尔值
   */
  public putBoolean(key: string, value: boolean): void {
    this.innerMap.set(key, value);
  }

  /**
   * 写入数值。
   * @param key 键名
   * @param value 数值
   */
  public putNumber(key: string, value: number): void {
    this.innerMap.set(key, value);
  }

  /**
   * 写入字符串。
   * @param key 键名
   * @param value 字符串
   */
  public putString(key: string, value: string): void {
    this.innerMap.set(key, value);
  }

  /**
   * 写入字节（Uint8Array）。
   * @param key 键名
   * @param value 字节数组
   */
  public putByte(key: string, value: Uint8Array): void {
    this.innerMap.set(key, value);
  }

  /**
   * 写入 null 值。
   * @param key 键名
   */
  public putNull(key: string): void {
    this.innerMap.set(key, null);
  }

  /**
   * 写入子 Map。
   * @param key 键名
   * @param value 子 Map
   */
  public putMap(key: string, value: DataMap): void {
    this.innerMap.set(key, value);
  }

  /**
   * 将传入 Map 的所有键值合并到当前 Map。
   * @param value 待合并的 Map
   */
  public merge(value: DataMap): void {
    value.forEach((v: MethodChannelValue, k: string) => this.innerMap.set(k, v));
  }

  /**
   * 写入数组。
   * @param key 键名
   * @param value 数组
   */
  public putArray(key: string, value: DataArray): void {
    this.innerMap.set(key, value);
  }

  /**
   * 获取子数组，键不存在时返回 null。
   * @param name 键名
   */
  public getArray(name: string): ConstraintsArray | null {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    if (!(value instanceof Array)) {
      return null;
    }
    return new ConstraintsArray(value);
  }

  /**
   * 获取底层数组（DataArray）。
   * @param name 键名
   */
  public getListArray(name: string): DataArray {
    const value: MethodChannelValue | undefined = this.innerMap.get(name);
    return value instanceof Array ? value : [];
  }

  /** 序列化为 JSON 字符串。 */
  public toString(): string {
    return `${JSON.stringify(Object.fromEntries(this.innerMap))}`;
  }
}
