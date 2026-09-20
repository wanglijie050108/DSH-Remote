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
 
import { audio } from '@kit.AudioKit';

// 协议契约：以下 Map 的 key 与 Dart 层 OhosStreamUsage 枚举成员名（经
// describeEnum 序列化后的字符串）严格一一对应，不可改名。
// 语义明确、无歧义。两端 key 不一致将导致 setOhosAudioConfiguration 解析失败。
const STREAM_USAGES: Map<string, audio.StreamUsage> = new Map([
  ['unknown', audio.StreamUsage.STREAM_USAGE_UNKNOWN],
  ['music', audio.StreamUsage.STREAM_USAGE_MUSIC],
  ['voiceCommunication', audio.StreamUsage.STREAM_USAGE_VOICE_COMMUNICATION],
  ['voiceAssistant', audio.StreamUsage.STREAM_USAGE_VOICE_ASSISTANT],
  ['alarm', audio.StreamUsage.STREAM_USAGE_ALARM],
  ['voiceMessage', audio.StreamUsage.STREAM_USAGE_VOICE_MESSAGE],
  ['ringtone', audio.StreamUsage.STREAM_USAGE_RINGTONE],
  ['notification', audio.StreamUsage.STREAM_USAGE_NOTIFICATION],
  ['accessibility', audio.StreamUsage.STREAM_USAGE_ACCESSIBILITY],
  ['movie', audio.StreamUsage.STREAM_USAGE_MOVIE],
  ['game', audio.StreamUsage.STREAM_USAGE_GAME],
  ['audioBook', audio.StreamUsage.STREAM_USAGE_AUDIOBOOK],
  ['navigation', audio.StreamUsage.STREAM_USAGE_NAVIGATION],
  ['videoCommunication', audio.StreamUsage.STREAM_USAGE_VIDEO_COMMUNICATION]
]);

// 协议契约：以下 Map 的 key 与 Dart 层 OhosSourceType 枚举成员名严格一一对应，不可改名。
const SOURCE_TYPES: Map<string, audio.SourceType> = new Map([
  ['invalid', audio.SourceType.SOURCE_TYPE_INVALID],
  ['mic', audio.SourceType.SOURCE_TYPE_MIC],
  ['voiceRecognition', audio.SourceType.SOURCE_TYPE_VOICE_RECOGNITION],
  ['voiceCommunication', audio.SourceType.SOURCE_TYPE_VOICE_COMMUNICATION],
  ['voiceMessage', audio.SourceType.SOURCE_TYPE_VOICE_MESSAGE],
  ['camcorder', audio.SourceType.SOURCE_TYPE_CAMCORDER]
]);

/**
 * Resolves a method-channel stream usage name to the native enum.
 * @param value serialized stream usage name
 * @returns native stream usage, or undefined for an unknown value
 */
export function resolveStreamUsage(value: string): audio.StreamUsage | undefined {
  return STREAM_USAGES.get(value);
}

/**
 * Resolves a method-channel source type name to the native enum.
 * @param value serialized source type name
 * @returns native source type, or undefined for an unknown value
 */
export function resolveSourceType(value: string): audio.SourceType | undefined {
  return SOURCE_TYPES.get(value);
}
