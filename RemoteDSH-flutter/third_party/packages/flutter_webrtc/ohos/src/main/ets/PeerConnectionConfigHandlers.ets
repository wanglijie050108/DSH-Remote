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
import { BinaryMessenger, Log } from '@ohos/flutter_ohos';
import { HashMap } from '@kit.ArkTS';
// 2. 第三方库导入
import {
  RTCPeerConnection,
  RTCBundlePolicy,
  RTCCandidateNetworkPolicy,
  RTCConfiguration,
  RTCContinualGatheringPolicy,
  RTCIceServer,
  RTCIceTransportPolicy,
  RTCKeyType,
  RTCRtcpMuxPolicy,
  RTCSdpSemantics,
  RTCTcpCandidatePolicy,
  PeerConnectionFactory,
} from 'libohos_webrtc.so';
// 3. 本地模块导入
import { ConstraintsArray } from './utils/ConstraintsArray';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { ObjectType } from './utils/ObjectType';
import PeerConnectionObserver from './PeerConnectionObserver';
import StateProvider from './StateProvider';
import AudioSwitchManager from './audio/AudioSwitchManager';

const TAG: string = 'FlutterWebRTCPlugin-PeerConnectionConfigHandlers';

/**
 * PeerConnection 工厂与配置相关方法集合（工厂创建/懒加载、PC 初始化、
 * RTC 配置解析、ICE Server 解析）。
 *
 * 抽离自 MethodCallHandlerImpl，通过构造函数注入共享的 peerConnectionObservers 映射、
 * messenger、stateProvider、getNextStreamUUID 回调与 pcf 的访问器，与原实现保持等价行为。
 */

/**
 * PeerConnection 配置处理器的依赖注入配置对象，避免构造函数参数数量超标。
 */
export interface PeerConnectionConfigHandlersOptions {
  messenger: BinaryMessenger;
  stateProvider: StateProvider;
  peerConnectionObservers: HashMap<string, PeerConnectionObserver>;
  getNextStreamUUID: () => string;
  getPcf: () => PeerConnectionFactory | null;
  setPcf: (pcf: PeerConnectionFactory | null) => void;
}

export class PeerConnectionConfigHandlers {
  private messenger: BinaryMessenger;
  private stateProvider: StateProvider;
  private peerConnectionObservers: HashMap<string, PeerConnectionObserver>;
  private getNextStreamUUID: () => string;
  private getPcf: () => PeerConnectionFactory | null;
  private setPcf: (pcf: PeerConnectionFactory | null) => void;

  /**
   * 构造函数，注入 PeerConnection 配置处理器所需的依赖（messenger、stateProvider、
   * peerConnectionObservers 映射、getNextStreamUUID 回调与 pcf 访问器）。
   * @param options 依赖注入配置对象
   */
  constructor(options: PeerConnectionConfigHandlersOptions) {
    this.messenger = options.messenger;
    this.stateProvider = options.stateProvider;
    this.peerConnectionObservers = options.peerConnectionObservers;
    this.getNextStreamUUID = options.getNextStreamUUID;
    this.getPcf = options.getPcf;
    this.setPcf = options.setPcf;
  }

  /**
   * 创建 PeerConnectionFactory，使用 libohos_webrtc.so 的默认配置。
   * 包裹 try-catch 以记录精确错误上下文，异常重新抛出由顶层安全网捕获并传播到 Flutter。
   */
  createPeerConnectionFactory(): void {
    Log.i(TAG, '[createPeerConnectionFactory] using native defaults from libohos_webrtc.so');
    try {
      let pcf: PeerConnectionFactory = new PeerConnectionFactory({
        adm: AudioSwitchManager.getExistingInstance()?.getAudioDeviceModule()
      });
      this.setPcf(pcf);
      Log.i(TAG, `[createPeerConnectionFactory] PeerConnectionFactory created: pcf=${this.getPcf() !== null}`);
    } catch (error) {
      Log.e(TAG, '[createPeerConnectionFactory] failed: ' + JSON.stringify(error));
      throw new Error('createPeerConnectionFactory failed: ' + JSON.stringify(error));
    }
  }

  /**
   * 懒加载获取 PeerConnectionFactory，首次调用时创建。
   * @returns PeerConnectionFactory 实例
   */
  getPeerConnectionFactory(): PeerConnectionFactory {
    let pcf: PeerConnectionFactory | null = this.getPcf();
    if (pcf) {
      return pcf;
    }
    // Lazy initialization: factory is created on first use, relying on libohos_webrtc.so defaults.
    Log.i(TAG, 'getPeerConnectionFactory: lazy init');
    this.createPeerConnectionFactory();
    pcf = this.getPcf();
    if (!pcf) {
      Log.e(TAG, 'getPeerConnectionFactory: failed to create PeerConnectionFactory');
      throw new Error('Failed to create PeerConnectionFactory');
    }
    return pcf;
  }

  /**
   * 初始化 PeerConnection：生成 id、解析配置、创建底层连接并注册观察者。
   * @param configurationMap RTC 配置约束
   * @param constraintsMap 媒体约束
   * @returns PeerConnection id
   */
  peerConnectionInit(configurationMap: ConstraintsMap, constraintsMap: ConstraintsMap): string {
    let peerConnectionId: string = this.getNextStreamUUID();
    Log.d(TAG, 'peerConnectionInit peerConnectionId= ' + peerConnectionId);
    let conf: RTCConfiguration = this.parseRTCConfiguration(configurationMap);
    // Lazily creates the factory via getPeerConnectionFactory().
    let peerConnection: RTCPeerConnection = this.getPeerConnectionFactory().createPeerConnection(conf);
    let observer: PeerConnectionObserver =
      new PeerConnectionObserver(conf, this.stateProvider, this.messenger, peerConnectionId, peerConnection);
    this.peerConnectionObservers.set(peerConnectionId, observer);
    return peerConnectionId;
  }

  /**
   * 将 Flutter RTCConfiguration 完整映射为 OHOS 原生配置。
   * @param map 配置约束
   * @returns RTCConfiguration
   */
  parseRTCConfiguration(map: ConstraintsMap): RTCConfiguration {
    let iceServersArray: ConstraintsArray = new ConstraintsArray();
    if (map.getType('iceServers') === ObjectType.ARRAY) {
      let configuredServers: ConstraintsArray | null = map.getArray('iceServers');
      if (configuredServers) {
        iceServersArray = configuredServers;
      }
      Log.d(TAG, 'parseRTCConfiguration iceServersArray= ' + iceServersArray);
    }
    let conf: RTCConfiguration = {
      iceServers: this.createIceServers(iceServersArray)
    };
    this.applyPublicConfiguration(conf, map);
    this.applyAdvancedConfiguration(conf, map);
    Log.d(TAG, 'parseRTCConfiguration conf= ' + JSON.stringify(conf));
    return conf;
  }

  /**
   * 映射 WebRTC 标准公开配置项，并忽略无效枚举值。
   * @param conf 待填充的 RTCConfiguration
   * @param map 配置约束
   */
  private applyPublicConfiguration(conf: RTCConfiguration, map: ConstraintsMap): void {
    if (map.getType('iceTransportPolicy') === ObjectType.STRING) {
      conf.iceTransportPolicy = this.parseIceTransportPolicy(map.getString('iceTransportPolicy'));
    }
    if (map.getType('bundlePolicy') === ObjectType.STRING) {
      conf.bundlePolicy = this.parseBundlePolicy(map.getString('bundlePolicy'));
    }
    if (map.getType('rtcpMuxPolicy') === ObjectType.STRING) {
      conf.rtcpMuxPolicy = this.parseRtcpMuxPolicy(map.getString('rtcpMuxPolicy'));
    }
    if (map.getType('sdpSemantics') === ObjectType.STRING) {
      conf.sdpSemantics = this.parseSdpSemantics(map.getString('sdpSemantics'));
    }
    if (map.getType('iceCandidatePoolSize') === ObjectType.NUMBER) {
      let poolSize: number = map.getNumber('iceCandidatePoolSize');
      conf.iceCandidatePoolSize = Math.max(0, Math.min(65535, Math.round(poolSize)));
    }
  }

  /**
   * 映射各移动端共用的 WebRTC 扩展配置项。
   * @param conf 待填充的 RTCConfiguration
   * @param map 配置约束
   */
  private applyAdvancedConfiguration(conf: RTCConfiguration, map: ConstraintsMap): void {
    if (map.getType('maxIPv6Networks') === ObjectType.NUMBER) {
      conf.maxIPv6Networks = map.getNumber('maxIPv6Networks');
    }
    if (map.getType('tcpCandidatePolicy') === ObjectType.STRING) {
      conf.tcpCandidatePolicy = this.parseTcpCandidatePolicy(map.getString('tcpCandidatePolicy'));
    }
    if (map.getType('candidateNetworkPolicy') === ObjectType.STRING) {
      conf.candidateNetworkPolicy = this.parseCandidateNetworkPolicy(map.getString('candidateNetworkPolicy'));
    }
    if (map.getType('keyType') === ObjectType.STRING) {
      conf.keyType = this.parseKeyType(map.getString('keyType'));
    }
    if (map.getType('continualGatheringPolicy') === ObjectType.STRING) {
      conf.continualGatheringPolicy = this.parseGatheringPolicy(map.getString('continualGatheringPolicy'));
    }
    this.applyAdvancedNumberConfiguration(conf, map);
    this.applyAdvancedBooleanConfiguration(conf, map);
  }

  /**
   * 映射高级数值配置项。
   * @param conf 待填充的 RTCConfiguration
   * @param map 配置约束
   */
  private applyAdvancedNumberConfiguration(conf: RTCConfiguration, map: ConstraintsMap): void {
    if (map.getType('audioJitterBufferMaxPackets') === ObjectType.NUMBER) {
      conf.audioJitterBufferMaxPackets = map.getNumber('audioJitterBufferMaxPackets');
    }
    if (map.getType('iceConnectionReceivingTimeout') === ObjectType.NUMBER) {
      conf.iceConnectionReceivingTimeout = map.getNumber('iceConnectionReceivingTimeout');
    }
    if (map.getType('iceBackupCandidatePairPingInterval') === ObjectType.NUMBER) {
      conf.iceBackupCandidatePairPingInterval = map.getNumber('iceBackupCandidatePairPingInterval');
    }
  }

  /**
   * 映射高级布尔配置项。
   * @param conf 待填充的 RTCConfiguration
   * @param map 配置约束
   */
  private applyAdvancedBooleanConfiguration(conf: RTCConfiguration, map: ConstraintsMap): void {
    if (map.getType('audioJitterBufferFastAccelerate') === ObjectType.BOOLEAN) {
      conf.audioJitterBufferFastAccelerate = map.getBoolean('audioJitterBufferFastAccelerate');
    }
    if (map.getType('pruneTurnPorts') === ObjectType.BOOLEAN) {
      conf.pruneTurnPorts = map.getBoolean('pruneTurnPorts');
    }
    if (map.getType('presumeWritableWhenFullyRelayed') === ObjectType.BOOLEAN) {
      conf.presumeWritableWhenFullyRelayed = map.getBoolean('presumeWritableWhenFullyRelayed');
    }
    if (map.getType('enableCpuOveruseDetection') === ObjectType.BOOLEAN) {
      conf.enableCpuOveruseDetection = map.getBoolean('enableCpuOveruseDetection');
    }
  }

  /**
   * 将字符串解析为 ICE 传输策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCIceTransportPolicy 或 undefined
   */
  private parseIceTransportPolicy(value: string): RTCIceTransportPolicy | undefined {
    return value === 'all' || value === 'relay' ? value : undefined;
  }

  /**
   * 将字符串解析为 bundle 策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCBundlePolicy 或 undefined
   */
  private parseBundlePolicy(value: string): RTCBundlePolicy | undefined {
    return value === 'balanced' || value === 'max-bundle' || value === 'max-compat' ? value : undefined;
  }

  /**
   * 将字符串解析为 rtcp mux 策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCRtcpMuxPolicy 或 undefined
   */
  private parseRtcpMuxPolicy(value: string): RTCRtcpMuxPolicy | undefined {
    return value === 'require' ? value : undefined;
  }

  /**
   * 将字符串解析为 SDP 语义枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCSdpSemantics 或 undefined
   */
  private parseSdpSemantics(value: string): RTCSdpSemantics | undefined {
    return value === 'plan-b' || value === 'unified-plan' ? value : undefined;
  }

  /**
   * 将字符串解析为 TCP 候选策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCTcpCandidatePolicy 或 undefined
   */
  private parseTcpCandidatePolicy(value: string): RTCTcpCandidatePolicy | undefined {
    return value === 'enabled' || value === 'disabled' ? value : undefined;
  }

  /**
   * 将字符串解析为候选网络策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCCandidateNetworkPolicy 或 undefined
   */
  private parseCandidateNetworkPolicy(value: string): RTCCandidateNetworkPolicy | undefined {
    return value === 'all' || value === 'low_cost' ? value : undefined;
  }

  /**
   * 将字符串解析为密钥类型枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCKeyType 或 undefined
   */
  private parseKeyType(value: string): RTCKeyType | undefined {
    return value === 'RSA' || value === 'ECDSA' ? value : undefined;
  }

  /**
   * 将字符串解析为持续收集策略枚举，非法值返回 undefined。
   * @param value 原始字符串
   * @returns 合法的 RTCContinualGatheringPolicy 或 undefined
   */
  private parseGatheringPolicy(value: string): RTCContinualGatheringPolicy | undefined {
    return value === 'gather_once' || value === 'gather_continually' ? value : undefined;
  }

  /**
   * 从约束数组解析 ICE Server 列表，支持 url/urls 及 username/credential。
   * @param iceServersArray ICE Server 约束数组
   * @returns RTCIceServer 列表
   */
  createIceServers(iceServersArray: ConstraintsArray): RTCIceServer[] {
    Log.d(TAG, 'createIceServers in');
    let iceServers: RTCIceServer[] = [];
    for (let i = 0; i < iceServersArray.size(); i++) {
      if (iceServersArray.getType(i) !== ObjectType.MAP) {
        continue;
      }
      let iceServerMap: ConstraintsMap = new ConstraintsMap(iceServersArray.getMap(i));
      let hasUsernameAndCredential: boolean =
        iceServerMap.hasKey('username') && iceServerMap.hasKey('credential');
      // 参数边界校验：至少提供 url 或 urls，且取到的值必须为非空合法字符串，
      // 否则跳过该条目
      let rawUrl: string = '';
      if (iceServerMap.hasKey('url')) {
        rawUrl = iceServerMap.getString('url');
      } else if (iceServerMap.hasKey('urls')) {
        rawUrl = iceServerMap.getString('urls');
      }
      if (!this.isValidIceServerUrl(rawUrl)) {
        Log.w(TAG, `createIceServers: skip invalid ice server at index ${i}, url/urls missing or invalid`);
        continue;
      }
      let server: RTCIceServer = { urls: rawUrl };
      if (hasUsernameAndCredential) {
        server.username = iceServerMap.getString('username');
        server.credential = iceServerMap.getString('credential');
      }
      iceServers.push(server);
    }
    return iceServers;
  }

  /**
   * 校验 ICE Server 的 url/urls 是否为合法非空字符串。
   * 支持 stun:/turn:/turns: 等 scheme（含空格或空串视为非法）。
   * @param url 待校验的 url/urls 字符串
   * @returns 是否合法
   */
  private isValidIceServerUrl(url: string): boolean {
    if (!url || typeof url !== 'string' || url.trim().length === 0) {
      return false;
    }
    return url.startsWith('stun:') || url.startsWith('turn:') || url.startsWith('turns:');
  }
}
