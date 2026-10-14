import 'package:flutter_tts/flutter_tts.dart';

import '../models/voice_language.dart';

/// Phase 13F — Jacky's spoken replies. PRESENTATION ONLY: the on-screen
/// text stays the source of truth, and nothing spoken ever creates a sale,
/// cart line, payment or backend request. Callers treat every failure as
/// "not spoken" (the Quick Bill works without TTS).
abstract class VoiceTtsService {
  /// Speaks [text] in [language] (Phase 13G), stopping anything still being
  /// spoken. Completes when the speech has finished (or was stopped).
  Future<void> speak(
    String text, {
    VoiceLanguage language = VoiceLanguage.english,
  });

  /// Stops the current speech, if any.
  Future<void> stop();

  Future<void> dispose();
}

/// The device's text-to-speech engine (flutter_tts), speaking in the
/// requested [VoiceLanguage]'s code (en-US for English).
class FlutterTtsService implements VoiceTtsService {
  FlutterTtsService();

  final FlutterTts _tts = FlutterTts();
  bool _ready = false;
  String? _languageCode;

  Future<void> _init(VoiceLanguage language) async {
    if (!_ready) {
      await _tts.awaitSpeakCompletion(true);
      _ready = true;
    }
    if (_languageCode != language.code) {
      // Phase 13H: another language needs a voice on the device; without
      // one nothing is spoken (never in a different language).
      if (language != VoiceLanguage.english &&
          await _tts.isLanguageAvailable(language.ttsLocale) != true) {
        throw StateError('No ${language.label} voice on this device');
      }
      await _tts.setLanguage(language.ttsLocale);
      _languageCode = language.code;
    }
  }

  @override
  Future<void> speak(
    String text, {
    VoiceLanguage language = VoiceLanguage.english,
  }) async {
    await _init(language);
    await _tts.stop();
    await _tts.speak(text);
  }

  @override
  Future<void> stop() async {
    if (_ready) await _tts.stop();
  }

  @override
  Future<void> dispose() => stop();
}
