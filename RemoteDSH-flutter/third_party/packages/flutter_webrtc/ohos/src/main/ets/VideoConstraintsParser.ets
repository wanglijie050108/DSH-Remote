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
 
import { Log } from '@ohos/flutter_ohos';
import { ConstraintsMap } from './utils/ConstraintsMap';
import { ObjectType } from './utils/ObjectType';

const TAG: string = 'FlutterWebRTCPlugin-VideoConstraintsParser';

/** Parsed video and mandatory constraint maps used during camera capture setup. */
export interface VideoConstraintsResult {
  videoConstraintsMap: ConstraintsMap;
  videoConstraintsMandatory: ConstraintsMap;
}

/** Parses Flutter video constraints without coupling mapping policy to capture lifecycle code. */
export class VideoConstraintsParser {
  /** Separates the video constraint map and its mandatory subsection. */
  parse(constraints: ConstraintsMap): VideoConstraintsResult {
    let video: ConstraintsMap = new ConstraintsMap();
    let mandatory: ConstraintsMap = new ConstraintsMap();
    if (constraints.getType('video') === ObjectType.MAP) {
      video = constraints.getMap('video') ?? new ConstraintsMap();
      if (video.getType('mandatory') === ObjectType.MAP) {
        mandatory = video.getMap('mandatory') ?? new ConstraintsMap();
      }
    }
    return { videoConstraintsMap: video, videoConstraintsMandatory: mandatory };
  }

  /** Resolves an explicit, mandatory, or default numeric video constraint. */
  resolveNumber(map: ConstraintsMap, mandatory: ConstraintsMap,
    key: string, mandatoryKey: string, defaultValue: number): number {
    let value: number | null = this.getNumber(map, key);
    if (value !== null) {
      return value;
    }
    if (mandatory.hasKey(mandatoryKey)) {
      return mandatory.getNumber(mandatoryKey);
    }
    return defaultValue;
  }

  /** Returns the requested camera facing mode or an empty value. */
  getFacingMode(constraints: ConstraintsMap): string {
    return constraints.getType('facingMode') === ObjectType.STRING ? constraints.getString('facingMode') : '';
  }

  private getNumber(map: ConstraintsMap, key: string): number | null {
    try {
      if (map.getType(key) === ObjectType.NUMBER) {
        return map.getNumber(key);
      }
      if (map.getType(key) === ObjectType.STRING) {
        return parseInt(map.getString(key));
      }
      if (map.getType(key) === ObjectType.MAP) {
        let inner: ConstraintsMap | null = map.getMap(key);
        if (inner?.getType('ideal') === ObjectType.NUMBER) {
          return inner.getNumber('ideal');
        }
      }
    } catch (error) {
      Log.e(TAG, `Invalid constraint ${key}: ${JSON.stringify(error)}`);
    }
    return null;
  }
}
