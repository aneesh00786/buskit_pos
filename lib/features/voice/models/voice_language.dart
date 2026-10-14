import 'package:flutter/foundation.dart';

/// Phase 3A — what a voice language supports in this app. Parser grammar,
/// spoken replies and screen wording exist per language; the DEVICE's
/// speech engines are checked separately at run time (see
/// LocaleAwareRecognizer / the TTS service) — a capability here never claims
/// that a device can hear or speak the language.
enum VoiceCapability {
  quickBill,
  corrections,
  orders,
  tables,

  /// Spoken yes / no / cancel.
  replies,

  /// Jacky's replies written for this language (screen and speech).
  responses,
}

/// Phase 13G — the language a voice session speaks: recognition, intent
/// parsing and spoken replies all receive it. Phase 13H adds [malayalam]
/// (Malayalam commands / numbers / replies; product names stay English for
/// the English catalogue). Any other language must be added explicitly —
/// it is never parsed as English.
///
/// Phase 3A: the central language configuration. Adding a language means a
/// new entry here (locales + capabilities), its grammar in the parser, its
/// wording in VoiceResponses, and tests — not changes to billing logic.
@immutable
class VoiceLanguage {
  const VoiceLanguage(
    this.code,
    this.label, {
    this.nativeLabel,
    String? speechLocale,
    String? ttsLocale,
    this.capabilities = const {},
  }) : // Named parameters cannot be private, so no initializing formals.
       // ignore: prefer_initializing_formals
       _speechLocale = speechLocale,
       // ignore: prefer_initializing_formals
       _ttsLocale = ttsLocale;

  /// BCP-47-style code (identity of the language in this app).
  final String code;

  /// Shown to the operator ("English").
  final String label;

  /// The language's own name ("മലയാളം"), shown next to [label].
  final String? nativeLabel;

  final String? _speechLocale;
  final String? _ttsLocale;

  /// The locale asked of the device's speech recognizer.
  String get speechLocale => _speechLocale ?? code;

  /// The locale asked of the device's text-to-speech engine.
  String get ttsLocale => _ttsLocale ?? code;

  /// What this app implements for the language.
  final Set<VoiceCapability> capabilities;

  bool can(VoiceCapability c) => capabilities.contains(c);

  /// "Malayalam (മലയാളം)" / "English".
  String get displayName => nativeLabel == null || nativeLabel == label
      ? label
      : '$label ($nativeLabel)';

  static const _all = {
    VoiceCapability.quickBill,
    VoiceCapability.corrections,
    VoiceCapability.orders,
    VoiceCapability.tables,
    VoiceCapability.replies,
    VoiceCapability.responses,
  };

  static const english = VoiceLanguage(
    'en-US',
    'English',
    speechLocale: 'en-US',
    ttsLocale: 'en-US',
    capabilities: _all,
  );
  static const malayalam = VoiceLanguage(
    'ml-IN',
    'Malayalam',
    nativeLabel: 'മലയാളം',
    speechLocale: 'ml-IN',
    ttsLocale: 'ml-IN',
    capabilities: _all,
  );

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
///
/// Phase 3A: a choice is kept PER STAFF MEMBER ([staff] = company + staff
/// id) on this device, so one cashier's language never carries over to the
/// next cashier who signs in; without a staff key it is the device default
/// (what every staff member starts with). In memory only (an app restart
/// returns to English).
class VoiceSettings extends ChangeNotifier {
  VoiceLanguage _language = VoiceLanguage.english;
  final Map<String, VoiceLanguage> _byStaff = {};

  /// The device default.
  VoiceLanguage get language => _language;

  /// [staff]'s choice, or the device default.
  VoiceLanguage languageFor(String? staff) =>
      (staff == null ? null : _byStaff[staff]) ?? language;

  /// False (and unchanged) for a language that is not implemented.
  bool setLanguage(VoiceLanguage language, {String? staff}) {
    if (!language.isSupported) return false;
    if (staff == null) {
      if (language == _language) return true;
      _language = language;
    } else {
      if (_byStaff[staff] == language) return true;
      _byStaff[staff] = language;
    }
    notifyListeners();
    return true;
  }
}
