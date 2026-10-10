import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/money.dart';
import '../../cart/models/cart_sale.dart';
import '../models/payment.dart';
import '../models/terminal_payment.dart';

/// Recovery state of an unfinished sale (server-decided, from the existing
/// provider-neutral attempt statuses — see buskit-web
/// services/pos/payments/posPaymentRecoveryService.js).
enum RecoveryState {
  captured('PAYMENT_CAPTURED'),
  authorized('PAYMENT_AUTHORIZED'),
  pending('PAYMENT_PENDING'),
  failed('PAYMENT_FAILED'),
  cancelled('PAYMENT_CANCELLED'),
  noPayment('DRAFT_WITH_NO_PAYMENT');

  const RecoveryState(this.wire);
  final String wire;

  static RecoveryState? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }

  String get label => switch (this) {
    captured => 'Payment captured',
    authorized => 'Payment authorized',
    pending => 'Payment pending',
    failed => 'Payment failed',
    cancelled => 'Payment cancelled',
    noPayment => 'No payment taken',
  };
}

/// One attempt as recovery shows it (the existing attempt view plus what the
/// provider still allows).
class RecoveryAttempt {
  const RecoveryAttempt({
    required this.attempt,
    required this.method,
    this.cancellable = false,
    this.refreshError,
  });
  final PaymentAttempt attempt;

  /// Server method: CARD | QR | ...
  final String method;
  final bool cancellable;

  /// The provider could not be reached on the last check (state unchanged).
  final String? refreshError;

  /// Phase 18B.18 — the server says this OPEN attempt's provider reference is
  /// recorded but not attached yet: a manager must attach it before the
  /// payment can be checked or cancelled at the provider. Nothing about the
  /// payment's outcome follows from this.
  bool get referenceRecordedUnattached =>
      attempt.status.isOpen &&
      !attempt.hasProviderReference &&
      attempt.referenceStatus == ProviderReferenceStatus.recordedUnattached;

  /// Same attempt with the server's current view (Phase 18B.18).
  RecoveryAttempt withAttempt(PaymentAttempt latest) =>
      RecoveryAttempt(attempt: latest, method: method, cancellable: cancellable, refreshError: refreshError);

  static RecoveryAttempt? fromJson(Object? json) {
    final a = PaymentAttempt.fromJson(json);
    final m = asMap(json);
    if (a == null || m == null) return null;
    return RecoveryAttempt(
      attempt: a,
      method: asString(m['method']) ?? '',
      cancellable: asBool(m['cancellable']) ?? false,
      refreshError: asString(m['refresh_error']),
    );
  }
}

/// Phase 7: the captured-payment exception of a draft that cannot complete,
/// with what the SIGNED-IN staff member may do (the server re-checks).
class RecoveryExceptionInfo {
  const RecoveryExceptionInfo({
    required this.paymentAttemptId,
    required this.state,
    this.resolution,
    this.resolvedBy,
    this.recommendedAction,
    this.viewerCanAct = false,
    this.viewerBlockReason,
    this.provider,
    this.originalCashier,
    this.capturedAt,
  });
  final int paymentAttemptId;

  /// OPEN | REFUND_PENDING | REFUNDED | REFUND_FAILED | MANUAL_REFUND_REQUIRED.
  final String state;
  final String? resolution;
  final String? resolvedBy;

  /// REFUND_PAYMENT | MANUAL_REFUND.
  final String? recommendedAction;
  final bool viewerCanAct;

  /// SELF_RESOLUTION | PERMISSION.
  final String? viewerBlockReason;

  /// Phase 8: context for the manual (Pine Labs) refund close-out screen.
  final String? provider;
  final String? originalCashier;
  final DateTime? capturedAt;

  static RecoveryExceptionInfo? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['payment_attempt_id']);
    final state = asString(m?['state']);
    if (m == null || id == null || state == null) return null;
    return RecoveryExceptionInfo(
      paymentAttemptId: id,
      state: state,
      resolution: asString(m['resolution']),
      resolvedBy: asString(m['resolved_by']),
      recommendedAction: asString(m['recommended_action']),
      viewerCanAct: asBool(m['viewer_can_act']) ?? false,
      viewerBlockReason: asString(m['viewer_block_reason']),
      provider: asString(m['provider']),
      originalCashier: asString(m['original_cashier']),
      capturedAt: DateTime.tryParse(asString(m['captured_at']) ?? ''),
    );
  }
}

/// A draft of THIS device the app can resume after a restart.
class RecoverableSale {
  const RecoverableSale({
    required this.saleId,
    required this.state,
    required this.sale,
    required this.attempts,
    required this.canComplete,
    required this.nextAction,
    required this.completionPayments,
    this.saleNumber,
    this.createdAt,
    this.blockedReason,
    this.currentShift = true,
    this.exception,
  });

  final int saleId;
  final String? saleNumber;
  final DateTime? createdAt;
  final RecoveryState state;

  /// The live draft (items, server-computed totals) — the cart it restores.
  final CartSale sale;
  final List<RecoveryAttempt> attempts;
  final bool canComplete;

  /// COMPLETE_SALE | CHECK_PAYMENT | RETRY_PAYMENT | RESTORE_CART |
  /// CONTACT_MANAGER.
  final String nextAction;

  /// SHIFT_NOT_CURRENT | UNAVAILABLE_ITEMS | PAYMENT_STILL_OPEN |
  /// CAPTURED_AMOUNT_DIFFERS | STOCK_CONFLICT | AMOUNT_MISMATCH |
  /// PRODUCT_UNAVAILABLE | BUSINESS_RULE | CHECK_FAILED.
  final String? blockedReason;

  /// Phase 7: present when the payment is captured but the sale cannot be
  /// completed (a captured-payment exception).
  final RecoveryExceptionInfo? exception;
  final bool currentShift;

  /// Exactly the tenders completing this sale must carry (one per captured
  /// attempt) — never typed by the cashier, never a new payment.
  final List<PaymentLine> completionPayments;

  String get reference => saleNumber ?? 'Draft #$saleId';

  /// Same sale with updated attempts (Phase 18B.18).
  RecoverableSale withAttempts(List<RecoveryAttempt> next) => RecoverableSale(
    saleId: saleId,
    state: state,
    sale: sale,
    attempts: next,
    canComplete: canComplete,
    nextAction: nextAction,
    completionPayments: completionPayments,
    saleNumber: saleNumber,
    createdAt: createdAt,
    blockedReason: blockedReason,
    currentShift: currentShift,
    exception: exception,
  );

  static RecoverableSale? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['sale_id']);
    final state = RecoveryState.fromWire(asString(m?['recovery_state']));
    final sale = CartSale.fromJson(m?['sale']);
    if (m == null || id == null || state == null || sale == null) return null;
    final payments = <PaymentLine>[];
    for (final p in asList(m['completion_payments'])) {
      final pm = asMap(p);
      final method = TenderMethod.fromWire(asString(pm?['method']));
      final amount = asDouble(pm?['amount']);
      final attemptId = asInt(pm?['payment_attempt_id']);
      if (method == null || amount == null || attemptId == null) return null;
      payments.add(
        PaymentLine(
          method: method,
          amountMilli: milliFromDouble(amount),
          paymentAttemptId: attemptId,
        ),
      );
    }
    return RecoverableSale(
      saleId: id,
      saleNumber: asString(m['sale_number']),
      createdAt: DateTime.tryParse(asString(m['created_at']) ?? ''),
      state: state,
      sale: sale,
      attempts: asList(m['payment_attempts'])
          .map(RecoveryAttempt.fromJson)
          .whereType<RecoveryAttempt>()
          .toList(),
      canComplete: asBool(m['can_complete']) ?? false,
      nextAction: asString(m['next_action']) ?? 'CONTACT_MANAGER',
      blockedReason: asString(m['blocked_reason']),
      currentShift: asBool(m['current_shift']) ?? true,
      completionPayments: payments,
      exception: RecoveryExceptionInfo.fromJson(m['exception']),
    );
  }
}

/// A sale the app remembered from before the restart that is no longer a
/// draft (e.g. completed just before the app died).
class ResolvedSale {
  const ResolvedSale({
    required this.saleId,
    required this.status,
    this.saleNumber,
    this.grandTotal,
  });
  final int saleId;

  /// SALE_COMPLETED | SALE_VOIDED | SALE_CLOSED.
  final String status;
  final String? saleNumber;
  final double? grandTotal;

  bool get completed => status == 'SALE_COMPLETED';

  static ResolvedSale? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['sale_id']);
    final status = asString(m?['status']);
    if (id == null || status == null) return null;
    return ResolvedSale(
      saleId: id,
      status: status,
      saleNumber: asString(m!['sale_number']),
      grandTotal: asDouble(m['grand_total']),
    );
  }
}

class PaymentRecoveryResult {
  const PaymentRecoveryResult({
    this.recoverable = const [],
    this.resolved = const [],
  });
  final List<RecoverableSale> recoverable;
  final List<ResolvedSale> resolved;

  bool get isEmpty => recoverable.isEmpty && resolved.isEmpty;
}

/// `GET /payment-recovery` — this device's unfinished sales after a restart.
/// Read-only; [refresh] asks the provider about OPEN attempts (the same
/// transaction / QR, never a new one); [saleIds] are the app's local
/// reminders of sales it was paying for.
abstract class PaymentRecoveryService {
  Future<PaymentRecoveryResult> fetch({
    bool refresh = false,
    List<int> saleIds = const [],
  });

  /// `POST /payment-attempts/:id/cancel` — confirmed by the provider or not
  /// at all (then the attempt keeps its state).
  Future<void> cancelAttempt(int attemptId);
}

/// Phase 18B.18 — the recovery listing does not carry
/// provider_reference_status; for each OPEN attempt without a provider
/// reference whose status is not known, [lookup] reads the server's current
/// view (GET /payment-attempts/:id, read-only — no provider call). A lookup
/// that fails, or returns another attempt, leaves the attempt as listed
/// (the existing backward-compatible behaviour).
Future<PaymentRecoveryResult> withReferenceStatus(
  PaymentRecoveryResult result,
  Future<PaymentAttempt> Function(int attemptId) lookup,
) async {
  final sales = <RecoverableSale>[];
  for (final s in result.recoverable) {
    final attempts = <RecoveryAttempt>[];
    for (final a in s.attempts) {
      final x = a.attempt;
      if (!x.status.isOpen || x.hasProviderReference || x.referenceStatus != ProviderReferenceStatus.unknown) {
        attempts.add(a);
        continue;
      }
      try {
        final latest = await lookup(x.id);
        attempts.add(latest.id == x.id ? a.withAttempt(latest) : a);
      } on ApiException {
        attempts.add(a);
      }
    }
    sales.add(s.withAttempts(attempts));
  }
  return PaymentRecoveryResult(recoverable: sales, resolved: result.resolved);
}

class ApiPaymentRecoveryService implements PaymentRecoveryService {
  ApiPaymentRecoveryService(this._client);
  final PosApiClient _client;

  @override
  Future<PaymentRecoveryResult> fetch({
    bool refresh = false,
    List<int> saleIds = const [],
  }) async {
    final data = asMap(
      await _client.get(
        '/payment-recovery',
        query: {
          if (refresh) 'refresh': 'true',
          if (saleIds.isNotEmpty) 'sale_ids': saleIds.take(20).join(','),
        },
      ),
    );
    if (data == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    final listed = PaymentRecoveryResult(
      recoverable: asList(data['recoverable'])
          .map(RecoverableSale.fromJson)
          .whereType<RecoverableSale>()
          .toList(),
      resolved: asList(data['resolved'])
          .map(ResolvedSale.fromJson)
          .whereType<ResolvedSale>()
          .toList(),
    );
    return withReferenceStatus(listed, _current);
  }

  Future<PaymentAttempt> _current(int attemptId) async {
    final a = PaymentAttempt.fromJson(await _client.get('/payment-attempts/$attemptId'));
    if (a == null) throw const ApiException(kind: ApiErrorKind.unknown, message: 'Unexpected response from the server.');
    return a;
  }

  @override
  Future<void> cancelAttempt(int attemptId) async {
    await _client.post('/payment-attempts/$attemptId/cancel');
  }
}
