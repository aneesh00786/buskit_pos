import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/utils/quantity.dart';
import '../../auth/models/pos_token_scope.dart';
import '../../cart/state/cart_controller.dart';
import '../data/voice_platform.dart';
import '../data/voice_preview_service.dart';
import '../data/voice_tts.dart';
import '../models/voice_language.dart';
import '../intent/voice_intent.dart';
import '../intent/voice_intent_parser.dart';
import '../models/quick_bill_preview.dart';
import '../models/voice_session.dart';
import 'voice_responses.dart';

/// Phase 13A — where the voice flow is.
enum VoiceState {
  idle,
  requestingPermission,
  listening,
  processing,
  recognized,
  error,
}

/// Phase 13C-B — where the backend quick-bill preview is.
enum VoicePreviewState { none, loading, loaded, failed }

/// Phase 13C-C — Confirm Bill: the confirmed lines being put into the
/// normal POS cart ([adding]) or put there ([added], go to checkout).
enum VoiceBillState { none, adding, added }

/// Phase 13A — the voice foundation: microphone permission (asked on first
/// use), listening, speech-to-text, and the session / request ids. It ends
/// at RECOGNIZED TEXT: nothing is interpreted and nothing is sent to the
/// POS backend; no sale, payment, stock or other POS state is touched
/// (Phase 13B adds intent handling).
///
/// One controller per screen; a voice session is per signed-in staff member
/// and device ([scope] is read from the existing POS session each time a
/// request starts — when it changes, a new session begins).
class VoiceController extends ChangeNotifier {
  VoiceController({
    required this.permission,
    required this.recognizer,
    required this.scope,
    this.intentParser = const RuleBasedIntentParser(),
    this.previewService,
    this.cart,
    this.correctionParser = const RuleBasedCorrectionParser(),
    this.tts,
    this.settings,
  });

  /// Phase 13G: the app-local voice language setting (null = English).
  final VoiceSettings? settings;

  /// The language a NEW voice session starts in.
  VoiceLanguage get language => settings?.language ?? VoiceLanguage.english;

  /// Phase 13H: selects the language for the NEXT voice bill. An existing
  /// session keeps its own language. False for a language without an
  /// implementation (or with no settings attached).
  bool selectLanguage(VoiceLanguage l) {
    final s = settings;
    if (s == null || !s.setLanguage(l)) return false;
    notifyListeners();
    return true;
  }

  /// The current session's language (recognition, parsing, replies).
  VoiceLanguage get sessionLanguage => _session?.language ?? language;

  /// Phase 13F: Jacky's spoken replies (operator Quick Bill only; null =
  /// silent). Presentation only — never decides or changes anything.
  final VoiceTtsService? tts;

  /// Phase 13E: spoken corrections of the Quick Bill on screen.
  final RuleBasedCorrectionParser correctionParser;

  /// Phase 13C-C: the normal POS cart a confirmed bill is added to (through
  /// its existing add-item path). Null: Confirm Bill cannot continue.
  final CartController? cart;

  /// Phase 13C-B: backend preview of a CREATE_QUICK_BILL intent (resolved
  /// products, server prices and tax). Null: no preview (intent only).
  final VoicePreviewService? previewService;

  /// Phase 13B: recognized text -> structured intent (replaceable).
  final VoiceIntentParser intentParser;

  final MicrophonePermission permission;
  final SpeechRecognizer recognizer;

  /// The signed-in POS scope (company / store / register / device / staff)
  /// from the existing session; null when nobody is signed in.
  final PosTokenScope? Function() scope;

  VoiceState _state = VoiceState.idle;
  VoiceSession? _session;
  VoiceRequest? _request;
  VoiceIntent? _intent;
  VoicePermission? _permission;
  String? _error;
  bool _initialized = false;
  bool _busy = false; // a start / stop / cancel is in progress
  bool _disposed = false;
  VoicePreviewState _previewState = VoicePreviewState.none;
  QuickBillPreview? _preview;
  String? _previewError;
  bool _previewRetryable = false;
  VoiceBillState _billState = VoiceBillState.none;

  /// Phase 13D: the lines currently being previewed (as first spoken, then
  /// as corrected). Each correction replaces it with a NEW request.
  QuickBillRequest? _billRequest;

  /// Phase 13E: while listening for / interpreting a spoken correction, the
  /// bill being corrected (it stays on screen, unchanged, until the
  /// correction is understood) and the request its preview belongs to.
  ({QuickBillRequest bill, QuickBillPreview preview, VoiceRequest request})?
  _correctionBase;
  String? _correctionQuestion;
  bool _speaking = false;
  int _sayGen = 0; // bumps on every say / stop: an older reply's end is ignored
  String? _billError;

  VoiceState get state => _state;
  VoiceSession? get session => _session;
  VoiceRequest? get request => _request;

  /// Phase 13B: what the recognized text means (preview only — nothing is
  /// billed). Null until the current request's text has been interpreted.
  VoiceIntent? get intent => _intent;

  /// Phase 13C-B: the backend preview of the current request's quick bill.
  VoicePreviewState get previewState => _previewState;
  QuickBillPreview? get preview => _preview;

  /// A safe, cashier-facing reason the preview failed.
  String? get previewError => _previewError;

  /// Network / timeout / server failures: "Retry" re-sends the same request
  /// (same voice session and request ids).
  bool get previewRetryable => _previewRetryable;

  /// Phase 13C-C: where Confirm Bill is (adding to the cart / added).
  VoiceBillState get billState => _billState;

  /// Why Confirm Bill could not continue (a safe, cashier-facing message).
  String? get billError => _billError;

  static const staleBillMessage =
      'This bill is no longer current. Please check it again.';
  static const noCartMessage =
      'Open Voice bill from the cart to continue to checkout.';
  static const offlineMessage =
      'Voice billing needs a connection to the server.';
  static const busyCartMessage =
      'Finish, hold or clear the current sale before billing by voice.';
  VoicePermission? get lastPermission => _permission;
  String? get error => _error;
  String get text => _request?.text ?? '';
  bool get isListening => _state == VoiceState.listening;

  /// Permission is refused for good: only the device settings can fix it.
  bool get needsSettings => _permission == VoicePermission.permanentlyDenied;

  void _set(VoiceState s, {String? error}) {
    if (_disposed) return;
    // A spoken correction that failed (nothing heard, recognizer error)
    // leaves the bill exactly as it was.
    if (s == VoiceState.error && _correctionBase != null) _restoreBill();
    _state = s;
    _error = error;
    notifyListeners();
  }

  /// Starts a fresh voice session (new voiceSessionId) for the current
  /// signed-in scope. Any request in progress is cancelled first.
  Future<void> newSession() async {
    if (_state == VoiceState.listening) await cancel();
    _stopSpeaking(); // Phase 15B: no reply from the old session carries over
    _session = VoiceSession.start(scope(), language: language);
    _request = null;
    _intent = null;
    _billRequest = null;
    _clearPreview();
    _set(VoiceState.idle);
  }

  /// Asks for the microphone (first use only), then listens for one request
  /// (new requestId). Returns false when it did not start — already busy
  /// or listening (duplicate start), permission refused, or the recognizer
  /// is unavailable ([error] says why).
  Future<bool> start() => _start();

  Future<bool> _start({bool keepBill = false}) async {
    if (_busy ||
        _disposed ||
        _state == VoiceState.listening ||
        _state == VoiceState.processing) {
      return false;
    }
    _busy = true;
    _stopSpeaking(); // a new listening operation (bill or correction)
    try {
      // Phase 13G: a correction keeps its session's language; a new bill
      // uses the selected one. A language without an implementation is
      // refused before the microphone opens (no bill, no cart change).
      final lang = keepBill ? sessionLanguage : language;
      if (!lang.isSupported) {
        _set(
          VoiceState.error,
          error: 'Voice is not available in ${lang.label} yet.',
        );
        return false;
      }
      // Permission — asked here, when voice is used, never at app start.
      var p = await permission.status();
      if (p == VoicePermission.denied) {
        _set(VoiceState.requestingPermission);
        p = await permission.request();
      }
      _permission = p;
      if (p != VoicePermission.granted) {
        _set(VoiceState.error, error: _permissionMessage(p));
        return false;
      }

      if (!_initialized) {
        _initialized = await recognizer.initialize(
          onError: _onRecognizerError,
          onStatus: _onRecognizerStatus,
        );
        if (!_initialized) {
          _set(
            VoiceState.error,
            error: 'Speech recognition is not available on this device.',
          );
          return false;
        }
      }

      // Session isolation: a different staff member / device / company never
      // continues someone else's session.
      final current = scope();
      if (_session == null ||
          !_session!.belongsTo(current) ||
          (!keepBill && _session!.language != lang)) {
        _session = VoiceSession.start(current, language: lang);
      }
      _request = VoiceRequest.start(_session!);
      if (!keepBill) {
        _intent = null;
        _billRequest = null;
        _clearPreview();
      }
      _set(VoiceState.listening);
      await recognizer.listen(
        onResult: _onResult,
        language: _session!.language,
      );
      return true;
    } catch (_) {
      _set(VoiceState.error, error: 'Voice could not start. Try again.');
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Stops listening; the recognized text follows ([VoiceState.processing]
  /// until it arrives). Ignored unless listening (duplicate stop).
  Future<void> stop() async {
    if (_busy || _state != VoiceState.listening) return;
    _busy = true;
    try {
      _set(VoiceState.processing);
      await recognizer.stop();
    } catch (_) {
      _set(VoiceState.error, error: 'Voice could not stop cleanly.');
    } finally {
      _busy = false;
    }
  }

  /// Stops listening and discards whatever was heard.
  Future<void> cancel() async {
    _stopSpeaking();
    if (_state != VoiceState.listening && _state != VoiceState.processing) {
      return;
    }
    _busy = true;
    try {
      await recognizer.cancel();
    } catch (_) {
      // Released either way.
    } finally {
      _busy = false;
      if (_correctionBase != null) {
        // Cancelling a spoken correction keeps the bill as it was.
        _restoreBill();
        _set(VoiceState.recognized);
      } else {
        _request = null;
        _intent = null;
        _billRequest = null;
        _clearPreview();
        _set(VoiceState.idle);
      }
    }
  }

  /// Opens the device settings (when permission was refused for good).
  Future<bool> openSettings() => permission.openSettings();

  void _onResult(String text, bool isFinal) {
    final r = _request;
    if (_disposed || r == null) return;
    if (_state != VoiceState.listening && _state != VoiceState.processing) {
      return; // cancelled / finished: late results are ignored
    }
    r.text = text.trim();
    if (isFinal) {
      if (r.text.isEmpty) {
        _set(VoiceState.error, error: 'Nothing was heard. Try again.');
      } else {
        r.recognizedAt = DateTime.now();
        _set(VoiceState.recognized);
        _interpret(r);
      }
    } else if (!_disposed) {
      notifyListeners();
    }
  }

  /// Phase 13B: interpret the recognized text of [r]. The result is kept
  /// only while [r] is still the current request; a parser failure becomes
  /// UNKNOWN (never an exception, never a POS action).
  Future<void> _interpret(VoiceRequest r) async {
    if (_correctionBase != null) return _interpretCorrection(r);
    VoiceIntent result;
    try {
      result = await intentParser.parse(
        r.text,
        voiceSessionId: r.voiceSessionId,
        requestId: r.requestId,
        language: sessionLanguage,
      );
    } catch (_) {
      result = VoiceIntent(
        type: VoiceIntentType.unknown,
        voiceSessionId: r.voiceSessionId,
        requestId: r.requestId,
        recognizedText: r.text,
      );
    }
    if (_disposed || !identical(_request, r)) return;
    _intent = result;
    notifyListeners();
    if (result.type == VoiceIntentType.createQuickBill &&
        previewService != null) {
      final req = _billRequest = QuickBillRequest.fromIntent(result);
      await _loadPreview(r, req);
    }
  }

  // --- Phase 13C-B: backend preview + verification --------------------

  void _clearPreview() {
    _previewState = VoicePreviewState.none;
    _preview = null;
    _previewError = null;
    _previewRetryable = false;
    _billState = VoiceBillState.none;
    _billError = null;
    _correctionQuestion = null;
  }

  /// Sends [req] (what was said + the voice ids only) for a server-side
  /// preview. The answer is kept only while [r] / [req] are still the current
  /// request (a newer correction or a cancel discards it) and it carries this
  /// request's voice session and request ids.
  Future<void> _loadPreview(VoiceRequest r, QuickBillRequest req) async {
    _clearPreview();
    _previewState = VoicePreviewState.loading;
    notifyListeners();
    QuickBillPreview? result;
    String? error;
    var retryable = false;
    var foreign = false;
    try {
      result = await previewService!.previewQuickBill(req);
      if (result.voiceSessionId != req.voiceSessionId ||
          result.requestId != req.requestId) {
        // Phase 15A: an answer carrying another session's / request's ids
        // is discarded — never shown, never confirmable, never spoken.
        // Retry sends a NEW request id.
        result = null;
        foreign = true;
        retryable = true;
        error = 'The bill preview did not match this request. Speak again.';
      }
    } on ApiException catch (e) {
      error = _previewMessage(e);
      retryable = e.isRetryable;
    } catch (_) {
      error = 'The bill preview could not be loaded. Please try again.';
      retryable = true;
    }
    if (_disposed || !identical(_request, r) || !identical(_billRequest, req)) {
      return; // a newer request (or cancel) took over: drop this answer
    }
    _preview = result;
    _previewError = error;
    _previewRetryable = retryable;
    _previewState = result == null
        ? VoicePreviewState.failed
        : VoicePreviewState.loaded;
    notifyListeners();
    if (foreign) return;
    final say = _responses;
    if (say != null) _say(say.preview(result)); // CURRENT request only
  }

  /// 401 / 403 keep the app's existing handling (the API client already
  /// reports a 401 to the session; the permission wording is shared).
  static String _previewMessage(ApiException e) => switch (e.kind) {
    ApiErrorKind.network || ApiErrorKind.timeout => 'Could not reach the server to check this bill. Check the connection and tap Retry.',
    ApiErrorKind.validation =>
      'This request could not be checked: ${e.message}',
    _ => describeApiError(e),
  };

  /// Re-sends the same lines after a failed preview — Phase 15A: as a NEW
  /// request (same voice session, new request id), so an answer to the
  /// failed attempt can never be taken for the retry's.
  Future<void> retryPreview() async {
    final previous = _request;
    final old = _billRequest;
    final s = _session;
    if (_disposed ||
        previous == null ||
        old == null ||
        s == null ||
        previewService == null ||
        _previewState != VoicePreviewState.failed ||
        !_previewRetryable) {
      return;
    }
    if (!s.belongsTo(scope())) {
      _billRequest = null;
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = staleBillMessage;
      notifyListeners();
      return;
    }
    final r = _request = VoiceRequest.start(s)
      ..text = previous.text
      ..recognizedAt = previous.recognizedAt;
    final req = _billRequest = QuickBillRequest(
      voiceSessionId: s.voiceSessionId,
      requestId: r.requestId,
      recognizedText: old.recognizedText,
      items: old.items,
    );
    await _loadPreview(r, req);
  }

  // --- Phase 13D: correction -> a NEW server preview --------------------

  static const allRemovedMessage =
      'All items were removed. Speak again to start a new bill.';

  /// Corrections are possible while a preview exists and nothing is being
  /// added to the cart.
  bool get canCorrect =>
      previewService != null &&
      _billRequest != null &&
      _correctionBase == null &&
      _billState == VoiceBillState.none;

  /// Sets line [itemIndex] (the server's `item_index`) to [quantity] and asks
  /// for a new preview. Returns a message (nothing sent) when the quantity
  /// breaks the existing PIECE / WEIGHT rules; the server re-checks anyway.
  Future<String?> changeQuantity(int itemIndex, num quantity) async {
    final problem = await _setQuantity(itemIndex, quantity);
    if (problem != null) {
      _billError = problem;
      notifyListeners();
    }
    return problem;
  }

  Future<String?> _setQuantity(
    int itemIndex,
    num quantity, {
    String? unit,
  }) async {
    final req = _billRequest;
    if (!canCorrect ||
        req == null ||
        itemIndex < 0 ||
        itemIndex >= req.items.length) {
      return null;
    }
    final mode =
        _preview?.items
            .where((l) => l.itemIndex == itemIndex)
            .firstOrNull
            ?.sellingMode ??
        'PIECE';
    final problem = quantityError(mode, quantity);
    if (problem != null) return problem;
    final items = [...req.items];
    items[itemIndex] = items[itemIndex].withQuantity(
      quantityFromMilli(quantityMilliOf(quantity)!),
      unit: unit,
    );
    await _correct(items);
    return null;
  }

  /// Removes line [itemIndex] and asks for a new preview; removing the last
  /// line leaves nothing to confirm.
  Future<void> removeLine(int itemIndex) async {
    final req = _billRequest;
    if (!canCorrect ||
        req == null ||
        itemIndex < 0 ||
        itemIndex >= req.items.length) {
      return;
    }
    await _correct([...req.items]..removeAt(itemIndex));
  }

  /// The cashier explicitly chose [candidate] for the unclear line
  /// [itemIndex]. Only a candidate the CURRENT preview offered for that line
  /// can be chosen; the server re-validates it (company, active, sellable,
  /// quantity, price, tax). Never called automatically.
  Future<void> chooseCandidate(
    int itemIndex,
    QuickBillCandidate candidate,
  ) async {
    final req = _billRequest;
    final id = candidate.productVariationId;
    final offered =
        _preview?.issues.any(
          (i) =>
              i.itemIndex == itemIndex &&
              i.candidates.any((c) => identical(c, candidate)),
        ) ??
        false;
    if (!canCorrect ||
        req == null ||
        id == null ||
        !offered ||
        itemIndex < 0 ||
        itemIndex >= req.items.length) {
      return;
    }
    final items = [...req.items];
    items[itemIndex] = items[itemIndex].withSelection(id);
    await _correct(items);
  }

  // --- Phase 13E: spoken corrections -----------------------------------

  /// Listening for / interpreting a spoken correction of the bill on screen.
  bool get isCorrecting => _correctionBase != null;

  /// Why the last spoken correction was not applied (the bill is unchanged).
  String? get correctionQuestion => _correctionQuestion;

  // --- Phase 13F: spoken replies -----------------------------------------

  /// Jacky is speaking a reply.
  bool get isSpeaking => _speaking;

  /// Speaks [text] (replacing anything still being spoken). A TTS failure
  /// only means it was not spoken: the bill and the screen are unaffected.
  void _say(String text) {
    final t = tts;
    if (t == null || _disposed) return;
    final gen = ++_sayGen;
    _speaking = true;
    notifyListeners();
    final lang = sessionLanguage;
    Future<void>.sync(() => t.speak(text, language: lang))
        .catchError((Object _) {})
        .whenComplete(() {
          if (_disposed || gen != _sayGen) return;
          _speaking = false;
          notifyListeners();
        });
  }

  void _stopSpeaking() {
    final t = tts;
    if (t == null) return;
    _sayGen++;
    final was = _speaking;
    _speaking = false;
    Future<void>.sync(t.stop).catchError((Object _) {});
    if (was && !_disposed) notifyListeners();
  }

  /// The spoken wording for this session's language (null: none).
  VoiceResponses? get _responses =>
      VoiceResponses.forLanguage(_session?.language ?? language);

  /// Phase 13H: on-screen correction questions in the session's language.
  VoiceResponses get _screen => _responses ?? const EnglishVoiceResponses();

  void _restoreBill() {
    final b = _correctionBase!;
    _correctionBase = null;
    _request = b.request; // the bill's own request: unchanged, confirmable
  }

  /// "Speak correction": listens for one correction ("make it three",
  /// "remove the water", "add one more coffee") while the current preview
  /// stays on screen. Confirm Bill is refused until it is handled.
  Future<bool> startCorrection() async {
    final bill = _billRequest;
    final p = _preview;
    final r = _request;
    if (!canCorrect ||
        bill == null ||
        p == null ||
        r == null ||
        _previewState != VoicePreviewState.loaded) {
      return false;
    }
    _correctionBase = (bill: bill, preview: p, request: r);
    _correctionQuestion = null;
    _billError = null;
    final ok = await _start(keepBill: true);
    if (!ok && _correctionBase != null) {
      _restoreBill();
      notifyListeners();
    }
    return ok;
  }

  Future<void> _interpretCorrection(VoiceRequest r) async {
    final base = _correctionBase!;
    _correctionBase = null;
    if (_disposed || !identical(_request, r)) return;
    final s = _session;
    if (s == null ||
        s.voiceSessionId != base.request.voiceSessionId ||
        !identical(_billRequest, base.bill)) {
      // Someone else signed in while listening: their session never
      // continues this bill.
      _billRequest = null;
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = staleBillMessage;
      notifyListeners();
      return;
    }
    // Not applied: the bill, its preview and its request stay as they were.
    void ask(String question, {String? spoken}) {
      _request = base.request;
      _correctionQuestion = question;
      notifyListeners();
      final say = _responses;
      if (say != null) _say(spoken ?? say.question(question));
    }

    VoiceCorrection? c;
    try {
      c = correctionParser.parse(r.text, language: s.language);
    } catch (_) {
      c = null;
    }
    if (c == null) {
      return ask(_screen.notACorrection());
    }
    final bill = base.bill;
    final preview = base.preview;
    switch (c.kind) {
      case VoiceCorrectionKind.unclear:
        return ask(c.question ?? RuleBasedCorrectionParser.exampleHint);
      case VoiceCorrectionKind.setQuantity:
        final i = _targetLine(c.target, bill, preview, ask);
        if (i == null) return;
        final problem = await _setQuantity(i, c.quantity!, unit: c.unit);
        if (problem != null) ask(problem);
      case VoiceCorrectionKind.remove:
        final i = _targetLine(c.target, bill, preview, ask);
        if (i == null) return;
        await removeLine(i);
      case VoiceCorrectionKind.add:
        final items = [...bill.items];
        for (final add in c.items) {
          final said = [add.variantQuery, add.productQuery].nonNulls.join(' ');
          final same = _linesMatching(said, bill, preview);
          if (same.length > 1) {
            return ask(
              _screen.whichNamedScreen(said, _labels(same, bill, preview)),
              spoken: _responses?.whichNamed(
                said,
                _spokenLabels(same, bill, preview),
              ),
            );
          }
          if (same.isEmpty) {
            items.add(QuickBillRequestItem.fromIntent(add));
            continue;
          }
          // "add one more coffee": more of the line already on the bill.
          final j = same.single;
          final current = items[j];
          if (add.unit != null && add.unit != current.unit) {
            return ask('Say the extra $said in ${current.unit ?? 'pieces'}.');
          }
          final total = quantityFromMilli(
            quantityMilliOf(current.quantity)! + quantityMilliOf(add.quantity)!,
          );
          final mode =
              preview.items
                  .where((l) => l.itemIndex == j)
                  .firstOrNull
                  ?.sellingMode ??
              'PIECE';
          final problem = quantityError(mode, total);
          if (problem != null) return ask(problem);
          items[j] = current.withQuantity(total);
        }
        await _correct(items);
    }
  }

  /// The ONE bill line a spoken correction means, or null after asking.
  /// "it" / "that" only when the bill has exactly one line; a name must
  /// match exactly one line. Never a guess.
  int? _targetLine(
    String? target,
    QuickBillRequest bill,
    QuickBillPreview preview,
    void Function(String, {String? spoken}) ask,
  ) {
    final all = [for (var i = 0; i < bill.items.length; i++) i];
    if (target == null) {
      if (bill.items.length == 1) return 0;
      ask(
        _screen.whichItemScreen(_labels(all, bill, preview)),
        spoken: _responses?.whichItem(_spokenLabels(all, bill, preview)),
      );
      return null;
    }
    final hits = _linesMatching(target, bill, preview);
    if (hits.length == 1) return hits.single;
    ask(
      hits.isEmpty
          ? _screen.noSuchLineScreen(target, _labels(all, bill, preview))
          : _screen.whichNamedScreen(target, _labels(hits, bill, preview)),
      spoken: hits.isEmpty
          ? _responses?.noSuchLine(target)
          : _responses?.whichNamed(target, _spokenLabels(hits, bill, preview)),
    );
    return null;
  }

  /// Lines whose spoken query or server-resolved name contains every word
  /// the cashier said ("coffee", "large coffee", "water").
  List<int> _linesMatching(
    String said,
    QuickBillRequest bill,
    QuickBillPreview preview,
  ) {
    final want = RuleBasedCorrectionParser.matchWords(said);
    if (want.isEmpty) return const [];
    return [
      for (var i = 0; i < bill.items.length; i++)
        if (want.every(
          RuleBasedCorrectionParser.matchWords(
            [
              bill.items[i].variantQuery,
              bill.items[i].productQuery,
              _lineAt(preview, i)?.productName,
              _lineAt(preview, i)?.variantName,
            ].nonNulls.join(' '),
          ).toSet().contains,
        ))
          i,
    ];
  }

  /// Line names for speaking: "Coffee Regular", or what was said.
  static List<String> _spokenLabels(
    List<int> lines,
    QuickBillRequest bill,
    QuickBillPreview preview,
  ) => [
    for (final i in lines)
      switch (_lineAt(preview, i)) {
        final l? => [l.productName, l.variantName].nonNulls.join(' '),
        null => bill.items[i].productQuery,
      },
  ];

  static QuickBillLine? _lineAt(QuickBillPreview p, int i) =>
      p.items.where((l) => l.itemIndex == i).firstOrNull;

  static String _labels(
    List<int> lines,
    QuickBillRequest bill,
    QuickBillPreview preview,
  ) => [
    for (final i in lines)
      switch (_lineAt(preview, i)) {
        final l? when l.variantName != null =>
          '${l.productName} (${l.variantName})',
        final l? => l.productName,
        null => '"${bill.items[i].productQuery}"',
      },
  ].join(', ');

  /// A correction is a NEW request in the SAME voice session: the old
  /// preview is cleared at once (never confirmable) and only the newest
  /// request's answer may update the screen.
  Future<void> _correct(List<QuickBillRequestItem> items) async {
    final s = _session;
    final old = _billRequest;
    final previous = _request;
    if (_disposed || s == null || old == null || previous == null) return;
    if (!s.belongsTo(scope())) {
      _billRequest = null;
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = staleBillMessage;
      notifyListeners();
      return;
    }
    final r = VoiceRequest.start(s)
      ..text = previous.text
      ..recognizedAt = previous.recognizedAt;
    _request = r;
    if (items.isEmpty) {
      _billRequest = null;
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = _screen.allRemoved();
      notifyListeners();
      if (_responses != null) _say(_screen.allRemoved());
      return;
    }
    final say = _responses;
    if (say != null) _say(say.checking());
    final req = _billRequest = QuickBillRequest(
      voiceSessionId: s.voiceSessionId,
      requestId: r.requestId,
      recognizedText: old.recognizedText,
      items: items,
    );
    await _loadPreview(r, req);
  }

  /// "Confirm Bill": the cashier confirmed the interpreted bill and wants to
  /// continue to the NORMAL checkout. Adds each server-resolved variation
  /// with its exact quantity through the existing cart path (existing draft
  /// creation, quantity validation and add-item API — no price or tax is
  /// sent; the cart re-prices live). It never completes a sale or takes a
  /// payment. True when every line is in the cart (the caller then opens the
  /// existing checkout).
  Future<bool> confirmBill() async {
    if (_disposed || _billState != VoiceBillState.none) {
      return false; // already adding / added: a double tap does nothing
    }
    if (_correctionBase != null) {
      return false; // a spoken correction is being listened to / processed
    }
    final p = _preview;
    final r = _request;
    final s = _session;
    final req = _billRequest;
    final current =
        p != null &&
        _previewState == VoicePreviewState.loaded &&
        r != null &&
        s != null &&
        req != null &&
        req.requestId == r.requestId &&
        req.voiceSessionId == r.voiceSessionId &&
        p.voiceSessionId == s.voiceSessionId &&
        p.voiceSessionId == r.voiceSessionId &&
        p.requestId == r.requestId &&
        s.belongsTo(scope());
    if (current && !p.isReady) {
      return false; // still needs clarification: nothing to confirm yet
    }
    if (!current) {
      // Nothing is added: back to the voice input safely.
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = staleBillMessage;
      notifyListeners();
      return false;
    }
    final cart = this.cart;
    final open = cart?.sale;
    final refusal = cart == null
        ? noCartMessage
        : (cart.isLocalSale || cart.offline?.isOffline() == true)
        ? offlineMessage
        : (cart.isMutating ||
              cart.hasPendingCompletion ||
              (open != null && (!open.isDraft || open.items.isNotEmpty)))
        ? busyCartMessage
        : null;
    if (refusal != null) {
      _billError = refusal;
      notifyListeners();
      return false;
    }

    _billState = VoiceBillState.adding;
    _billError = null;
    notifyListeners();
    final lines = [...p.items]
      ..sort((a, b) => a.itemIndex.compareTo(b.itemIndex));
    var added = 0;
    for (final line in lines) {
      final ok = await cart!.addItem(
        line.productVariationId,
        line.quantity,
        label: line.variantName == null
            ? line.productName
            : '${line.productName} (${line.variantName})',
        sellingMode: line.sellingMode,
      );
      if (!ok) {
        await _billFailed(cart, added);
        return false;
      }
      added++;
    }
    if (_disposed) return false;
    _billState = VoiceBillState.added;
    notifyListeners();
    return true;
  }

  /// An add failed: stop (never skip a line), show the cart's own error, and
  /// take back what this bill already added with the cart's existing
  /// "Clear all" (the draft stays open and empty, as it normally does). A
  /// 401 is left to the existing session-expiry handling.
  Future<void> _billFailed(CartController cart, int added) async {
    final e = cart.error;
    var message = e == null
        ? 'The bill could not be added to the cart. Please try again.'
        : describeApiError(e);
    if (added > 0 && e?.isUnauthorized != true) {
      if (!await cart.clearAll()) {
        message += ' Part of this bill is in the cart — clear the cart before continuing.';
      }
    }
    if (_disposed) return;
    _billState = VoiceBillState.none;
    _billError = message;
    notifyListeners();
  }

  /// Test-only: the preview as if loaded (to simulate a stale preview).
  @visibleForTesting
  void debugSetPreview(QuickBillPreview p) {
    _preview = p;
    _previewState = VoicePreviewState.loaded;
    notifyListeners();
  }

  /// "Edit / Speak Again": discards this preview and listens for a new
  /// request in the same voice session (new request id).
  Future<bool> speakAgain() async {
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      return false;
    }
    _request = null;
    _intent = null;
    _billRequest = null;
    _clearPreview();
    _set(VoiceState.idle);
    return start();
  }

  /// "Cancel": discards the request and its preview; nothing was billed.
  void cancelBill() {
    if (_disposed) return;
    _stopSpeaking();
    _request = null;
    _intent = null;
    _billRequest = null;
    _clearPreview();
    _set(VoiceState.idle);
  }

  void _onRecognizerStatus(String status) {
    // The recognizer finished without a final result (e.g. silence).
    if (status == 'done' &&
        (_state == VoiceState.listening || _state == VoiceState.processing)) {
      final r = _request;
      if (r != null && r.text.isNotEmpty) {
        r.recognizedAt = DateTime.now();
        _set(VoiceState.recognized);
        _interpret(r);
      } else {
        _set(VoiceState.error, error: 'Nothing was heard. Try again.');
      }
    }
  }

  void _onRecognizerError(String error) {
    if (_state == VoiceState.idle || _state == VoiceState.recognized) return;
    _set(
      VoiceState.error,
      error: error.contains('no_match') || error.contains('speech_timeout')
          ? 'Nothing was heard. Try again.'
          // Phase 13H: the device cannot recognise this language — said
          // plainly; never retried in another language.
          : error.contains('language')
          ? 'Speech recognition in ${sessionLanguage.label} is not available on this device.'
          : 'Speech recognition failed. Try again.',
    );
  }

  static String _permissionMessage(VoicePermission p) => switch (p) {
    VoicePermission.permanentlyDenied => 'Microphone access is turned off for this app. Turn it on in the device settings to use voice.',
    VoicePermission.unavailable =>
      'The microphone is not available on this device.',
    VoicePermission.unsupportedPlatform => 'Voice input is not available in the desktop app. Use the keyboard or a barcode scanner instead.',
    _ => 'Microphone access is needed to use voice.',
  };

  @override
  void dispose() {
    _disposed = true;
    _sayGen++;
    final t = tts;
    if (t != null) {
      Future<void>.sync(t.stop).catchError((Object _) {});
      Future<void>.sync(t.dispose).catchError((Object _) {});
    }
    if (_state == VoiceState.listening || _state == VoiceState.processing) {
      recognizer.cancel().catchError((_) {});
    }
    super.dispose();
  }
}
