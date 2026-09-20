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
 
// 1. 系统/Kit 导入
import { BinaryMessenger, Log, MethodResult } from '@ohos/flutter_ohos';
import { HashMap, util } from '@kit.ArkTS';
// 2. 第三方库导入
import webrtc, {
  RTCDataChannel,
  RTCPeerConnection,
} from 'libohos_webrtc.so';
import { RTCDataChannelEvent } from 'libohos_webrtc.so';
// 3. 本地模块导入
import StateProvider from './StateProvider';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataChannelObserver } from './DataChannelObserver';
import { DataMap, ObjectType } from './utils/ObjectType';
import { DataChannelInit } from './DataChannelInit';
import { dataMapToString } from './utils/Utils';

const TAG: string = 'FlutterWebRTCPlugin-PeerConnectionObserver';

/**
 * 抽离自 PeerConnectionObserver 的数据通道相关方法集合。
 * 持有对 PCO 共享的 dataChannels / dataChannelObservers 映射的引用，
 * 因此迁出的方法体与原实现保持逐字节一致。
 */

/**
 * 数据通道处理器的依赖注入配置对象，将多个构造参数收敛为单一对象，
 * 避免构造函数参数数量超标。
 */
export interface PeerConnectionDataChannelsOptions {
  messenger: BinaryMessenger;
  id: string;
  stateProvider: StateProvider;
  dataChannels: HashMap<string, RTCDataChannel>;
  dataChannelObservers: HashMap<string, DataChannelObserver>;
  resultError: (method: string, error: string, result: MethodResult) => void;
  sendEvent: (event: DataMap) => void;
  peerConnection: RTCPeerConnection;
}

export class PeerConnectionDataChannels {
  private peerConnection: RTCPeerConnection;
  private messenger: BinaryMessenger;
  private id: string;
  private stateProvider: StateProvider;
  private dataChannels: HashMap<string, RTCDataChannel>;
  private dataChannelObservers: HashMap<string, DataChannelObserver>;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private sendEvent: (event: DataMap) => void;

  /**
   * 构造函数，注入数据通道处理器所需的依赖（messenger、id、stateProvider、
   * dataChannels/dataChannelObservers 映射、错误回调、事件发送器与 PeerConnection 实例）。
   * @param options 依赖注入配置对象
   */
  constructor(options: PeerConnectionDataChannelsOptions) {
    this.messenger = options.messenger;
    this.id = options.id;
    this.stateProvider = options.stateProvider;
    this.dataChannels = options.dataChannels;
    this.dataChannelObservers = options.dataChannelObservers;
    this.resultError = options.resultError;
    this.sendEvent = options.sendEvent;
    this.peerConnection = options.peerConnection;
  }

  /** Breaks callbacks that capture the owning PeerConnectionObserver. */
  dispose(): void {
    this.resultError = (method: string, error: string, result: MethodResult): void => {
      Log.w(TAG, `Ignoring ${method} after data-channel handler disposal: ${error}`);
    };
    this.sendEvent = (event: DataMap): void => {
      Log.w(TAG, 'Ignoring data-channel event after handler disposal');
    };
  }

  /**
   * 设置底层 RTCPeerConnection 实例。
   * @param peerConnection 待绑定的 RTCPeerConnection 对象
   */
  setPeerConnection(peerConnection: RTCPeerConnection): void {
    this.peerConnection = peerConnection;
  }

  /**
   * 为指定数据通道注册观察者，监听其状态与消息事件。
   * @param dcId 数据通道的 flutterId
   * @param dataChannel 底层数据通道实例
   */
  registerDataChannelObserver(dcId: string, dataChannel: RTCDataChannel): void {
    try {
      Log.d(TAG, 'registerDataChannelObserver dcId: ' + JSON.stringify(dcId));
      // 若已存在同 dcId 的观察者，先释放，避免重复注册与回调泄漏
      let existing: DataChannelObserver | undefined = this.dataChannelObservers.get(dcId);
      if (existing) {
        existing.dispose();
      }
      let observer: DataChannelObserver = new DataChannelObserver(this.messenger, this.id, dcId, dataChannel);
      this.dataChannelObservers.set(dcId, observer);
    } catch (error) {
      Log.e(TAG, 'registerDataChannelObserver failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 远端数据通道开启回调：生成本地 flutterId、缓存通道、注册观察者并通知 Flutter。
   * @param event 数据通道开启事件，包含底层 RTCDataChannel
   */
  onDataChannel(event: RTCDataChannelEvent): void {
    try {
      let flutterId: string = this.stateProvider.getNextStreamUUID();
      let params: DataMap = new Map();
      params.set('event', 'didOpenDataChannel');
      params.set('id', event.channel.id ?? '');
      params.set('label', event.channel.label);
      params.set('flutterId', flutterId);
      Log.d(TAG, `onDataChannel params: ${dataMapToString(params)}`);
      this.dataChannels.set(flutterId, event.channel);
      //订阅事件
      this.registerDataChannelObserver(flutterId, event.channel);
      this.sendEvent(params);
    } catch (error) {
      Log.e(TAG, 'onDataChannel failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 创建数据通道并注册观察者。
   * @param label 通道标签
   * @param config 通道配置（id/ordered/maxRetransmits/protocol/negotiated）
   * @param result 回调句柄，返回 { id, label, flutterId }
   */
  createDataChannel(label: string, config: ConstraintsMap, result: MethodResult): void {
    try {
      let init: DataChannelInit = new DataChannelInit();
      if (config.getType('id') === ObjectType.NUMBER) {
        init.id = config.getNumber('id');
      }
      if (config.getType('ordered') === ObjectType.BOOLEAN) {
        init.ordered = config.getBoolean('ordered');
      }
      if (config.getType('maxRetransmits') === ObjectType.NUMBER) {
        init.maxRetransmits = config.getNumber('maxRetransmits');
      }
      if (config.getType('protocol') === ObjectType.STRING) {
        init.protocol = config.getString('protocol');
      }
      if (config.getType('negotiated') === ObjectType.BOOLEAN) {
        init.negotiated = config.getBoolean('negotiated');
      }
      Log.d(TAG, 'createDataChannel init = ' + JSON.stringify(init));
      let dataChannel: RTCDataChannel | undefined = this.peerConnection.createDataChannel(label, init);
      if (!dataChannel) {
        this.resultError('createDataChannel', 'Can\'t create data-channel for id: ' + init.id, result);
        return;
      }
      let flutterId: string = this.getNextDataChannelUUID();
      Log.d(TAG, 'createDataChannel flutterId = ' + flutterId);
      this.dataChannels.set(flutterId, dataChannel);
      this.registerDataChannelObserver(flutterId, dataChannel);
      let params: ConstraintsMap = new ConstraintsMap();
      params.putNumber('id', dataChannel.id);
      params.putString('label', dataChannel.label);
      params.putString('flutterId', flutterId);
      result.success(params.toMap());
      Log.d(TAG, 'createDataChannel params = ' + params.toString());
    } catch (error) {
      this.resultError('createDataChannel', 'createDataChannel failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 关闭指定 ID 的数据通道，释放关联的观察者并移除映射。
   * @param dataChannelId 数据通道的 flutterId
   */
  dataChannelClose(dataChannelId: string): void {
    try {
      let dataChannel: RTCDataChannel | undefined = this.dataChannels.get(dataChannelId);
      let observer: DataChannelObserver | undefined = this.dataChannelObservers.get(dataChannelId);
      if (observer) {
        observer.dispose();
        this.dataChannelObservers.remove(dataChannelId);
      }
      if (dataChannel) {
        dataChannel.close();
        this.dataChannels.remove(dataChannelId);
      } else {
        Log.d(TAG, 'dataChannelClose() dataChannel is null');
      }
    } catch (error) {
      Log.e(TAG, 'dataChannelClose failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 向指定数据通道发送消息。
   * @param dataChannelId 数据通道的 flutterId
   * @param byteBuffer 待发送的字节数据（文本消息需预先转为 UTF-8 字节）
   * @param isBinary 是否为二进制消息
   */
  dataChannelSend(dataChannelId: string, byteBuffer: ArrayBuffer, isBinary: boolean): boolean {
    try {
      let dataChannel: RTCDataChannel | undefined = this.dataChannels.get(dataChannelId);
      if (dataChannel) {
        // OHOS WebRTC SDK 的平台限制， OHOS RTCDataChannel.send() 仅支持 ArrayBuffer，
        // 文本消息已在上游 MethodCallHandlerImpl 中转为 UTF-8 字节。
        // 文本消息将以二进制形式在数据通道上传输。
        dataChannel.send(byteBuffer);
        return true;
      } else {
        Log.d(TAG, 'dataChannelSend() dataChannel is null');
        return false;
      }
    } catch (error) {
      Log.e(TAG, 'dataChannelSend failed: ' + JSON.stringify(error));
      return false;
    }
  }

  /**
   * 生成一个不与已有数据通道冲突的唯一标识符。
   * @returns 唯一的数据通道 flutterId 字符串
   */
  getNextDataChannelUUID(): string {
    let uuid: string;
    do {
      uuid = util.generateRandomUUID(false);
    } while (this.dataChannels.hasKey(uuid));

    return uuid;
  }
}
