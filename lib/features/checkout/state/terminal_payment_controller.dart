import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/uuid.dart';
import '../data/payment_terminal_service.dart';
import '../models/terminal_payment.dart';

/// What the cashier sees during a card-terminal payment.
enum TerminalPhase {
  /// Sending the payment to the server / terminal.
  connecting,

  /// The terminal is waiting for the customer's card.
  waitingForCard,

  /// Asking the server for the latest status.
  processing,

  /// Cancel requested; waiting for the provider to confirm it.
  cancelling,

  /// Captured — the sale can be completed with this payment.
  approved,

  /// Declined / failed — no money was taken; try again or use another tender.
  declined,

  /// Cancelled (confirmed by the provider).
  cancelled,

  /// The provider closed it at its expiry without payment (QR).
  expired,

  /// No answer we can trust yet. Money MAY have been taken: never treated as
  /// failed — check again, or cancel through the provider.
  unknown,

  /// No terminal is configured for this register / provider unavailable.
  unavailable,
}

/// Drives one terminal payment through the server's payment-attempt API and
/// polls `GET /payment-attempts/:id?refresh=true`. One idempotency key per
/// payment: a retried start can never create a second terminal transaction.
/// The server stays authoritative — nothing here decides that a payment
/// succeeded except a CAPTURED status from the server.
class TerminalPaymentController extends ChangeNotifier {
  TerminalPaymentController(
    this._service, {
    required this.saleId,
    required this.provider,
    required this.amountMilli,
    this.method = 'CARD',
    this.pollInterval = const Duration(seconds: 3),
    this.maxWait = const Duration(minutes: 3),
    String? idempotencyKey,
    DateTime Function()? clock,
  }) : idempotencyKey = idempotencyKey ?? generateUuidV4(),
       _now = clock ?? DateTime.now;

  /// Wall clock for the wait deadline (injectable for tests).
  final DateTime Function() _now;

  final PaymentTerminalService _service;
  final int saleId;
  final String provider;
  final int amountMilli;

  /// CARD (terminal) or QR.
  final String method;
  final Duration pollInterval;
  final Duration maxWait;
  final String idempotencyKey;

  TerminalPhase _phase = TerminalPhase.connecting;
  TerminalPhase get phase => _phase;

  PaymentAttempt? _attempt;
  PaymentAttempt? get attempt => _attempt;

  String? _message;

  /// Extra cashier-facing detail for the current phase (never raw provider text).
  String? get message => _message;

  Timer? _timer;
  DateTime? _deadline;
  bool _disposed = false;

  bool get canCancel =>
      _attempt != null && _attempt!.status.isOpen && _phase != TerminalPhase.cancelling && !isReferenceRecordedUnattached;

  /// Phase 18B.1: an unconfirmed attempt (no provider reference) may be
  /// abandoned by a manager; the server decides permission and timing.
  /// Phase 18B.15: never when the attempt has a provider reference, or the
  /// server said its reference is recorded (it must be checked / cancelled
  /// through the provider instead).
  bool get canAbandon =>
      _attempt != null &&
      _attempt!.unconfirmed &&
      !_attempt!.hasProviderReference &&
      !isReferenceRecordedUnattached &&
      _attempt!.status.isOpen &&
      (_phase == TerminalPhase.unknown || _phase == TerminalPhase.waitingForCard);

  /// Phase 18B.15: the server refused abandon / cancel because the provider's
  /// reference for this still-open attempt is durably recorded but not yet
  /// attached (POS_PAYMENT_PROVIDER_REFERENCE_UNRECORDED). The payment may
  /// still be paid on the terminal: no abandon, no cancel, no other tender
  /// until a manager attaches it; "Check again" picks the reference up.
  bool _referenceRecorded = false;
  /// Phase 18B.17: an explicit provider_reference_status from the server
  /// decides; only when it is missing / unknown (older backend) does the
  /// earlier refusal ([_referenceRecorded]) decide.
  bool get isReferenceRecordedUnattached {
    final a = _attempt;
    if (a == null || !a.status.isOpen || a.hasProviderReference) return false;
    return switch (a.referenceStatus) {
      ProviderReferenceStatus.recordedUnattached => true,
      ProviderReferenceStatus.attached || ProviderReferenceStatus.notRecorded => false,
      ProviderReferenceStatus.unknown => _referenceRecorded,
    };
  }

  /// Ended by a manager without the provider's confirmation.
  bool get isAbandoned => _attempt?.isAbandoned == true;

  /// Phase 18B.3: the wait ([maxWait] — for a card terminal its auto-cancel
  /// window) has passed and the payment is still not confirmed either way.
  /// Shown as its own state; never treated as failed or cancelled.
  bool _overdue = false;
  bool get isOverdue => _overdue && (_attempt == null || _attempt!.status.isOpen);
  bool get canCheckAgain =>
      _phase == TerminalPhase.unknown || (isReferenceRecordedUnattached && _phase != TerminalPhase.processing);
  bool get isFinal =>
      _phase == TerminalPhase.approved ||
      _phase == TerminalPhase.declined ||
      _phase == TerminalPhase.cancelled ||
      _phase == TerminalPhase.expired ||
      _phase == TerminalPhase.unavailable;

  /// After a final outcome without payment, a NEW payment (new key) may be tried.
  bool get canRetry =>
      _phase == TerminalPhase.declined ||
      _phase == TerminalPhase.cancelled ||
      _phase == TerminalPhase.expired;

  /// Ask the server now (e.g. when the displayed expiry is reached) — the
  /// server, not the till's clock, decides whether it expired.
  Future<void> refreshNow() async {
    if (_attempt == null || !_attempt!.status.isOpen) return;
    _timer?.cancel();
    await _poll();
  }

  Future<void> start() async {
    _set(TerminalPhase.connecting);
    try {
      _apply(await _service.start(saleId: saleId, provider: provider, amountMilli: amountMilli, idempotencyKey: idempotencyKey, method: method));
    } on ApiException catch (e) {
      _onError(e, starting: true);
      await _readReferenceStatus();
    }
  }

  /// Phase 18B.17 — for an open attempt without a provider reference, read
  /// the server's current view (no provider call) to learn whether its
  /// reference is recorded. A failure here changes nothing.
  Future<void> _readReferenceStatus() async {
    final a = _attempt;
    if (a == null || _disposed || !a.status.isOpen || a.hasProviderReference) return;
    try {
      final latest = await _service.current(a.id);
      if (_disposed || latest.id != a.id) return;
      if (!latest.status.isOpen) return _apply(latest);
      _attempt = latest;
      notifyListeners();
    } on ApiException {
      // Keep what we know; the next check tries again.
    }
  }

  /// After an unknown outcome: re-ask (re-sending the SAME start request if
  /// no attempt is known yet — the server returns the same attempt).
  /// Phase 18B.3: the wait is NOT restarted — before the deadline polling
  /// resumes until it; after it, each Check again is one status check.
  Future<void> checkAgain() async {
    if (_attempt == null) return start();
    _deadline ??= _now().add(maxWait);
    await _poll();
  }

  Future<void> cancel() async {
    final a = _attempt;
    if (a == null || !a.status.isOpen) return;
    _timer?.cancel();
    _set(TerminalPhase.cancelling);
    try {
      _apply(await _service.cancel(a.id));
    } on ApiException catch (e) {
      if (e.errorCode == 'POS_PAYMENT_CANCEL_NOT_CONFIRMED') {
        final latest = PaymentAttempt.fromJson(e.dataMap?['payment_attempt']);
        if (latest != null) _attempt = latest;
        _message = 'The terminal did not confirm the cancellation. The payment may still be in progress.';
        _set(TerminalPhase.waitingForCard, keepMessage: true);
        _schedulePoll();
      } else if (e.errorCode == 'POS_PAYMENT_ALREADY_COMPLETED') {
        await _poll(); // it was captured meanwhile
      } else if (e.errorCode == referenceUnrecordedCode) {
        _onReferenceRecorded(e);
      } else {
        _message = 'The cancellation could not be confirmed. Check the payment status.';
        _set(TerminalPhase.unknown, keepMessage: true);
      }
    }
  }

  /// Phase 18B.1 — asks the server to abandon this unconfirmed attempt with
  /// [reason]. True when it is abandoned (the warning is then the message).
  /// Refusals (no permission, too early, changed) keep the attempt as it was.
  Future<bool> abandon(String reason) async {
    final a = _attempt;
    if (a == null || !canAbandon) return false;
    _timer?.cancel();
    _set(TerminalPhase.processing);
    try {
      final r = await _service.abandonUnconfirmed(a.id, reason);
      _apply(r.attempt);
      _message = r.warning;
      _set(_phase, keepMessage: true);
      return r.attempt.isAbandoned;
    } on ApiException catch (e) {
      if (e.errorCode == referenceUnrecordedCode) {
        _onReferenceRecorded(e);
        return false;
      }
      final latest = PaymentAttempt.fromJson(e.dataMap?['payment_attempt']);
      if (latest != null) _attempt = latest;
      _message = switch (e.errorCode) {
        'POS_PAYMENT_ABANDON_TOO_EARLY' => _tooEarly(asString(e.dataMap?['available_at'])),
        _ when e.kind == ApiErrorKind.forbidden =>
          'Only a manager can abandon this payment. Ask a manager to sign in on this till.',
        _ => e.message,
      };
      _set(TerminalPhase.unknown, keepMessage: true);
      return false;
    }
  }

  static const referenceUnrecordedCode = 'POS_PAYMENT_PROVIDER_REFERENCE_UNRECORDED';

  /// Shown while [isReferenceRecordedUnattached]: never "failed" / "cancelled".
  static const referenceRecordedMessage =
      'The terminal reference for this payment is recorded but not attached yet. The customer may still be charged on the terminal — '
      'do not take another payment. A manager must attach the reference (Payment Reconciliation in the admin portal); '
      'then use Check again, and check or cancel the payment here.';

  void _onReferenceRecorded(ApiException e) {
    final latest = PaymentAttempt.fromJson(e.dataMap?['payment_attempt']);
    if (latest != null) _attempt = latest;
    _referenceRecorded = true;
    _timer?.cancel();
    _message = referenceRecordedMessage;
    _set(TerminalPhase.unknown, keepMessage: true);
  }

  static String _tooEarly(String? availableAt) {
    final at = DateTime.tryParse(availableAt ?? '')?.toLocal();
    final when = at == null
        ? 'later'
        : 'after ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    return 'The terminal may still accept this payment. It can be abandoned $when.';
  }

  void _apply(PaymentAttempt a) {
    _attempt = a;
    _message = null;
    switch (a.status) {
      case AttemptStatus.captured:
        _timer?.cancel();
        _set(TerminalPhase.approved);
      case AttemptStatus.failed:
        _timer?.cancel();
        _message = a.failureMessage;
        _set(TerminalPhase.declined, keepMessage: true);
      case AttemptStatus.cancelled:
        _timer?.cancel();
        if (a.isAbandoned) _message = abandonWarning;
        _set(a.isExpired ? TerminalPhase.expired : TerminalPhase.cancelled, keepMessage: a.isAbandoned);
      case AttemptStatus.pending:
      case AttemptStatus.authorized:
        _deadline ??= _now().add(maxWait);
        _set(TerminalPhase.waitingForCard);
        _schedulePoll();
      default:
        _timer?.cancel();
        _set(TerminalPhase.unknown);
    }
  }

  void _onError(ApiException e, {bool starting = false}) {
    final latest = PaymentAttempt.fromJson(e.dataMap?['payment_attempt']);
    switch (e.errorCode) {
      case 'POS_PAYMENT_TERMINAL_NOT_CONFIGURED':
      case 'POS_PAYMENT_PROVIDER_NOT_SUPPORTED':
      case 'POS_PAYMENT_CURRENCY_NOT_SUPPORTED':
      case 'POS_PAYMENT_METHOD_NOT_SUPPORTED':
        _message = 'The card terminal is not available for this register.';
        _set(TerminalPhase.unavailable, keepMessage: true);
        return;
      case 'POS_PAYMENT_FAILED':
        if (latest != null) return _apply(latest);
        _set(TerminalPhase.declined);
        return;
    }
    if (latest != null && latest.status.isOpen) {
      // Timeout / provider outcome unknown: the attempt exists and is still
      // open — keep watching it.
      _attempt = latest;
      _deadline ??= _now().add(maxWait);
      _set(TerminalPhase.waitingForCard);
      _schedulePoll();
      return;
    }
    if (latest != null) return _apply(latest);
    if (starting && (e.kind == ApiErrorKind.validation || e.kind == ApiErrorKind.conflict || e.kind == ApiErrorKind.forbidden)) {
      // The server refused the request (nothing was sent to the terminal).
      _message = e.message;
      _set(TerminalPhase.unavailable, keepMessage: true);
      return;
    }
    // No trustworthy answer (network/timeout/server): the payment may exist.
    _message = 'No confirmation from the server yet. Check again before taking another payment.';
    _set(TerminalPhase.unknown, keepMessage: true);
  }

  void _schedulePoll() {
    _timer?.cancel();
    if (_disposed) return;
    if (_deadline != null && _now().isAfter(_deadline!)) {
      _overdue = true;
      _message =
          'The terminal has not confirmed the payment or its cancellation within its time limit. '
          'Do not take another payment: check the terminal, then Check again.';
      _set(TerminalPhase.unknown, keepMessage: true);
      return;
    }
    _timer = Timer(pollInterval, _poll);
  }

  Future<void> _poll() async {
    final a = _attempt;
    if (a == null || _disposed) return;
    _set(TerminalPhase.processing, keepMessage: true);
    try {
      _apply(await _service.refresh(a.id));
    } on ApiException catch (e) {
      final latest = PaymentAttempt.fromJson(e.dataMap?['payment_attempt']);
      if (latest != null && !latest.status.isOpen) return _apply(latest);
      // A failed status check changes nothing: keep waiting until the deadline.
      // Phase 18B.17: without a provider reference the provider cannot be
      // asked — read whether the reference is recorded instead.
      await _readReferenceStatus();
      if (_disposed || !(_attempt?.status.isOpen ?? false)) return;
      _set(TerminalPhase.waitingForCard, keepMessage: true);
      _schedulePoll();
    }
  }

  void _set(TerminalPhase p, {bool keepMessage = false}) {
    if (_disposed) return;
    if (!keepMessage && p != TerminalPhase.processing) _message = null;
    _phase = p;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
