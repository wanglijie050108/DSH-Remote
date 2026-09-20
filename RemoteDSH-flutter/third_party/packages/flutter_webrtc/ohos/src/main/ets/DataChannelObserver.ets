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

import { BinaryMessenger, Log } from '@ohos/flutter_ohos';
import EventChannel, { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { RTCDataChannel, Event, MessageEvent, DataChannelState } from 'libohos_webrtc.so';
import { ArrayList } from '@kit.ArkTS';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataChannelStateCode, DataMap, MethodChannelValue } from './utils/ObjectType';
import { util } from '@kit.ArkTS';
import { isBinaryBuffer } from './utils/Utils';

const TAG: string = 'FlutterWebRTCPlugin-DataChannelObserver';
const CHANNEL_NAME: string = 'FlutterWebRTC/dataChannelEvent';

export class DataChannelObserver implements StreamHandler {
  // EventSink 未就绪时缓存事件的队列容量上限。高频 DataChannel 消息 + Flutter
  // 延迟订阅可导致事件无限堆积，超过上限时丢弃最旧事件，防止内存持续攀升。
  private static readonly MAX_EVENT_QUEUE_SIZE: number = 512;
  private flutterId: string;
  private dataChannel: RTCDataChannel | null;
  private eventChannel: EventChannel;
  private eventSink: EventSink | null = null;
  private eventQueue: ArrayList<DataMap> = new ArrayList();

  /**
   * 构造数据通道观察者：缓存通道引用，注册 EventChannel 并绑定底层 RTCDataChannel 的
   * 6 个事件回调（bufferedamountlow/message/closing/open/close/error）。
   * 回调赋值包裹 try-catch，避免单个回调注册失败导致构造阶段崩溃。
   * @param messenger Flutter 二进制信使，用于创建 EventChannel
   * @param peerConnectionId 所属 PeerConnection 的 flutterId（拼入 EventChannel 名以保证唯一）
   * @param flutterId 数据通道的 flutterId（拼入 EventChannel 名以保证唯一）
   * @param dataChannel 底层 RTCDataChannel 实例，观察者将绑定其事件回调
   */
  constructor(messenger: BinaryMessenger, peerConnectionId: string, flutterId: string, dataChannel: RTCDataChannel) {
    this.flutterId = flutterId;
    this.dataChannel = dataChannel;
    this.eventChannel = new EventChannel(messenger, `${CHANNEL_NAME}${peerConnectionId}${flutterId}`);
    this.eventChannel.setStreamHandler(this);
    // 注册回调时进行异常保护，避免单个回调赋值失败导致构造阶段崩溃
    try {
      this.dataChannel.onbufferedamountlow = (data: Event) => this.onBufferedAmountChange(data);
      this.dataChannel.onmessage = (data: MessageEvent<string | ArrayBuffer | Uint8Array>) => this.onMessage(data);
      this.dataChannel.onclosing = (data: Event) => this.onClosing(data);
      this.dataChannel.onopen = (data: Event) => this.onOpen(data);
      this.dataChannel.onclose = (data: Event) => this.onClose(data);
      this.dataChannel.onerror = (data: Event) => this.onError(data);
    } catch (error) {
      Log.e(TAG, 'dataChannel callback registration failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 释放数据通道观察者：清除底层数据通道上注册的所有回调
   * （打破 dataChannel -> callback -> this 循环引用），
   * 解除 EventChannel 绑定，并清空事件队列与缓存引用。
   */
  dispose(): void {
    if (this.dataChannel) {
      // 先清除回调引用，避免关闭过程中触发已失效的回调
      this.dataChannel.onbufferedamountlow = null;
      this.dataChannel.onmessage = null;
      this.dataChannel.onclosing = null;
      this.dataChannel.onopen = null;
      this.dataChannel.onclose = null;
      this.dataChannel.onerror = null;
      // 主动关闭底层 dataChannel，避免 native 连接资源泄漏
      try {
        this.dataChannel.close();
      } catch (error) {
        Log.e(TAG, 'dataChannel.close failed: ' + JSON.stringify(error));
      }
      this.dataChannel = null;
    }
    this.eventChannel.setStreamHandler(null);
    this.eventSink = null;
    this.eventQueue.clear();
  }

  /**
   * 数据通道进入关闭中状态时通知 Flutter 层。
   * @param ev 关闭中事件
   */
  onClosing(ev: Event): void {
    this.onStateChange(DataChannelStateCode.CLOSING);
  }

  /**
   * 数据通道打开完成时通知 Flutter 层。
   * @param ev 打开事件
   */
  onOpen(ev: Event): void {
    this.onStateChange(DataChannelStateCode.OPEN);
  }

  /**
   * 数据通道关闭完成时通知 Flutter 层。
   * @param ev 关闭事件
   */
  onClose(ev: Event): void {
    this.onStateChange(DataChannelStateCode.CLOSED);
  }

  /**
   * 数据通道发生错误时，将错误事件传播到 Flutter 层（与 iOS/Android 行为对齐）。
   * @param ev 错误事件
   */
  onError(ev: Event): void {
    Log.d(TAG, 'onError' + JSON.stringify(ev));
    let params: ConstraintsMap = new ConstraintsMap();
    params.putString('event', 'dataChannelError');
    params.putNumber('id', this.dataChannel?.id ?? -1);
    this.sendEvent(params);
  }

  /**
   * 数据通道状态变更时通知 Flutter 层。
   * @param state 新的数据通道状态
   */
  onStateChange(state: DataChannelState): void {
    try {
      Log.d(TAG, 'onStateChange' + JSON.stringify(state));
      if (!this.dataChannel) {
        return;
      }
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('event', 'dataChannelStateChanged');
      params.putNumber('id', this.dataChannel.id);
      params.putString('state', state);
      this.sendEvent(params);
    } catch (error) {
      Log.e(TAG, 'onStateChange failed: ' + JSON.stringify(error));
      this.sendErrorEvent('dataChannelStateChanged', error);
    }
  }

  /**
   * EventChannel 开始监听时缓存事件出口，并回放缓存的事件。
   * @param args 事件通道参数
   * @param events Flutter 事件出口
   */
  onListen(args: MethodChannelValue, events: EventSink): void {
    this.eventSink = events;
    for (const event of this.eventQueue) {
      this.eventSink.success(event);
    }
    this.eventQueue.clear();
  }

  /**
   * EventChannel 取消监听时清空事件出口。
   * @param args 事件通道参数
   */
  onCancel(args: MethodChannelValue): void {
    this.eventSink = null;
  }

  /**
   * 缓冲数据量变化时通知 Flutter 层。
   * @param ev 触发事件
   */
  onBufferedAmountChange(ev: Event): void {
    try {
      Log.d(TAG, 'onBufferedAmountChange' + JSON.stringify(ev.type));
      if (!this.dataChannel) {
        return;
      }
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('event', 'dataChannelBufferedAmountChange');
      params.putNumber('id', this.dataChannel.id);
      params.putNumber('bufferedAmount', this.dataChannel.bufferedAmount);
      params.putNumber('changedAmount', this.dataChannel.bufferedAmount);
      this.sendEvent(params);
    } catch (error) {
      Log.e(TAG, 'onBufferedAmountChange failed: ' + JSON.stringify(error));
      this.sendErrorEvent('dataChannelBufferedAmountChange', error);
    }
  }

  /**
   * 收到数据通道消息时通知 Flutter 层，自动区分二进制与文本消息。
   * @param ev 消息事件
   */
  onMessage(ev: MessageEvent<string | ArrayBuffer | Uint8Array>): void {
    try {
      if (!this.dataChannel) {
        return;
      }
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('event', 'dataChannelReceiveMessage');
      params.putNumber('id', this.dataChannel.id);
      if (typeof ev.data === 'string') {
        params.putString('type', 'text');
        params.putString('data', ev.data);
        this.sendEvent(params);
        return;
      }
      let bytes: Uint8Array;
      if (ev.data instanceof ArrayBuffer) {
        bytes = new Uint8Array(ev.data);
      } else if (ev.data instanceof Uint8Array) {
        bytes = ev.data;
      } else {
        bytes = ev.data;
      }

      if (isBinaryBuffer(bytes)) {
        params.putString('type', 'binary');
        params.putByte('data', bytes);
      } else {
        let decoder: util.TextDecoder = new util.TextDecoder();
        let decodeToStringOptions: util.DecodeToStringOptions = {
          stream: false
        };
        let decodedString: string = decoder.decodeToString(bytes, decodeToStringOptions);
        params.putString('type', 'text');
        params.putString('data', decodedString);
      }

      this.sendEvent(params);
    } catch (error) {
      Log.e(TAG, 'onMessage failed: ' + JSON.stringify(error));
      this.sendErrorEvent('dataChannelReceiveMessage', error);
    }
  }

  /**
   * 向 Flutter 层推送一个 native 回调错误事件，使 Flutter 端能感知数据通道
   * native 层抛出的异常（避免 catch 仅 Log.e 导致 Flutter Future 挂起或状态不一致）。
   * @param eventName 触发错误的回调事件名（如 'dataChannelStateChanged'）
   * @param error 被捕获的异常对象
   */
  private sendErrorEvent(eventName: string, error: Object): void {
    try {
      let params: ConstraintsMap = new ConstraintsMap();
      params.putString('event', eventName + 'Error');
      params.putString('error', JSON.stringify(error));
      this.sendEvent(params);
    } catch (e) {
      Log.e(TAG, 'sendErrorEvent failed: ' + JSON.stringify(e));
    }
  }

  /**
   * 向 Flutter 层发送事件；若 EventChannel 尚未建立监听则先缓存到事件队列。
   * @param params 事件参数
   */
  sendEvent(params: ConstraintsMap): void {
    try {
      if (this.eventSink) {
        this.eventSink.success(params.toMap());
      } else {
        // 队列超限时丢弃最旧事件，避免高频消息导致无界内存增长
        if (this.eventQueue.length >= DataChannelObserver.MAX_EVENT_QUEUE_SIZE) {
          Log.w(TAG, 'eventQueue exceeded ' + DataChannelObserver.MAX_EVENT_QUEUE_SIZE +
            ', dropping oldest event');
          this.eventQueue.removeByIndex(0);
        }
        this.eventQueue.add(params.toMap());
      }
    } catch (error) {
      Log.e(TAG, 'sendEvent failed: ' + JSON.stringify(error));
    }
  }
}
