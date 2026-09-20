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
import buffer from '@ohos.buffer';
import { Log, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { HashMap } from '@kit.ArkTS';
// 2. 第三方库导入
import { RTCPeerConnection, RTCRtpSender, RTCDTMFSender } from 'libohos_webrtc.so';
// 3. 本地模块导入
import PeerConnectionObserver from './PeerConnectionObserver';
import {
  getDataChannelDictMap,
  getDataChannelId,
  getDuration,
  getGap,
  getLabel,
  getRtpSenderId,
  getTone,
  getType
} from './utils/CallUtils';

const TAG: string = 'FlutterWebRTCPlugin-DataChannelConnectionHandlers';

/**
 * 数据通道与连接控制相关方法集合（DTMF、数据通道、ICE 重启、连接关闭/释放）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入 host 回调与共享的
 * peerConnectionObservers 映射，与原实现保持等价行为。
 */
export class DataChannelConnectionHandlers {
  private getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null;
  private getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null;
  private resultError: (method: string, error: string, result: MethodResult) => void;
  private peerConnectionObservers: HashMap<string, PeerConnectionObserver>;

  /**
   * 构造数据通道与连接控制处理器：注入 host 回调与共享的 peerConnectionObservers 映射。
   * @param getPCO 按 call 解析 PeerConnectionObserver 的回调
   * @param getPeerConnection 按 call 解析底层 RTCPeerConnection 的回调
   * @param resultError 统一错误返回回调（与 host 复用同一错误格式）
   * @param peerConnectionObservers 共享的 PeerConnectionObserver 映射，用于 dispose 时按 id 移除
   */
  constructor(getPCO: (call: MethodCall, result: MethodResult) => PeerConnectionObserver | null,
    getPeerConnection: (call: MethodCall, result: MethodResult) => RTCPeerConnection | null,
    resultError: (method: string, error: string, result: MethodResult) => void,
    peerConnectionObservers: HashMap<string, PeerConnectionObserver>) {
    this.getPCO = getPCO;
    this.getPeerConnection = getPeerConnection;
    this.resultError = resultError;
    this.peerConnectionObservers = peerConnectionObservers;
  }

  /**
   * 向对端发送 DTMF 拨号信令。
   * @param call 方法调用（参数：tone、duration、gap）
   * @param result 回调句柄
   */
  sendDtmf(call: MethodCall, result: MethodResult): void {
    const peerConnection = this.getPeerConnection(call, result);
    if (!peerConnection) {
      return;
    }
    try {
      let audioSender: RTCRtpSender | null = null;
      for (let sender of peerConnection.getSenders()) {
        if (sender.track?.kind === 'audio') {
          audioSender = sender;
          break;
        }
      }
      if (audioSender?.dtmf) {
        let dtmfSender: RTCDTMFSender = audioSender.dtmf;
        let tone: string = getTone(call);
        Log.d(TAG, 'sendDtmf tone= ' + tone);
        let duration: number | undefined = getDuration(call);
        Log.d(TAG, 'sendDtmf duration= ' + duration);
        let gap: number | undefined = getGap(call);
        Log.d(TAG, 'sendDtmf gap= ' + gap);
        dtmfSender.insertDTMF(tone, duration, gap);
      } else {
        this.resultError(call.method, 'audio sender with DTMF support was not found', result);
        return;
      }
      // 与 Android/iOS 一致返回 void（null），而非字符串 'success'
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'sendDtmf failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 检查指定 RTP Sender 是否可插入 DTMF。
   * @param call 方法调用（参数：rtpSenderId）
   * @param result 回调句柄，返回 boolean
   */
  canInsertDtmf(call: MethodCall, result: MethodResult): void {
    try {
      let pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      let rtpSenderId: string = getRtpSenderId(call);
      if (!rtpSenderId || rtpSenderId.length === 0) {
        this.resultError('canInsertDtmf', 'rtpSenderId is required', result);
        return;
      }
      let sender: RTCRtpSender | null = pco.getRtpSenderById(rtpSenderId);
      result.success(sender !== null && sender.dtmf !== null);
    } catch (error) {
      this.resultError(call.method, 'canInsertDtmf failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 创建数据通道。
   * @param call 方法调用（参数：label、dataChannelDict）
   * @param result 回调句柄
   */
  createDataChannel(call: MethodCall, result: MethodResult): void {
    this.getPCO(call, result)?.createDataChannel(getLabel(call), getDataChannelDictMap(call), result);
  }

  /**
   * 通过数据通道发送消息（文本或二进制）。
   * @param call 方法调用（参数：dataChannelId、data、type）
   * @param result 回调句柄
   */
  dataChannelSend(call: MethodCall, result: MethodResult): void {
    try {
      const isBinary: boolean = getType(call) === 'binary';
      let byteBuffer: buffer.Buffer;
      if (isBinary) {
        let data: Uint8Array = call.argument('data');
        if (data === null) {
          this.resultError('dataChannelSend', 'data is null', result);
          return;
        }
        byteBuffer = buffer.from(data);
      } else {
        let data: string = call.argument('data');
        if (data === null) {
          this.resultError('dataChannelSend', 'data is null', result);
          return;
        }
        byteBuffer = buffer.from(data, 'utf-8');
      }
      let pco: PeerConnectionObserver | null = this.getPCO(call, result);
      if (!pco) {
        return;
      }
      if (!pco.dataChannelSend(getDataChannelId(call), byteBuffer.buffer, isBinary)) {
        this.resultError('dataChannelSend', 'data channel was not found or send failed', result);
        return;
      }
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'dataChannelSend failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 关闭并释放指定数据通道。
   * @param call 方法调用（参数：dataChannelId）
   * @param result 回调句柄
   */
  dataChannelClose(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.dataChannelClose(getDataChannelId(call));
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'dataChannelClose failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 重启 ICE。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 调用结果
   */
  restartIce(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.restartIce();
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'restartIce failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 关闭 PeerConnection。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 调用结果
   */
  peerConnectionClose(call: MethodCall, result: MethodResult): void {
    try {
      this.getPCO(call, result)?.close();
      result.success(null);
    } catch (error) {
      this.resultError(call.method, 'peerConnectionClose failed: ' + JSON.stringify(error), result);
    }
  }

  /**
   * 释放 PeerConnection 并从映射移除；音频 owner 由 PeerConnectionObserver.dispose() 按轨道对称释放。
   * @param call 方法调用（参数：peerConnectionId）
   * @param result 回调句柄
   */
  peerConnectionDispose(call: MethodCall, result: MethodResult, peerConnectionId: string): void {
    let pco: PeerConnectionObserver | null = this.getPCO(call, result);
    if (!pco) {
      return;
    }
    let disposedOk: boolean = true;
    try {
      pco.dispose();
    } catch (error) {
      disposedOk = false;
      Log.e(TAG, 'peerConnectionDispose failed: ' + JSON.stringify(error));
      this.resultError('peerConnectionDispose', 'peerConnection dispose failed: ' + JSON.stringify(error), result);
    } finally {
      // 无论 dispose 是否抛出，都需从映射移除，避免 PCO 泄漏
      this.peerConnectionObservers.remove(peerConnectionId);
    }
    if (!disposedOk) {
      return;
    }
    result.success(null);
  }
}
 
