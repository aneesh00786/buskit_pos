import 'package:flutter/foundation.dart';

/// Phase 13G — the language a voice session speaks: recognition, intent
/// parsing and spoken replies all receive it. Phase 13H adds [malayalam]
/// (Malayalam commands / numbers / replies; product names stay English for
/// the English catalogue). Any other language must be added explicitly —
/// it is never parsed as English.
@immutable
class VoiceLanguage {
  const VoiceLanguage(this.code, this.label);

  /// BCP-47-style code given to speech recognition and TTS.
  final String code;

  /// Shown to the operator ("English").
  final String label;

  static const english = VoiceLanguage('en-US', 'English');
  static const malayalam = VoiceLanguage('ml-IN', 'Malayalam');

  /// The languages with a full implementation. Only these can be selected.
  static const supported = [english, malayalam];

  bool get isSupported => supported.contains(this);

  @override
  bool operator ==(Object other) =>
      other is VoiceLanguage && other.code == code;

  @override
  int get hashCode => code.hashCode;

  @override
  String toString() => 'VoiceLanguage($code)';
}

/// Phase 13G — the app-local voice language setting (no backend, no
/// storage yet). Defaults to English; a language without an
/// implementation can never be selected.
class VoiceSettings extends ChangeNotifier {
  VoiceLanguage _language = VoiceLanguage.english;

  VoiceLanguage get language => _language;

  /// False (and unchanged) for a language that is not implemented.
  bool setLanguage(VoiceLanguage language) {
    if (!language.isSupported) return false;
    if (language == _language) return true;
    _language = language;
    notifyListeners();
    return true;
  }
}
