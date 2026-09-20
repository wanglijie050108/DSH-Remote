/* MIT License
*
* Copyright (c) 2024 SwanLink (Jiangsu) Technology Development Co., LTD.
* All rights reserved.
* Permission is hereby granted, free of charge, to any person obtaining a copy
* of this software and associated documentation files (the 'Software'), to deal
* in the Software without restriction, including without limitation the rights
* to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
* copies of the Software, and to permit persons to whom the Software is
* furnished to do so, subject to the following conditions:
*
* The above copyright notice and this permission notice shall be included in all
* copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED 'AS IS', WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
* AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
* OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
* SOFTWARE.
*/

import { AdapterType } from './AdapterType';
import { ConstraintsMap } from './ConstraintsMap';
import { DataArray, DataMap, ObjectType, MethodChannelValue } from './ObjectType';
import { ArrayList } from '@kit.ArkTS';
import { ConstraintsArray } from './ConstraintsArray';

/**
 * 从配置项中获取网络忽略掩码。
 * 解析 optionsMap 中的 networkIgnoreMask 数组，累加对应的网络适配器类型掩码值。
 * @param optionsMap - 包含配置项的 ConstraintsMap
 * @returns 网络忽略掩码数值
 */
export function getOptionsNetworkIgnoreMask(optionsMap: ConstraintsMap): number {
  let networkIgnoreMask: number = AdapterType.ADAPTER_TYPE_UNKNOWN;
  if (optionsMap.getType('networkIgnoreMask') === ObjectType.ARRAY) {
    let ignoredAdapters: ConstraintsArray | null = optionsMap.getArray('networkIgnoreMask');
    ignoredAdapters?.toArrayList().forEach((adapter: MethodChannelValue) => {
      switch (adapter?.toString()) {
        case 'adapterTypeEthernet':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_ETHERNET;
          break;
        case 'adapterTypeWifi':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_WIFI;
          break;
        case 'adapterTypeCellular':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_CELLULAR;
          break;
        case 'adapterTypeVpn':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_VPN;
          break;
        case 'adapterTypeLoopback':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_LOOPBACK;
          break;
        case 'adapterTypeAny':
          networkIgnoreMask += AdapterType.ADAPTER_TYPE_ANY;
          break;
      }
    });
  }
  return networkIgnoreMask;
}

/**
 * 从配置项中获取是否强制使用软件编解码。
 * @param optionsMap - 包含配置项的 ConstraintsMap
 * @returns 是否强制使用软件编解码，默认返回 false
 */
export function getOptionsForceSWCodec(optionsMap: ConstraintsMap): boolean {
  let forceSWCodec: boolean = false;
  if (optionsMap.getType('forceSWCodec') === ObjectType.BOOLEAN) {
    forceSWCodec = optionsMap.getBoolean('forceSWCodec');
  }
  return forceSWCodec;
}

/**
 * 从配置项中获取强制使用软件编解码的编码格式列表。
 * 若未配置则默认包含 VP9。
 * @param optionsMap - 包含配置项的 ConstraintsMap
 * @returns 强制使用软件编解码的编码格式名称列表
 */
export function getOptionsForceSWCodecList(optionsMap: ConstraintsMap): ArrayList<string> {
  let forceSWCodecList: ArrayList<string> = new ArrayList();
  if (optionsMap.getType('forceSWCodecList') === ObjectType.ARRAY) {
    let array: DataArray = optionsMap.getListArray('forceSWCodecList');
    array.forEach((v: MethodChannelValue) => {
      forceSWCodecList.add(v?.toString());
    });
  } else {
    // disable HW Codec for VP9 by default.
    forceSWCodecList.add('VP9');
  }
  return forceSWCodecList;
}

/**
 * 从配置项中获取音频配置。
 * 优先读取 ohosAudioConfiguration 键，若不存在则回退到 configuration 键。
 * @param optionsMap - 包含配置项的 ConstraintsMap
 * @returns 音频配置 ConstraintsMap，未配置时返回空的 ConstraintsMap
 */
export function getOptionsAudioConfiguration(optionsMap: ConstraintsMap): ConstraintsMap {
  let audioConfiguration: ConstraintsMap = new ConstraintsMap();
  let configurationKey: string = optionsMap.getType('ohosAudioConfiguration') === ObjectType.MAP
    ? 'ohosAudioConfiguration'
    : 'configuration';
  if (optionsMap.getType(configurationKey) === ObjectType.MAP) {
    let configuredAudio: ConstraintsMap | null = optionsMap.getMap(configurationKey);
    if (configuredAudio) {
      audioConfiguration = configuredAudio;
    }
  }
  return audioConfiguration;
}
