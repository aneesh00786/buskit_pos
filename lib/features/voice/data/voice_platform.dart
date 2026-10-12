import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../models/voice_language.dart';

/// Phase 13A — the microphone permission, as the voice feature needs it.
enum VoicePermission {
  granted,
  denied,

  /// Refused for good: only the device settings can change it.
  permanentlyDenied,

  /// Not available on this device / platform (e.g. restricted).
  unavailable,

  /// Phase 6ZA/6ZB: voice input is not offered on this platform at all (the
  /// desktop apps: `permission_handler` has no macOS implementation, and the
  /// Windows speech plugin is unvalidated) — nothing is asked and no
  /// microphone is opened.
  unsupportedPlatform,
}

/// Microphone permission. Asked ONLY when voice is first used (never at
/// app start). Tests substitute a fake.
abstract class MicrophonePermission {
  /// Current state, without asking.
  Future<VoicePermission> status();

  /// Shows the system prompt (when the platform still allows it).
  Future<VoicePermission> request();

  /// Opens the app's system settings (for [VoicePermission.permanentlyDenied]).
  Future<bool> openSettings();
}

/// Phase 6ZA/6ZB — the microphone permission for the platform the app runs
/// on: [PermissionHandlerMicrophone] on Android / iOS (unchanged), and
/// [UnsupportedPlatformMicrophone] on the desktop apps (macOS: no
/// `permission_handler` implementation; Windows / Linux: speech input not
/// validated), so no unsupported or untested plugin path is ever called.
MicrophonePermission defaultMicrophonePermission([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  const desktop = {TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux};
  if (!kIsWeb && desktop.contains(p)) return const UnsupportedPlatformMicrophone();
  return const PermissionHandlerMicrophone();
}

/// Phase 6ZA — voice input is not offered on this platform: nothing is asked,
/// no plugin is called, no microphone is opened.
class UnsupportedPlatformMicrophone implements MicrophonePermission {
  const UnsupportedPlatformMicrophone();

  @override
  Future<VoicePermission> status() async => VoicePermission.unsupportedPlatform;

  @override
  Future<VoicePermission> request() async => VoicePermission.unsupportedPlatform;

  @override
  Future<bool> openSettings() async => false;
}

class PermissionHandlerMicrophone implements MicrophonePermission {
  const PermissionHandlerMicrophone();

  static VoicePermission _map(ph.PermissionStatus s) {
    if (s.isGranted || s.isLimited) return VoicePermission.granted;
    if (s.isPermanentlyDenied) return VoicePermission.permanentlyDenied;
    if (s.isRestricted) return VoicePermission.unavailable;
    return VoicePermission.denied;
  }

  @override
  Future<VoicePermission> status() async =>
      _map(await ph.Permission.microphone.status);

  @override
  Future<VoicePermission> request() async =>
      _map(await ph.Permission.microphone.request());

  @override
  Future<bool> openSettings() => ph.openAppSettings();
}

/// Speech-to-text: microphone audio in, recognized TEXT out. Nothing here
/// interprets the text or talks to the POS backend. Tests substitute a fake.
abstract class SpeechRecognizer {
  /// Prepares the platform recognizer; false when it is unavailable.
  /// [onError] / [onStatus] report asynchronous recognizer events.
  Future<bool> initialize({
    required void Function(String error) onError,
    required void Function(String status) onStatus,
  });

  /// Starts listening in [language] (Phase 13G); [onResult] receives
  /// partial and final text.
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    VoiceLanguage language = VoiceLanguage.english,
  });

  /// Stops listening; the final result (if any) still arrives via onResult.
  Future<void> stop();

  /// Stops listening and discards the result.
  Future<void> cancel();
}

/// The `speech_to_text` package: the device's own speech recognition
/// service (Android SpeechRecognizer / iOS Speech framework).
class SpeechToTextRecognizer implements SpeechRecognizer {
  SpeechToTextRecognizer([stt.SpeechToText? speech])
    : _speech = speech ?? stt.SpeechToText();
  final stt.SpeechToText _speech;

  @override
  Future<bool> initialize({
    required void Function(String error) onError,
    required void Function(String status) onStatus,
  }) => _speech.initialize(
    onError: (SpeechRecognitionError e) => onError(e.errorMsg),
    onStatus: onStatus,
  );

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
    VoiceLanguage language = VoiceLanguage.english,
  }) => _speech.listen(
    onResult: (SpeechRecognitionResult r) =>
        onResult(r.recognizedWords, r.finalResult),
    listenOptions: stt.SpeechListenOptions(
      partialResults: true,
      cancelOnError: true,
      listenMode: stt.ListenMode.confirmation,
      localeId: language.code, // en-US for English
    ),
  );

  @override
  Future<void> stop() => _speech.stop();

  @override
  Future<void> cancel() => _speech.cancel();
}
