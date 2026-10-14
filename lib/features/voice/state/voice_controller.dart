import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/quantity.dart';
import '../../auth/models/pos_token_scope.dart';
import '../../cart/models/cart_sale.dart';
import '../../cart/state/cart_controller.dart';
import '../data/voice_order_service.dart';
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

/// Phase 2 — an existing order looked up by voice ("bill order 1048").
enum VoiceOrderState {
  none,
  loading,
  loaded,

  /// No held order with that number in this store (or out of scope).
  notFound,

  /// "bill table 6" with no table lookup available on this screen.
  unsupported,

  /// Phase 2.1: several held orders at the table — the cashier must pick
  /// one ([VoiceController.tableOrders] / [VoiceController.chooseTableOrder]).
  choosing,

  /// The lookup failed (network / server); [VoiceController.retryOrder].
  failed,

  /// Changed or billed by someone else since it was shown — reload.
  conflict,

  /// No longer billable here (cancelled, moved, another store).
  ineligible,
}

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
    this.replyParser = const RuleBasedReplyParser(),
    this.orderService,
    this.tts,
    this.settings,
  });

  /// Phase 13G: the app-local voice language setting (null = English).
  final VoiceSettings? settings;

  /// Phase 3A: the signed-in staff member on this device (company + staff),
  /// the key their language choice is kept under; null when nobody is
  /// signed in (the device default applies).
  String? get _staffKey {
    final s = scope();
    return s == null ? null : '${s.companyId}:${s.salesmanId}';
  }

  /// The language a NEW voice session starts in (this staff member's
  /// choice, else the device default).
  VoiceLanguage get language =>
      settings?.languageFor(_staffKey) ?? VoiceLanguage.english;

  /// Phase 13H: selects the language for the NEXT voice bill. An existing
  /// session keeps its own language (a bill waiting for confirmation is
  /// never re-read in another language). Phase 3A: kept for the signed-in
  /// staff member only. False for a language without an implementation (or
  /// with no settings attached).
  bool selectLanguage(VoiceLanguage l) {
    final s = settings;
    if (s == null || !s.setLanguage(l, staff: _staffKey)) return false;
    notifyListeners();
    return true;
  }

  /// Phase 3A: languages this device's recognizer reported it cannot hear.
  final Set<VoiceLanguage> _noRecognition = {};

  /// Phase 3A: languages this device could not speak (replies on screen).
  final Set<VoiceLanguage> _noSpokenReplies = {};

  /// False only when the device's recognizer said it does not support
  /// [l] (unknown = true until checked).
  bool recognitionAvailable(VoiceLanguage l) => !_noRecognition.contains(l);

  /// False once speaking in [l] failed on this device.
  bool spokenRepliesAvailable(VoiceLanguage l) => !_noSpokenReplies.contains(l);

  /// The on-screen note when the session language cannot be spoken here.
  String? get spokenRepliesNote =>
      tts == null || spokenRepliesAvailable(sessionLanguage)
      ? null
      : _screen.spokenRepliesUnavailable(sessionLanguage.label);

  /// The current session's language (recognition, parsing, replies).
  VoiceLanguage get sessionLanguage => _session?.language ?? language;

  /// Phase 13F: Jacky's spoken replies (operator Quick Bill only; null =
  /// silent). Presentation only — never decides or changes anything.
  final VoiceTtsService? tts;

  /// Phase 13E: spoken corrections of the Quick Bill on screen.
  final RuleBasedCorrectionParser correctionParser;

  /// Phase 1 (English): spoken yes / no / cancel to "Would you like to
  /// confirm this bill?".
  final RuleBasedReplyParser replyParser;

  /// Phase 2: existing orders by voice and the voice audit link (null = not
  /// available on this screen).
  final VoiceOrderService? orderService;

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
  bool _confirmedByVoice = false;

  // Phase 2 — the existing order on screen.
  VoiceOrderState _orderState = VoiceOrderState.none;
  CartSale? _order;
  int? _orderNumber;
  String? _orderMessage;
  bool _orderRetryable = false;

  /// While listening for / interpreting a spoken answer about the order on
  /// screen: the order's own request (restored when nothing is decided).
  VoiceRequest? _orderAnswerBase;

  // Phase 2.1 — a table lookup.
  String? _tableRef;
  List<TableOrderSummary> _tableOrders = const [];

  /// The table asked for ("bill table 6" -> "6"), while its result is shown.
  String? get tableRef => _tableRef;

  /// The held orders at [tableRef] when there are several to choose from.
  List<TableOrderSummary> get tableOrders => _tableOrders;

  VoiceOrderState get orderState => _orderState;

  /// The server's view of the held order (lines, prices, tax, total, version).
  CartSale? get order => _order;
  int? get orderNumber => _orderNumber;
  String? get orderMessage => _orderMessage;
  bool get orderRetryable => _orderRetryable;
  bool get isAnsweringOrder => _orderAnswerBase != null;

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
    if (s == VoiceState.error && _orderAnswerBase != null) _restoreOrder();
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

      // Phase 3A: never listen in a language the device's recognizer says
      // it cannot hear (and never fall back to another language). A
      // recognizer that cannot tell (null) is tried as before.
      final r = recognizer;
      if (r is LocaleAwareRecognizer) {
        final supported = await (r as LocaleAwareRecognizer).supportsLanguage(
          lang,
        );
        if (supported == false) {
          _noRecognition.add(lang);
          _set(
            VoiceState.error,
            error:
                (VoiceResponses.forLanguage(lang) ??
                        const EnglishVoiceResponses())
                    .recognitionUnavailable(lang.label),
          );
          return false;
        }
        _noRecognition.remove(lang);
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
      } else if (_orderAnswerBase != null) {
        _restoreOrder(); // the order stays on screen, unchanged
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
    if (_orderAnswerBase != null) return _interpretOrderAnswer(r);
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
    // Phase 2: an existing order.
    if (result.type == VoiceIntentType.billOrder && orderService != null) {
      return _loadOrder(r, result.orderNumber!);
    }
    if (result.type == VoiceIntentType.tableOrder) {
      if (orderService != null) return _loadTable(r, '${result.tableNumber}');
      _clearPreview();
      _orderState = VoiceOrderState.unsupported;
      _orderMessage = _screen.tableUnsupported();
      notifyListeners();
      if (_responses != null) _say(_screen.tableUnsupported());
      return;
    }
    if (result.type == VoiceIntentType.billShownOrder) {
      _clearPreview();
      _orderState = VoiceOrderState.notFound;
      _orderMessage = _screen.whichOrder();
      notifyListeners();
      return;
    }
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
    _confirmedByVoice = false;
    _orderState = VoiceOrderState.none;
    _order = null;
    _orderNumber = null;
    _orderMessage = null;
    _orderRetryable = false;
    _tableRef = null;
    _tableOrders = const [];
  }

  /// Phase 1: the current bill was confirmed by a spoken "yes" (through
  /// [confirmBill], exactly like the button) — the screen then continues to
  /// the existing checkout.
  bool get confirmedByVoice =>
      _confirmedByVoice && _billState == VoiceBillState.added;

  /// Phase 1 (English) — asked after a spoken "no".
  static const whatToChangeQuestion =
      'What would you like to change? ${RuleBasedCorrectionParser.exampleHint}';

  /// Phase 1 (English) — asked when the answer was not a clear yes or no.
  static const yesOrNoQuestion =
      'Please say yes to confirm the bill, or no to change it.';

  static const notReadyToConfirmMessage =
      'This bill still needs a clarification before it can be confirmed.';

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
      _previewError = _screen.staleBill();
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
        .then((_) => _noSpokenReplies.remove(lang))
        .catchError((Object _) {
          // Phase 3A: not spoken (e.g. no voice for this language): the
          // reply stays on screen and the screen says speech is off.
          if (_noSpokenReplies.add(lang) && !_disposed) notifyListeners();
          return false;
        })
        .whenComplete(() {
          if (_disposed || gen != _sayGen) return;
          _speaking = false;
          notifyListeners();
        });
  }

  /// Phase 3B: stops Jacky's current reply (before switching to translation
  /// mode). Nothing else about the bill changes.
  void stopSpeaking() => _stopSpeaking();

  /// Phase 3B: translation mode may open only while nothing is in progress
  /// here (not listening, not adding a bill, not waiting for a spoken
  /// answer). A bill waiting for confirmation stays exactly as it is; when
  /// the staff member returns, confirming it goes through the usual checks.
  bool get canOpenTranslation =>
      !_disposed &&
      _state != VoiceState.listening &&
      _state != VoiceState.processing &&
      _state != VoiceState.requestingPermission &&
      _billState == VoiceBillState.none &&
      _correctionBase == null &&
      _orderAnswerBase == null;

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
      _previewError = _screen.staleBill();
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

    // Phase 1 (English): first, a spoken answer to "Would you like to
    // confirm this bill?" — yes / no / cancel.
    ({VoiceReply reply, String? rest})? answer;
    try {
      answer = replyParser.parse(r.text, language: s.language);
    } catch (_) {
      answer = null;
    }
    var said = r.text;
    if (answer != null) {
      switch (answer.reply) {
        case VoiceReply.confirm:
          return _confirmByVoice(base.request, ask);
        case VoiceReply.cancel:
          cancelBill();
          if (_responses != null) {
            _say(_screen.billCancelled());
          }
          return;
        case VoiceReply.unclear:
          return ask(_screen.yesOrNo());
        case VoiceReply.reject:
          final rest = answer.rest;
          if (rest == null || rest.isEmpty) return ask(_screen.whatToChange());
          said = rest; // "no, make the coffee three"
      }
    }

    VoiceCorrection? c;
    try {
      c = correctionParser.parse(said, language: s.language);
    } catch (_) {
      c = null;
    }
    if (c == null) {
      return ask(
        answer?.reply == VoiceReply.reject
            ? _screen.whatToChange()
            : _screen.notACorrection(),
      );
    }
    final bill = base.bill;
    final preview = base.preview;
    switch (c.kind) {
      case VoiceCorrectionKind.unclear:
        return ask(c.question ?? RuleBasedCorrectionParser.exampleHint);
      case VoiceCorrectionKind.setQuantity:
        final i = _targetLine(c.target, bill, preview, ask, c.position);
        if (i == null) return;
        final problem = await _setQuantity(i, c.quantity!, unit: c.unit);
        if (problem != null) ask(problem);
      case VoiceCorrectionKind.remove:
        final i = _targetLine(c.target, bill, preview, ask, c.position);
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
    void Function(String, {String? spoken}) ask, [
    int? position,
  ]) {
    final all = [for (var i = 0; i < bill.items.length; i++) i];
    if (position != null) {
      // Phase 1: "the first item" / "the last one" — the bill's own order.
      final n = bill.items.length;
      final i = position == -1 ? n - 1 : position - 1;
      if (i >= 0 && i < n) return i;
      ask(
        _screen.noSuchLineScreen('item $position', _labels(all, bill, preview)),
        spoken: _responses?.noSuchLine('item $position'),
      );
      return null;
    }
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

  /// Phase 1: a spoken "yes" confirms the bill that was on screen when the
  /// answer was asked for ([reviewed]) — through [confirmBill], so the same
  /// checks apply as for the button (current revision, not stale, nothing
  /// added twice). It only puts the lines into the cart for the existing
  /// checkout: it never completes the sale or takes a payment.
  Future<void> _confirmByVoice(
    VoiceRequest reviewed,
    void Function(String, {String? spoken}) ask,
  ) async {
    _request = reviewed;
    final p = _preview;
    if (p == null || !p.isReady) return ask(_screen.notReadyToConfirm());
    if (await confirmBill()) {
      _confirmedByVoice = true;
      notifyListeners();
    } else if (_billError != null && _responses != null) {
      _say(_billError!);
    }
  }

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
      _previewError = _screen.staleBill();
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
      _previewError = _screen.staleBill();
      notifyListeners();
      return false;
    }
    final cart = this.cart;
    final open = cart?.sale;
    final refusal = cart == null
        ? _screen.noCart()
        : (cart.isLocalSale || cart.offline?.isOffline() == true)
        ? _screen.offline()
        : (cart.isMutating ||
              cart.hasPendingCompletion ||
              (open != null && (!open.isDraft || open.items.isNotEmpty)))
        ? _screen.busyCart()
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
    _linkQuickBill(cart!, s, r);
    return true;
  }

  /// Phase 2: records which voice request this confirmed quick bill came
  /// from (the server checks it is this cashier's own current draft).
  /// Best effort: never blocks or changes the bill.
  void _linkQuickBill(CartController cart, VoiceSession s, VoiceRequest r) {
    final service = orderService;
    final saleId = cart.isLocalSale ? null : cart.sale?.id;
    if (service == null || saleId == null) return;
    Future<void>.sync(
      () => service.linkQuickBill(
        saleId: saleId,
        voiceSessionId: s.voiceSessionId,
        requestId: r.requestId,
      ),
    ).catchError((Object _) {});
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

  // --- Phase 2: existing order -> existing checkout ---------------------

  static const tableUnsupportedMessage =
      'Table orders are not available here. Say "bill order" and the order '
      'number, for example "bill order 1048".';

  static String noTableOrdersMessage(String table) =>
      'No held orders are waiting for billing at table $table.';

  /// Phase 2.1 — "bill table 6": the server lists this store's held orders
  /// at the table (read only). None: said so. One: shown for verification
  /// through the normal order lookup. Several: listed — the cashier must
  /// choose one ([chooseTableOrder]); none is ever picked automatically.
  Future<void> _loadTable(VoiceRequest r, String table) async {
    _clearPreview();
    _tableRef = table;
    _orderState = VoiceOrderState.loading;
    notifyListeners();
    VoiceTableLookup? found;
    String? message;
    var retryable = false;
    try {
      found = await orderService!.lookupTable(
        tableRef: table,
        voiceSessionId: r.voiceSessionId,
        requestId: r.requestId,
      );
      if (found.voiceSessionId != r.voiceSessionId ||
          found.requestId != r.requestId) {
        found = null; // another request's answer: never shown
        retryable = true;
        message = _screen.tableMismatch();
      }
    } on ApiException catch (e) {
      retryable = e.isRetryable;
      message = switch (e.kind) {
        ApiErrorKind.network ||
        ApiErrorKind.timeout => _screen.tableNetwork(table),
        _ => describeApiError(e),
      };
    } catch (_) {
      retryable = true;
      message = _screen.tableLoadFailed(table);
    }
    if (_disposed || !identical(_request, r)) return; // a newer request won
    if (found == null) {
      _orderState = VoiceOrderState.failed;
      _orderMessage = message;
      _orderRetryable = retryable;
      notifyListeners();
      if (_responses != null) _say(message!);
      return;
    }
    final orders = found.orders;
    if (orders.isEmpty) {
      _orderState = VoiceOrderState.notFound;
      _orderMessage = _screen.noTableOrders(table);
      notifyListeners();
      if (_responses != null) _say(_orderMessage!);
      return;
    }
    if (orders.length == 1) {
      // Exactly one match: shown for verification (not billed) through the
      // same lookup as "bill order N".
      final tableRef = _tableRef;
      await _loadOrder(r, orders.single.id);
      _tableRef = tableRef;
      return;
    }
    _tableOrders = orders;
    _orderState = VoiceOrderState.choosing;
    notifyListeners();
    if (_responses != null) {
      _say(_screen.tableChoose(orders.length, table));
    }
  }

  /// Phase 2.1 — the cashier picked [saleId] from the table list: it is
  /// looked up as a NEW request (server-checked again, audited) and shown
  /// for verification like "bill order N".
  Future<void> chooseTableOrder(int saleId) async {
    final s = _session;
    if (_disposed ||
        s == null ||
        orderService == null ||
        _orderState != VoiceOrderState.choosing ||
        !_tableOrders.any((o) => o.id == saleId)) {
      return;
    }
    if (!s.belongsTo(scope())) {
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = _screen.staleBill();
      notifyListeners();
      return;
    }
    final table = _tableRef;
    final previous = _request;
    final r = _request = VoiceRequest.start(s)
      ..text = previous?.text ?? ''
      ..recognizedAt = previous?.recognizedAt;
    await _loadOrder(r, saleId);
    _tableRef = table;
  }

  static const orderChangedMessage =
      'This order was changed or billed by someone else after it was shown. '
      'Reload it to review it again.';
  static const orderIneligibleMessage =
      'This order can no longer be billed here. Reload it, or check Orders.';
  static const orderUncertainMessage =
      'Could not reach the server to open this order. Reload it to check '
      'whether it was opened before trying again.';

  /// Finds held order [n] for request [r]; only the current request's answer
  /// is shown. Read only on the server.
  Future<void> _loadOrder(VoiceRequest r, int n) async {
    _clearPreview();
    _orderState = VoiceOrderState.loading;
    _orderNumber = n;
    notifyListeners();
    VoiceOrderLookup? found;
    String? message;
    var state = VoiceOrderState.failed;
    var retryable = false;
    try {
      found = await orderService!.lookup(
        orderNumber: n,
        voiceSessionId: r.voiceSessionId,
        requestId: r.requestId,
      );
      if (found.voiceSessionId != r.voiceSessionId ||
          found.requestId != r.requestId ||
          found.order.id != n) {
        found = null; // another request's answer: never shown
        retryable = true;
        message = _screen.orderMismatch();
      } else {
        state = VoiceOrderState.loaded;
      }
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) {
        state = VoiceOrderState.notFound;
        message = _screen.orderNotFound(n);
      } else {
        retryable = e.isRetryable;
        message = switch (e.kind) {
          ApiErrorKind.network ||
          ApiErrorKind.timeout => _screen.orderNetwork(),
          _ => describeApiError(e),
        };
      }
    } catch (_) {
      retryable = true;
      message = _screen.orderLoadFailed();
    }
    if (_disposed || !identical(_request, r)) return; // a newer request won
    _order = found?.order;
    _orderState = state;
    _orderMessage = message;
    _orderRetryable = retryable;
    notifyListeners();
    final say = _responses;
    if (say == null) return;
    final o = _order;
    _say(
      o == null
          ? message!
          : say.orderPrompt(n, formatMoney(o.totals.grandTotal ?? 0)),
    );
  }

  /// Retry after a failed lookup, or Reload after a conflict: the same order
  /// number as a NEW request (same voice session).
  Future<void> retryOrder() async {
    final s = _session;
    final n = _orderNumber;
    final table = _tableRef;
    final previous = _request;
    if (_disposed ||
        s == null ||
        (n == null && table == null) ||
        orderService == null ||
        _billState != VoiceBillState.none ||
        _orderAnswerBase != null) {
      return;
    }
    if (!s.belongsTo(scope())) {
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = _screen.staleBill();
      notifyListeners();
      return;
    }
    final r = _request = VoiceRequest.start(s)
      ..text = previous?.text ?? ''
      ..recognizedAt = previous?.recognizedAt;
    if (n == null) return _loadTable(r, table!);
    await _loadOrder(r, n);
    _tableRef = table;
  }

  /// "Bill this order" (touch) or a spoken "yes": the EXISTING resume of the
  /// held sale (server lock + version + store checks; the order shown must
  /// still be the current one), recorded against this voice request. The
  /// same sale then goes to the existing checkout — nothing is paid or
  /// completed here, and no second sale is created.
  Future<bool> confirmOrder({bool byVoice = false}) async {
    final o = _order;
    final s = _session;
    if (_disposed ||
        o == null ||
        s == null ||
        _orderState != VoiceOrderState.loaded ||
        _billState != VoiceBillState.none ||
        _orderAnswerBase != null) {
      return false;
    }
    if (!s.belongsTo(scope())) {
      _clearPreview();
      _previewState = VoicePreviewState.failed;
      _previewError = _screen.staleBill();
      notifyListeners();
      return false;
    }
    final cart = this.cart;
    final refusal = cart == null
        ? _screen.noCart()
        : (cart.isLocalSale || cart.offline?.isOffline() == true)
        ? _screen.offline()
        : (cart.isMutating || cart.hasPendingCompletion)
        ? _screen.busyCart()
        : null;
    if (refusal != null) {
      _billError = refusal;
      notifyListeners();
      return false;
    }
    _billState = VoiceBillState.adding;
    _billError = null;
    notifyListeners();
    final action = VoiceRequest.start(s); // the bill action's own request id
    final ok = await cart!.resumeHeldSale(
      saleId: o.id,
      expectedVersion: o.version,
      voice: {
        'voice_session_id': s.voiceSessionId,
        'request_id': action.requestId,
      },
    );
    if (_disposed) return false;
    if (ok) {
      _billState = VoiceBillState.added;
      _confirmedByVoice = byVoice;
      notifyListeners();
      return true;
    }
    _billState = VoiceBillState.none;
    final e = cart.error;
    switch (e?.kind) {
      case ApiErrorKind.conflict:
        _orderState = VoiceOrderState.conflict;
        _orderMessage = _screen.orderChanged();
      case ApiErrorKind.forbidden || ApiErrorKind.notFound:
        _orderState = VoiceOrderState.ineligible;
        _orderMessage = _screen.orderIneligible();
      case ApiErrorKind.network || ApiErrorKind.timeout:
        _orderState = VoiceOrderState.conflict; // outcome unknown: reload first
        _orderMessage = _screen.orderUncertain();
      default:
        _billError = e == null
            ? _screen.orderOpenFailed()
            : describeApiError(e);
    }
    notifyListeners();
    final spoken = _orderMessage ?? _billError;
    if (_responses != null && spoken != null) _say(spoken);
    return false;
  }

  /// "Answer by voice" on an order: listens for yes / no / cancel / "bill
  /// that order" while the order stays on screen.
  Future<bool> startOrderAnswer() async {
    if (_orderState != VoiceOrderState.loaded ||
        _billState != VoiceBillState.none ||
        _orderAnswerBase != null ||
        _request == null) {
      return false;
    }
    _orderAnswerBase = _request;
    _correctionQuestion = null;
    _billError = null;
    final ok = await _start(keepBill: true);
    if (!ok && _orderAnswerBase != null) {
      _restoreOrder();
      notifyListeners();
    }
    return ok;
  }

  void _restoreOrder() {
    _request = _orderAnswerBase;
    _orderAnswerBase = null;
  }

  Future<void> _interpretOrderAnswer(VoiceRequest r) async {
    final base = _orderAnswerBase!;
    _orderAnswerBase = null;
    if (_disposed || !identical(_request, r)) return;
    _request = base;
    void ask(String q) {
      _correctionQuestion = q;
      notifyListeners();
      final say = _responses;
      if (say != null) _say(say.question(q));
    }

    final s = _session;
    ({VoiceReply reply, String? rest})? answer;
    try {
      answer = replyParser.parse(r.text, language: s?.language ?? language);
    } catch (_) {
      answer = null;
    }
    var bill = answer?.reply == VoiceReply.confirm;
    if (answer == null) {
      VoiceIntent? said;
      try {
        said = await intentParser.parse(
          r.text,
          voiceSessionId: r.voiceSessionId,
          requestId: r.requestId,
          language: s?.language ?? language,
        );
      } catch (_) {
        said = null;
      }
      if (_disposed || !identical(_request, base)) return;
      bill = said?.type == VoiceIntentType.billShownOrder;
      if (!bill) {
        return ask(_screen.orderAnswerHint());
      }
    }
    switch (answer?.reply) {
      case VoiceReply.cancel || VoiceReply.reject:
        cancelBill();
        if (_responses != null) {
          _say(_screen.orderLeftAsIs());
        }
        return;
      case VoiceReply.unclear:
        return ask(_screen.yesOrNo());
      default:
        if (bill) await confirmOrder(byVoice: true);
    }
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
