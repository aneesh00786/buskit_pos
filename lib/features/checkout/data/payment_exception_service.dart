import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';

/// Phase 7 — a captured provider payment whose sale could not be completed,
/// as the server reports it (`/payment-exceptions`). The server decides
/// everything (state, what the viewer may do); the app only shows it and
/// asks.
class PaymentExceptionView {
  const PaymentExceptionView({
    required this.paymentAttemptId,
    required this.state,
    required this.provider,
    required this.amount,
    this.currency,
    this.resolution,
    this.reasonCode,
    this.recommendedAction,
    this.providerReference,
    this.refundStatus,
    this.refundAmount,
    this.providerRefundId,
    this.resolvedBy,
    this.resolvedAt,
    this.replayed = false,
    this.refundMethod,
    this.manualRefundReference,
    this.manualRefundCompletedBy,
    this.manualRefundCompletedAt,
  });

  final int paymentAttemptId;

  /// OPEN | REFUND_PENDING | REFUNDED | REFUND_FAILED | MANUAL_REFUND_REQUIRED.
  final String state;
  final String provider;
  final double amount;
  final String? currency;
  final String? resolution;
  final String? reasonCode;

  /// REFUND_PAYMENT | MANUAL_REFUND | REFUND_PAYMENT_UNAVAILABLE.
  final String? recommendedAction;
  final String? providerReference;
  final String? refundStatus;
  final double? refundAmount;
  final String? providerRefundId;
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final bool replayed;

  /// Phase 8: PROVIDER (confirmed by the provider) | MANUAL (a manager
  /// recorded the refund slip reference — never a provider confirmation).
  final String? refundMethod;
  final String? manualRefundReference;
  final String? manualRefundCompletedBy;
  final DateTime? manualRefundCompletedAt;

  bool get isManualRefund => refundMethod == 'MANUAL';

  static PaymentExceptionView? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['payment_attempt_id']);
    final state = asString(m?['state']);
    if (m == null || id == null || state == null) return null;
    final refund = asMap(m['refund']);
    final manual = asMap(m['manual_refund']);
    return PaymentExceptionView(
      paymentAttemptId: id,
      state: state,
      provider: asString(m['provider']) ?? '',
      amount: asDouble(m['amount']) ?? 0,
      currency: asString(m['currency']),
      resolution: asString(m['resolution']),
      reasonCode: asString(m['reason_code']),
      recommendedAction: asString(m['recommended_action']),
      providerReference: asString(m['provider_reference']),
      refundStatus: asString(refund?['status']),
      refundAmount: asDouble(refund?['amount']),
      providerRefundId: asString(refund?['provider_refund_id']),
      resolvedBy: asString(m['resolved_by']),
      resolvedAt: DateTime.tryParse(asString(m['resolved_at']) ?? ''),
      replayed: asBool(m['replayed']) ?? false,
      refundMethod: asString(m['refund_method']),
      manualRefundReference: asString(manual?['reference']),
      manualRefundCompletedBy: asString(manual?['completed_by']),
      manualRefundCompletedAt: DateTime.tryParse(
        asString(manual?['completed_at']) ?? '',
      ),
    );
  }
}

/// `POST /payment-exceptions/:attemptId/...` — the server enforces the
/// permission (payments.resolve_captured_exception), the four-eyes rule, the
/// fixed FULL amount and idempotency; the app never names an amount.
abstract class PaymentExceptionService {
  /// Provider refund (e.g. Razorpay) of the captured payment, in full.
  Future<PaymentExceptionView> refund(int attemptId, {String? note});

  /// No refund API (e.g. Pine Labs): an acknowledged manual-refund flag.
  Future<PaymentExceptionView> flagManualRefund(int attemptId, {String? note});

  /// REFUND_PENDING: ask again (same provider idempotency key).
  Future<PaymentExceptionView> checkRefund(int attemptId);

  /// REFUND_FAILED (definitive): a new refund request.
  Future<PaymentExceptionView> retryRefund(int attemptId);

  /// Phase 8 — MANUAL_REFUND_REQUIRED (Pine Labs): after refunding through
  /// the Pine Labs / manual procedure, record the refund slip [reference].
  /// Manager-confirmed; the POS never calls Pine Labs.
  Future<PaymentExceptionView> completeManualRefund(
    int attemptId, {
    required String reference,
    String? note,
  });
}

/// The server refuses any refund until it has itself seen the payment
/// CAPTURED; the app must then check the payment (not retry the refund).
const captureStatusUnknownCode = 'POS_PAYMENT_CAPTURE_STATUS_UNKNOWN';

/// Same rules as the server: 1–64 characters, letters / digits / space and
/// `. _ : # / -`, starting with a letter or digit — and never a card number
/// (13–19 digits passing the Luhn check). Returns the trimmed reference or
/// null.
String? validManualRefundReference(String raw) {
  final ref = raw.trim();
  if (ref.isEmpty || ref.length > 64) return null;
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._:#/-]*$').hasMatch(ref)) return null;
  final digits = ref.replaceAll(RegExp(r'[ -]'), '');
  if (RegExp(r'^\d{13,19}$').hasMatch(digits) && _luhn(digits)) return null;
  return ref;
}

bool _luhn(String d) {
  var sum = 0;
  for (var i = 0; i < d.length; i++) {
    var n = int.parse(d[d.length - 1 - i]);
    if (i.isOdd) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
  }
  return sum % 10 == 0;
}

class ApiPaymentExceptionService implements PaymentExceptionService {
  ApiPaymentExceptionService(this._client);
  final PosApiClient _client;

  PaymentExceptionView _parse(Object? data) {
    final v = PaymentExceptionView.fromJson(data);
    if (v == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return v;
  }

  @override
  Future<PaymentExceptionView> refund(int attemptId, {String? note}) async =>
      _parse(
        await _client.post(
          '/payment-exceptions/$attemptId/refund',
          body: {'confirm': true, 'note': ?note},
        ),
      );

  @override
  Future<PaymentExceptionView> flagManualRefund(
    int attemptId, {
    String? note,
  }) async => _parse(
    await _client.post(
      '/payment-exceptions/$attemptId/manual-refund',
      body: {'acknowledged': true, 'note': ?note},
    ),
  );

  @override
  Future<PaymentExceptionView> checkRefund(int attemptId) async =>
      _parse(await _client.post('/payment-exceptions/$attemptId/refund/check'));

  @override
  Future<PaymentExceptionView> completeManualRefund(
    int attemptId, {
    required String reference,
    String? note,
  }) async => _parse(
    await _client.post(
      '/payment-exceptions/$attemptId/manual-refund/complete',
      body: {'confirm': true, 'refund_reference': reference, 'note': ?note},
    ),
  );

  @override
  Future<PaymentExceptionView> retryRefund(int attemptId) async => _parse(
    await _client.post(
      '/payment-exceptions/$attemptId/refund/retry',
      body: {'confirm': true},
    ),
  );
}
