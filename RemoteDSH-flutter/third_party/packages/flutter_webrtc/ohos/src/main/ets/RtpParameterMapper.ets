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
 
import {
  MediaStream,
  RTCRtpCodec,
  RTCRtpEncodingParameters,
  RTCRtpSendParameters,
  RTCRtpTransceiverDirection,
  RTCRtpTransceiverInit
} from 'libohos_webrtc.so';
import { ConstraintsArray } from './utils/ConstraintsArray';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { DataArray, DataMap, MethodChannelValue, ObjectType } from './utils/ObjectType';

/** Converts Flutter MethodChannel RTP maps into strongly typed native structures. */
export class RtpParameterMapper {
  /**
   * Converts transceiver initialization parameters, including simulcast encodings.
   * @param parameters Flutter transceiver initialization map
   * @param streams media streams associated with the transceiver
   * @returns native initialization object, or undefined when parameters are absent
   */
  mapTransceiverInit(parameters?: DataMap, streams?: MediaStream[]): RTCRtpTransceiverInit | undefined {
    if (!parameters) {
      return undefined;
    }
    let parameterMap: ConstraintsMap = new ConstraintsMap(parameters);
    let encodingsParams: ConstraintsArray | null = parameterMap.getArray('sendEncodings');
    let sendEncodings: RTCRtpEncodingParameters[] = [];
    if (encodingsParams) {
      for (let index = 0; index < encodingsParams.size(); index++) {
        if (encodingsParams.getType(index) === ObjectType.MAP) {
          sendEncodings.push(this.mapEncoding(encodingsParams.getMap(index)));
        }
      }
    }
    let init: RTCRtpTransceiverInit = {
      direction: this.parseDirection(parameterMap.getString('direction')),
      streams: streams ?? []
    };
    if (encodingsParams) {
      init.sendEncodings = sendEncodings;
    }
    return init;
  }

  /**
   * Converts one Flutter encoding map to native encoding parameters.
   * @param parameters Flutter encoding parameter map
   * @returns native RTP encoding parameters
   */
  mapEncoding(parameters: DataMap): RTCRtpEncodingParameters {
    let map: ConstraintsMap = new ConstraintsMap(parameters);
    let encoding: RTCRtpEncodingParameters = {};
    this.applyEncodingUpdate(encoding, map);
    return encoding;
  }

  /**
   * Applies Flutter encoding updates to an existing native sender parameter object.
   * @param parameters current sender parameters
   * @param newParameters Flutter sender update map
   * @returns the updated native sender parameters
   */
  updateSendParameters(parameters: RTCRtpSendParameters, newParameters: DataMap): RTCRtpSendParameters {
    let encodingArray: ConstraintsArray | null = new ConstraintsMap(newParameters).getArray('encodings');
    if (!encodingArray) {
      return parameters;
    }
    for (let index = 0; index < encodingArray.size(); index++) {
      if (encodingArray.getType(index) !== ObjectType.MAP) {
        continue;
      }
      let update: ConstraintsMap = new ConstraintsMap(encodingArray.getMap(index));
      let target: RTCRtpEncodingParameters | null =
        this.findEncoding(parameters.encodings, update.getString('rid'), index);
      if (target) {
        this.applyEncodingUpdate(target, update);
      }
    }
    return parameters;
  }

  /**
   * Converts an ordered Flutter codec list to native codec preference objects.
   * @param codecs serialized codec capability list
   * @returns native codecs in the requested preference order
   */
  mapCodecs(codecs: DataArray): RTCRtpCodec[] {
    let preferred: RTCRtpCodec[] = [];
    codecs.forEach((element: MethodChannelValue): void => {
      if (!(element instanceof Map)) {
        return;
      }
      let map: ConstraintsMap = new ConstraintsMap(element);
      let mimeType: string = map.getString('mimeType');
      let separator: number = mimeType.indexOf('/');
      let codec: RTCRtpCodec = {
        mimeType: mimeType,
        name: map.getType('name') === ObjectType.STRING ? map.getString('name') :
          (separator >= 0 ? mimeType.substring(separator + 1) : mimeType),
        clockRate: map.getNumber('clockRate'),
        sdpFmtpLine: map.getType('sdpFmtpLine') === ObjectType.STRING ? map.getString('sdpFmtpLine') : ''
      };
      if (map.getType('kind') === ObjectType.STRING) {
        codec.kind = map.getString('kind');
      }
      if (map.getType('payloadType') === ObjectType.NUMBER) {
        codec.payloadType = map.getNumber('payloadType');
      }
      if (map.getType('numChannels') === ObjectType.NUMBER) {
        codec.channels = map.getNumber('numChannels');
      }
      preferred.push(codec);
    });
    return preferred;
  }

  private findEncoding(encodings: RTCRtpEncodingParameters[], rid: string,
    fallbackIndex: number): RTCRtpEncodingParameters | null {
    if (rid !== '') {
      for (let encoding of encodings) {
        if (encoding.rid === rid) {
          return encoding;
        }
      }
    }
    return fallbackIndex < encodings.length ? encodings[fallbackIndex] : null;
  }

  private applyEncodingUpdate(target: RTCRtpEncodingParameters, update: ConstraintsMap): void {
    if (update.getType('active') === ObjectType.BOOLEAN) {
      target.active = update.getBoolean('active');
    }
    if (update.getType('maxBitrate') === ObjectType.NUMBER) {
      target.maxBitrate = update.getNumber('maxBitrate');
    }
    if (update.getType('maxFramerate') === ObjectType.NUMBER) {
      target.maxFramerate = update.getNumber('maxFramerate');
    }
    if (update.getType('scaleResolutionDownBy') === ObjectType.NUMBER) {
      target.scaleResolutionDownBy = update.getNumber('scaleResolutionDownBy');
    }
  }

  private parseDirection(value: string): RTCRtpTransceiverDirection {
    if (value === 'inactive' || value === 'recvonly' || value === 'sendonly' ||
      value === 'sendrecv' || value === 'stopped') {
      return value;
    }
    return 'sendrecv';
  }
}
