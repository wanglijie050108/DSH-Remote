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
import { Log } from '@ohos/flutter_ohos';

const TAG: string = 'FlutterWebRTCPlugin-CameraResourceReleaser';

/** Camera objects owned by the current capture session and released as one unit. */
export interface CameraResources {
  session?: camera.Session;
  input?: camera.CameraInput;
  preview?: camera.PreviewOutput;
  photo?: camera.PhotoOutput;
  inputDevice?: camera.CameraDevice;
}

/**
 * Releases camera resources independently so one native failure cannot skip later cleanup.
 * @param resources camera resources owned by the active capture session
 * @returns Promise completed after every releasable resource has been attempted
 */
export async function releaseCameraResources(resources: CameraResources): Promise<void> {
  try {
    await resources.session?.stop();
  } catch (error) {
    Log.e(TAG, 'session.stop failed: ' + JSON.stringify(error));
  }
  try {
    if (resources.input && resources.inputDevice) {
      resources.input.off('error', resources.inputDevice);
    }
  } catch (error) {
    Log.e(TAG, 'input.off failed: ' + JSON.stringify(error));
  }
  try {
    resources.input?.close();
  } catch (error) {
    Log.e(TAG, 'input.close failed: ' + JSON.stringify(error));
  }
  try {
    await resources.preview?.release();
  } catch (error) {
    Log.e(TAG, 'preview.release failed: ' + JSON.stringify(error));
  }
  try {
    await resources.photo?.release();
  } catch (error) {
    Log.e(TAG, 'photo.release failed: ' + JSON.stringify(error));
  }
  try {
    await resources.session?.release();
  } catch (error) {
    Log.e(TAG, 'session.release failed: ' + JSON.stringify(error));
  }
}
