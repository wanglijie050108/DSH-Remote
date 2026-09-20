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
 
import camera from '@ohos.multimedia.camera';
import { display } from '@kit.ArkUI';
import { Log } from '@ohos/flutter_ohos';

const TAG: string = 'FlutterWebRTCPlugin-CameraProfileUtils';

export interface ProfileSelection {
  previewProfile: camera.Profile | undefined;
  photoProfile: camera.Profile | undefined;
}

/**
 * Returns NORMAL_PHOTO output capabilities when the device supports that mode.
 * @param manager camera manager for the current engine context
 * @param device camera device to query
 * @returns output capability, or undefined when unsupported or unavailable
 */
export function getOutputCapability(
  manager: camera.CameraManager,
  device: camera.CameraDevice
): camera.CameraOutputCapability | undefined {
  try {
    let supported: boolean = manager.getSupportedSceneModes(device)
      .indexOf(camera.SceneMode.NORMAL_PHOTO) >= 0;
    if (!supported) {
      Log.e(TAG, 'NORMAL_PHOTO is not supported');
      return undefined;
    }
    return manager.getSupportedOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
  } catch (error) {
    Log.e(TAG, 'getOutputCapability failed: ' + JSON.stringify(error));
    return undefined;
  }
}

function matchesPreview(profile: camera.Profile, foldStatus: number): boolean {
  let screen: display.Display = display.getDefaultDisplaySync();
  if (screen.width <= 1080) {
    return profile.size.height === 1080 && profile.size.width === 1440;
  }
  if (screen.width <= 1440) {
    return profile.size.height === 1440 && profile.size.width === 1920;
  }
  let aspectRatio: number = profile.size.width / profile.size.height;
  let threshold: number = foldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED ? 1 : 4 / 3;
  return profile.size.height <= screen.width && profile.size.height >= 1080 &&
    aspectRatio < screen.height / screen.width && aspectRatio > threshold;
}

function matchesPhoto(profile: camera.Profile, preview: camera.Profile | undefined,
  foldStatus: number): boolean {
  if (!preview) {
    return false;
  }
  let ratio: number = foldStatus === display.FoldStatus.FOLD_STATUS_EXPANDED ? 1 :
    preview.size.height / preview.size.width;
  return profile.size.width <= 4096 && profile.size.width >= 2448 &&
    profile.size.height === ratio * profile.size.width;
}

/**
 * Selects compatible preview and photo profiles for the current display geometry.
 * @param capability supported camera output profiles
 * @param foldStatus current display fold status
 * @returns selected preview and photo profiles
 */
export function selectProfiles(capability: camera.CameraOutputCapability,
  foldStatus: number): ProfileSelection {
  let preview: camera.Profile | undefined = capability.previewProfiles.find(
    (profile: camera.Profile): boolean => matchesPreview(profile, foldStatus));
  let photo: camera.Profile | undefined = capability.photoProfiles.find(
    (profile: camera.Profile): boolean => matchesPhoto(profile, preview, foldStatus));
  return { previewProfile: preview, photoProfile: photo };
}
