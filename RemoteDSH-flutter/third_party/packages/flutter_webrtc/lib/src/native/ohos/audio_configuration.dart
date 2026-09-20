import 'package:flutter/foundation.dart';

import '../utils.dart';

enum OhosStreamUsage {
  unknown,
  music,
  voiceCommunication,
  voiceAssistant,
  alarm,
  voiceMessage,
  ringtone,
  notification,
  accessibility,
  movie,
  game,
  audioBook,
  navigation,
  videoCommunication,
}

extension OhosStreamUsageExt on OhosStreamUsage {
  String get value => describeEnum(this);
}

extension OhosStreamUsageEnumEx on String {
  OhosStreamUsage toOhosStreamUsage() => OhosStreamUsage.values
      .firstWhere((d) => describeEnum(d) == toLowerCase());
}

enum OhosSourceType {
  invalid,
  mic,
  voiceRecognition,
  voiceCommunication,
  voiceMessage,
  camcorder
}

extension OhosSourceTypeExt on OhosSourceType {
  String get value => describeEnum(this);
}

extension OhosSourceTypeEnumEx on String {
  OhosSourceType toOhosSourceType() =>
      OhosSourceType.values.firstWhere((d) => describeEnum(d) == toLowerCase());
}

class OhosAudioConfiguration {
  OhosAudioConfiguration({
    this.ohosStreamUsage,
    this.ohosSourceType,
  });

  final OhosStreamUsage? ohosStreamUsage;
  final OhosSourceType? ohosSourceType;

  Map<String, dynamic> toMap() => <String, dynamic>{
        if (ohosStreamUsage != null) 'ohosStreamUsage': ohosStreamUsage!.value,
        if (ohosSourceType != null) 'ohosSourceType': ohosSourceType!.value,
      };

  /// A pre-configured OhosAudioConfiguration for media playback.
  static final media = OhosAudioConfiguration(
    ohosStreamUsage: OhosStreamUsage.music,
    ohosSourceType: OhosSourceType.camcorder,
  );

  /// A pre-configured OhosAudioConfiguration for voice communication.
  static final communication = OhosAudioConfiguration(
    ohosStreamUsage: OhosStreamUsage.voiceCommunication,
    ohosSourceType: OhosSourceType.mic,
  );
}

class OhosNativeAudioManagement {
  static Future<void> setOhosAudioConfiguration(
      OhosAudioConfiguration config) async {
    if (WebRTC.platformIsOhos) {
      await WebRTC.invokeMethod(
        'setOhosAudioConfiguration',
        <String, dynamic>{'configuration': config.toMap()},
      );
    }
  }

  /// Request capture permissions (camera/microphone) for OpenHarmony.
  static Future<bool> requestCapturePermission({
    bool camera = true,
    bool microphone = true,
  }) async {
    if (!WebRTC.platformIsOhos) {
      return false;
    }
    final constraints = <String, dynamic>{};
    if (camera) constraints['video'] = true;
    if (microphone) constraints['audio'] = true;
    final response = await WebRTC.invokeMethod(
      'requestCapturePermission',
      <String, dynamic>{'constraints': constraints},
    );
    return response ?? false;
  }

  /// Enable or disable hardware speaker mute on OpenHarmony.
  static Future<void> setSpeakerMute(bool mute) async {
    if (WebRTC.platformIsOhos) {
      await WebRTC.invokeMethod('setSpeakerMute', <String, dynamic>{
        'mute': mute,
      });
    }
  }

  /// Enable or disable hardware noise suppressor on OpenHarmony.
  static Future<bool> setNoiseSuppressorEnabled(bool enabled) async {
    if (!WebRTC.platformIsOhos) {
      return false;
    }
    final response = await WebRTC.invokeMethod(
      'setNoiseSuppressorEnabled',
      <String, dynamic>{'enabled': enabled},
    );
    return response ?? false;
  }

  /// Check if built-in acoustic echo canceller is supported on OpenHarmony.
  static Future<bool> isBuiltInAcousticEchoCancelerSupported() async {
    if (!WebRTC.platformIsOhos) {
      return false;
    }
    final response = await WebRTC.invokeMethod(
      'isBuiltInAcousticEchoCancelerSupported',
    );
    return response ?? false;
  }

  /// Check if built-in noise suppressor is supported on OpenHarmony.
  static Future<bool> isBuiltInNoiseSuppressorSupported() async {
    if (!WebRTC.platformIsOhos) {
      return false;
    }
    final response = await WebRTC.invokeMethod(
      'isBuiltInNoiseSuppressorSupported',
    );
    return response ?? false;
  }
}
