import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/voice_platform.dart';
import '../data/voice_tts.dart';
import '../models/voice_language.dart';
import 'translation_service.dart';

/// Phase 3B — who is speaking in translation mode.
enum TranslationDirection {
  /// The staff member, translated into the customer's language.
  staffToCustomer,

  /// The customer's reply, translated into the staff member's language.
  customerToStaff,
}

enum TranslationStep {
  idle,
  listening,
  recognized,
  translating,
  translated,
  error,
}

/// Phase 3B — the translation mode's own state. A STRICT boundary: this
/// controller has no cart, sale, payment, order or voice-command parser.
/// Speech captured here only ever becomes text on this screen ("yes",
/// "cancel", "add two", "pay cash" are conversation, never POS commands).
///
/// Privacy: nothing is stored or logged; [clear] (and leaving the screen)
/// drops all text. Recognition runs only between an explicit start and its
/// end — never in the background. A translation is spoken only when asked
/// ([speak]) unless [autoSpeak] was switched on by the staff member.
class TranslationController extends ChangeNotifier {
  TranslationController({
    required this.permission,
    required this.recognizer,
    required this.service,
    this.tts,
    VoiceLanguage staffLanguage = VoiceLanguage.english,
    VoiceLanguage customerLanguage = VoiceLanguage.malayalam,
    this.timeout = const Duration(seconds: 15),
  }) : // Named parameters cannot be private, so no initializing formals.
       // ignore: prefer_initializing_formals
       _staffLanguage = staffLanguage,
       // ignore: prefer_initializing_formals
       _customerLanguage = customerLanguage {
    _supportLoading = refreshSupport();
  }
  final MicrophonePermission permission;
  final SpeechRecognizer recognizer;
  final TranslationService service;
  final VoiceTtsService? tts;
  final Duration timeout;

  /// The languages shown (the central configuration); which of them can be
  /// chosen depends on what translation is switched on ([support]).
  List<VoiceLanguage> get languages => VoiceLanguage.supported;

  // Phase 3B.1 — what the provider / store server switched on.
  TranslationSupport _support = TranslationSupport.none;
  bool _supportLoaded = false;
  Future<void>? _supportLoading;

  TranslationSupport get support => _support;
  bool get supportLoaded => _supportLoaded;

  /// Asks the provider what is switched on, then keeps the chosen languages
  /// valid: the staff language must be an enabled source and the customer
  /// language an enabled target; without any, English / English (workflow
  /// only — translating English into English is refused).
  Future<void> refreshSupport() async {
    TranslationSupport s;
    try {
      s = await service.loadSupport();
    } catch (_) {
      s = TranslationSupport.none;
    }
    if (_disposed) return;
    _support = s;
    _supportLoaded = true;
    if (!canChooseStaff(_staffLanguage)) {
      _staffLanguage = s.sources.isNotEmpty
          ? languages.firstWhere(s.sources.contains)
          : VoiceLanguage.english;
    }
    if (!canChooseCustomer(_customerLanguage)) {
      _customerLanguage = s.targets.isNotEmpty
          ? languages.firstWhere(s.targets.contains)
          : VoiceLanguage.english;
    }
    _notify();
  }

  /// A staff (source) language that may be chosen.
  bool canChooseStaff(VoiceLanguage l) => _support.available
      ? _support.sources.contains(l)
      : l == VoiceLanguage.english;

  /// A customer (target) language that may be chosen.
  bool canChooseCustomer(VoiceLanguage l) => _support.available
      ? _support.targets.contains(l)
      : l == VoiceLanguage.english;

  /// Translating the customer's reply needs the reverse pair switched on.
  bool get canTranslateReplies =>
      _support.allows(_customerLanguage, _staffLanguage);

  VoiceLanguage _staffLanguage;
  VoiceLanguage _customerLanguage;
  TranslationDirection _direction = TranslationDirection.staffToCustomer;
  TranslationStep _step = TranslationStep.idle;
  String _source = '';
  String? _translated;
  String? _error;
  TranslationErrorKind? _errorKind;
  bool _autoSpeak = false;
  bool _speaking = false;
  bool _initialized = false;
  bool _disposed = false;
  int _gen =
      0; // bumps on every new turn / cancel / clear: older answers dropped
  final Set<VoiceLanguage> _noVoice = {};

  VoiceLanguage get staffLanguage => _staffLanguage;
  VoiceLanguage get customerLanguage => _customerLanguage;
  TranslationDirection get direction => _direction;
  TranslationStep get step => _step;

  /// The recognised (or typed / corrected) text of the current turn.
  String get sourceText => _source;

  /// The translation of [sourceText] as it was when translated; null when
  /// there is none (never the source text in its place).
  String? get translatedText => _translated;
  String? get error => _error;
  TranslationErrorKind? get errorKind => _errorKind;
  bool get autoSpeak => _autoSpeak;
  bool get isSpeaking => _speaking;
  bool get isBusy =>
      _step == TranslationStep.listening ||
      _step == TranslationStep.translating;

  /// The language of [sourceText] and the language it is translated into.
  VoiceLanguage get sourceLanguage =>
      _direction == TranslationDirection.staffToCustomer
      ? _staffLanguage
      : _customerLanguage;
  VoiceLanguage get targetLanguage =>
      _direction == TranslationDirection.staffToCustomer
      ? _customerLanguage
      : _staffLanguage;

  bool get providerAvailable =>
      service.providerName != null && _support.available;
  bool get pairSupported => _support.allows(sourceLanguage, targetLanguage);

  /// False once speaking [l] failed on this device.
  bool canSpeak(VoiceLanguage l) => tts != null && !_noVoice.contains(l);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _fail(TranslationErrorKind kind, String message) {
    _step = TranslationStep.error;
    _errorKind = kind;
    _error = message;
    _notify();
  }

  // ---- languages ---------------------------------------------------------

  /// Changing a language cancels a translation in progress (its answer is
  /// dropped) and removes a translation that no longer matches; the source
  /// text the staff member reviewed is kept.
  void setLanguages({VoiceLanguage? staff, VoiceLanguage? customer}) {
    if (_step == TranslationStep.listening) return; // finish listening first
    final s = staff ?? _staffLanguage;
    final c = customer ?? _customerLanguage;
    if (!s.isSupported || !c.isSupported) return;
    // Phase 3B.1: once known, only languages that are switched on.
    if (_supportLoaded && (!canChooseStaff(s) || !canChooseCustomer(c))) {
      return;
    }
    if (s == _staffLanguage && c == _customerLanguage) return;
    _staffLanguage = s;
    _customerLanguage = c;
    _gen++;
    _translated = null;
    _error = null;
    _errorKind = null;
    _step = _source.trim().isEmpty
        ? TranslationStep.idle
        : TranslationStep.recognized;
    _notify();
  }

  void setAutoSpeak(bool on) {
    _autoSpeak = on;
    _notify();
  }

  // ---- recognition -------------------------------------------------------

  /// Starts ONE recognition turn for [direction] (the staff member speaking,
  /// or the customer's reply). Any earlier text of the screen is replaced
  /// only once this turn produces text.
  Future<bool> startListening(TranslationDirection direction) async {
    if (_disposed || isBusy) return false;
    final gen = ++_gen;
    _direction = direction;
    _error = null;
    _errorKind = null;
    _notify();
    var p = await permission.status();
    if (p == VoicePermission.denied) p = await permission.request();
    if (_disposed || gen != _gen) return false;
    if (p != VoicePermission.granted) {
      _fail(
        TranslationErrorKind.unavailable,
        p == VoicePermission.permanentlyDenied
            ? 'Microphone access is turned off for this app. Turn it on in the device settings, or type the text instead.'
            : p == VoicePermission.unsupportedPlatform
            ? 'Voice input is not available here. Type the text instead.'
            : 'Microphone access is needed to listen. You can also type the text.',
      );
      return false;
    }
    try {
      if (!_initialized) {
        _initialized = await recognizer.initialize(
          onError: _onRecognizerError,
          onStatus: _onRecognizerStatus,
        );
      }
      if (!_initialized) {
        _fail(
          TranslationErrorKind.unavailable,
          'Speech recognition is not available on this device. Type the text instead.',
        );
        return false;
      }
      final lang = sourceLanguage;
      final r = recognizer;
      if (r is LocaleAwareRecognizer &&
          await (r as LocaleAwareRecognizer).supportsLanguage(lang) == false) {
        _fail(
          TranslationErrorKind.unavailable,
          '${lang.label} speech recognition is not available on this device. Type the text instead.',
        );
        return false;
      }
      if (_disposed || gen != _gen) return false;
      _source = '';
      _translated = null;
      _step = TranslationStep.listening;
      _notify();
      await recognizer.listen(
        onResult: (t, f) => _onResult(gen, t, f),
        language: lang,
      );
      return true;
    } catch (_) {
      _fail(
        TranslationErrorKind.unavailable,
        'Listening could not start. Try again, or type the text.',
      );
      return false;
    }
  }

  void _onResult(int gen, String text, bool isFinal) {
    if (_disposed || gen != _gen || _step != TranslationStep.listening) return;
    _source = text.trim();
    if (isFinal) _endListening();
    _notify();
  }

  void _endListening() {
    if (_source.isEmpty) {
      _fail(
        TranslationErrorKind.emptyText,
        'Nothing was heard. Try again, or type the text.',
      );
    } else {
      _step = TranslationStep.recognized;
    }
  }

  void _onRecognizerStatus(String status) {
    if (_step == TranslationStep.listening &&
        (status == 'done' || status == 'notListening')) {
      _endListening();
      _notify();
    }
  }

  void _onRecognizerError(String error) {
    if (_step != TranslationStep.listening) return;
    _fail(
      TranslationErrorKind.unavailable,
      error.contains('no_match') || error.contains('speech_timeout')
          ? 'Nothing was heard. Try again, or type the text.'
          : 'Speech recognition failed. Try again, or type the text.',
    );
  }

  /// Ends listening; the text heard so far is kept for review.
  Future<void> stop() async {
    if (_step != TranslationStep.listening) return;
    try {
      await recognizer.stop();
    } catch (_) {}
    if (_step == TranslationStep.listening) {
      _endListening();
      _notify();
    }
  }

  /// Cancels listening (the partial text is dropped) or a translation in
  /// progress (its answer is dropped; the source text stays).
  Future<void> cancel() async {
    if (_step == TranslationStep.listening) {
      _gen++;
      try {
        await recognizer.cancel();
      } catch (_) {}
      _source = '';
      _step = TranslationStep.idle;
    } else if (_step == TranslationStep.translating) {
      _gen++;
      _step = TranslationStep.recognized;
    }
    _notify();
  }

  // ---- review and translate ---------------------------------------------

  /// The staff member corrects the text (or types it). The old translation
  /// no longer matches, so it is removed — never silently kept.
  void setSourceText(String text) {
    if (_step == TranslationStep.listening) return;
    if (_step == TranslationStep.translating) _gen++;
    _source = text;
    _translated = null;
    _error = null;
    _errorKind = null;
    _step = text.trim().isEmpty
        ? TranslationStep.idle
        : TranslationStep.recognized;
    _notify();
  }

  /// Translates [sourceText] (only when asked). On any failure the source
  /// stays for review and retry, and no translation is shown.
  Future<void> translate() async {
    if (_disposed || isBusy) return;
    if (!_supportLoaded) {
      // Phase 3B.1: never decide before knowing what is switched on.
      await (_supportLoading ??= refreshSupport());
      if (_disposed || isBusy) return;
    }
    final request = TranslationRequest(
      source: sourceLanguage,
      target: targetLanguage,
      text: _source.trim(),
    );
    final problem = request.problem;
    if (problem != null) {
      return _fail(problem, _message(problem));
    }
    if (!providerAvailable) {
      return _fail(
        TranslationErrorKind.unavailable,
        'Translation is not set up yet: the translation provider has to be approved and configured on the store server first.',
      );
    }
    if (!pairSupported) {
      return _fail(
        TranslationErrorKind.unsupportedPair,
        'Translation from ${request.source.label} to ${request.target.label} is not available.',
      );
    }
    final gen = ++_gen;
    _translated = null;
    _error = null;
    _errorKind = null;
    _step = TranslationStep.translating;
    _notify();
    TranslationResult result;
    try {
      result = await service.translate(request).timeout(timeout);
    } on TimeoutException {
      result = const TranslationResult.failed(TranslationErrorKind.timeout);
    } catch (_) {
      result = const TranslationResult.failed(TranslationErrorKind.network);
    }
    if (_disposed || gen != _gen) return; // cancelled / replaced: dropped
    final text = result.text?.trim();
    if (result.isTranslated && (text == null || text.isEmpty)) {
      result = const TranslationResult.failed(TranslationErrorKind.malformed);
    }
    if (!result.isTranslated) {
      return _fail(result.error!, _message(result.error!));
    }
    _translated = text;
    _step = TranslationStep.translated;
    _notify();
    if (_autoSpeak) unawaited(speak());
  }

  static String _message(TranslationErrorKind k) => switch (k) {
    TranslationErrorKind.timeout =>
      'Translation took too long. Check the connection and try again.',
    TranslationErrorKind.network =>
      'Translation could not be reached. Check the connection and try again.',
    TranslationErrorKind.malformed =>
      'The translation could not be read. Try again.',
    TranslationErrorKind.unsupportedPair =>
      'These two languages cannot be translated.',
    TranslationErrorKind.unavailable => 'Translation is not set up on the store server yet, or is unavailable right now.',
    TranslationErrorKind.cancelled => 'Translation was cancelled.',
    TranslationErrorKind.emptyText => 'There is nothing to translate yet.',
    TranslationErrorKind.sameLanguage => 'Choose two different languages.',
    TranslationErrorKind.tooLong =>
      'The text is too long to translate (at most ${TranslationRequest.maxChars} characters). Shorten it and try again.',
    TranslationErrorKind.permissionDenied =>
      'Translation is not permitted for this sign-in or on this server.',
    TranslationErrorKind.rateLimited =>
      'Too many translations right now. Wait a moment and try again.',
    TranslationErrorKind.upstream =>
      'The translation service failed. Try again.',
  };

  // ---- playback ----------------------------------------------------------

  /// Speaks the translation in the target language (only when asked, or
  /// with [autoSpeak]). Without a voice for it the text stays on screen.
  Future<void> speak() async {
    final t = tts;
    final text = _translated;
    final lang = targetLanguage;
    if (t == null || text == null || _disposed) return;
    _speaking = true;
    _notify();
    try {
      await t.speak(text, language: lang);
      _noVoice.remove(lang);
    } catch (_) {
      _noVoice.add(lang);
    } finally {
      _speaking = false;
      _notify();
    }
  }

  // ---- clear -------------------------------------------------------------

  /// Drops all text of the conversation (nothing was stored anywhere).
  Future<void> clear() async {
    if (_step == TranslationStep.listening) {
      try {
        await recognizer.cancel();
      } catch (_) {}
    }
    _gen++;
    _source = '';
    _translated = null;
    _error = null;
    _errorKind = null;
    _step = TranslationStep.idle;
    _notify();
    final t = tts;
    if (t != null) {
      unawaited(Future<void>.sync(t.stop).catchError((Object _) {}));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _gen++;
    if (_step == TranslationStep.listening) {
      Future<void>.sync(recognizer.cancel).catchError((Object _) {});
    }
    final t = tts;
    if (t != null) Future<void>.sync(t.stop).catchError((Object _) {});
    _source = '';
    _translated = null;
    super.dispose();
  }
}
