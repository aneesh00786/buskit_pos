import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../checkout/data/payment_recovery_service.dart';

/// Phase 9 — one captured-payment exception of the CURRENT STORE (any
/// register / device), as `GET /payment-exceptions/store` lists it. The
/// server decides state and what the viewer may do; the app only shows it.
class StoreExceptionItem {
  const StoreExceptionItem({
    required this.paymentAttemptId,
    required this.saleId,
    required this.state,
    required this.provider,
    required this.amount,
    this.currency,
    this.saleNumber,
    this.reasonCode,
    this.originalCashier,
    this.registerId,
    this.registerCode,
    this.createdAt,
    this.capturedAt,
    this.viewerCanAct = false,
    this.viewerBlockReason,
    this.refundMethod,
  });

  final int paymentAttemptId;
  final int saleId;

  /// OPEN | MANUAL_REFUND_REQUIRED | REFUND_PENDING | REFUND_FAILED | REFUNDED.
  final String state;
  final String provider;
  final double amount;
  final String? currency;
  final String? saleNumber;
  final String? reasonCode;
  final String? originalCashier;
  final int? registerId;
  final String? registerCode;
  final DateTime? createdAt;
  final DateTime? capturedAt;
  final bool viewerCanAct;
  final String? viewerBlockReason;
  final String? refundMethod;

  String get saleReference => saleNumber ?? 'Draft #$saleId';

  /// Still needs a manager (or is waiting on the provider).
  bool get unresolved => state != 'REFUNDED';

  static StoreExceptionItem? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['payment_attempt_id']);
    final saleId = asInt(m?['sale_id']);
    final state = asString(m?['state']);
    if (m == null || id == null || saleId == null || state == null) {
      return null;
    }
    return StoreExceptionItem(
      paymentAttemptId: id,
      saleId: saleId,
      state: state,
      provider: asString(m['provider']) ?? '',
      amount: asDouble(m['amount']) ?? 0,
      currency: asString(m['currency']),
      saleNumber: asString(m['sale_number']),
      reasonCode: asString(m['reason_code']),
      originalCashier: asString(m['original_cashier']),
      registerId: asInt(m['register_id']),
      registerCode: asString(m['register_code']),
      createdAt: DateTime.tryParse(asString(m['payment_created_at']) ?? ''),
      capturedAt: DateTime.tryParse(asString(m['captured_at']) ?? ''),
      viewerCanAct: asBool(m['viewer_can_act']) ?? false,
      viewerBlockReason: asString(m['viewer_block_reason']),
      refundMethod: asString(m['refund_method']),
    );
  }
}

class StoreExceptionPage {
  const StoreExceptionPage({this.items = const [], this.nextBeforeId});
  final List<StoreExceptionItem> items;

  /// Keyset cursor for the next (older) page; null = no more.
  final int? nextBeforeId;
}

/// One audit event (pos_payment_exception_events — the same rows the admin
/// portal shows).
class ExceptionEvent {
  const ExceptionEvent({
    required this.action,
    this.actor,
    this.fromStatus,
    this.toStatus,
    this.refundMethod,
    this.refundReference,
    this.providerRefundId,
    this.errorCode,
    this.note,
    this.createdAt,
  });
  final String action;
  final String? actor;
  final String? fromStatus;
  final String? toStatus;
  final String? refundMethod;
  final String? refundReference;
  final String? providerRefundId;
  final String? errorCode;
  final String? note;
  final DateTime? createdAt;

  static ExceptionEvent? fromJson(Object? json) {
    final m = asMap(json);
    final action = asString(m?['action']);
    if (m == null || action == null) return null;
    return ExceptionEvent(
      action: action,
      actor: asString(m['actor_salesman_id']),
      fromStatus: asString(m['from_status']),
      toStatus: asString(m['to_status']),
      refundMethod: asString(m['refund_method']),
      refundReference: asString(m['refund_reference']),
      providerRefundId: asString(m['provider_refund_id']),
      errorCode: asString(m['error_code']),
      note: asString(m['note']),
      createdAt: DateTime.tryParse(asString(m['created_at']) ?? ''),
    );
  }
}

/// `GET /payment-exceptions/store/:attemptId` — one payment of the store:
/// the exception (null when it is not / no longer one), its sale, its
/// payment attempts and the audit events. [sale] is in the recovery shape,
/// so the existing exception dialog (refund / manual close-out, Check
/// Payment) is reused unchanged.
class StoreExceptionDetail {
  const StoreExceptionDetail({
    required this.paymentAttemptId,
    required this.saleId,
    required this.saleStatus,
    required this.paymentStatus,
    required this.isException,
    required this.json,
    this.exceptionState,
    this.registerCode,
    this.sale,
    this.events = const [],
  });

  final int paymentAttemptId;
  final int saleId;
  final String? saleStatus;
  final String? paymentStatus;
  final bool isException;
  final String? exceptionState;
  final String? registerCode;

  /// The sale + attempts + exception as the recovery screen models them
  /// (null if the server sent no sale).
  final RecoverableSale? sale;
  final List<ExceptionEvent> events;

  /// The raw server view (shown fields are read from here).
  final Map<String, dynamic> json;

  Map<String, dynamic>? get exception => asMap(json['exception']);

  static const _recoveryStates = {
    'CAPTURED': 'PAYMENT_CAPTURED',
    'PENDING': 'PAYMENT_PENDING',
    'AUTHORIZED': 'PAYMENT_AUTHORIZED',
    'FAILED': 'PAYMENT_FAILED',
    'CANCELLED': 'PAYMENT_CANCELLED',
  };

  static StoreExceptionDetail? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['payment_attempt_id']);
    final saleId = asInt(m?['sale_id']);
    if (m == null || id == null || saleId == null) return null;
    final ex = asMap(m['exception']);
    final isException = asBool(m['is_exception']) ?? false;
    final paymentStatus = asString(m['payment_status']);
    final sale = RecoverableSale.fromJson({
      'sale_id': saleId,
      'sale_number': asMap(m['sale'])?['sale_number'],
      'created_at': asMap(m['sale'])?['created_at'],
      // The exception only matters for a captured payment; a refunded or
      // open one is shown by its attempt status (no actions offered).
      'recovery_state': _recoveryStates[paymentStatus] ?? 'PAYMENT_CAPTURED',
      'can_complete': false,
      'next_action': 'CONTACT_MANAGER',
      'blocked_reason': ex?['reason_code'],
      'completion_payments': const [],
      'current_shift': false,
      'sale': m['sale'],
      'payment_attempts': m['payment_attempts'],
      'exception': isException && ex != null && ex['state'] != 'REFUNDED'
          ? ex
          : null,
    });
    return StoreExceptionDetail(
      paymentAttemptId: id,
      saleId: saleId,
      saleStatus: asString(m['sale_status']),
      paymentStatus: paymentStatus,
      isException: isException,
      exceptionState: asString(ex?['state']),
      registerCode: asString(m['register_code']),
      sale: sale,
      events: asList(m['events'])
          .map(ExceptionEvent.fromJson)
          .whereType<ExceptionEvent>()
          .toList(),
      json: m,
    );
  }

  /// "Check Payment" for the shared exception dialog: what a refreshed
  /// recovery check of this sale would say, built from this detail.
  PaymentRecoveryResult toRecoveryResult() {
    if (saleStatus == 'completed') {
      return PaymentRecoveryResult(
        resolved: [ResolvedSale(saleId: saleId, status: 'SALE_COMPLETED')],
      );
    }
    final s = sale;
    if (saleStatus == 'draft' && s != null) {
      return PaymentRecoveryResult(recoverable: [s]);
    }
    return PaymentRecoveryResult(
      resolved: [ResolvedSale(saleId: saleId, status: 'SALE_CLOSED')],
    );
  }
}

/// Store-wide exceptions for managers. Viewing needs
/// payments.view_store_exceptions; every action stays on
/// PaymentExceptionService (payments.resolve_captured_exception + the
/// four-eyes rule, server-side).
abstract class StoreExceptionService {
  Future<StoreExceptionPage> list({
    String state = 'UNRESOLVED',
    int? beforeId,
    int limit = 25,
  });

  /// [refresh]: ask the provider about an open payment first.
  Future<StoreExceptionDetail> detail(int attemptId, {bool refresh = false});
}

class ApiStoreExceptionService implements StoreExceptionService {
  ApiStoreExceptionService(this._client);
  final PosApiClient _client;

  static const _unexpected = ApiException(
    kind: ApiErrorKind.unknown,
    message: 'Unexpected response from the server.',
  );

  @override
  Future<StoreExceptionPage> list({
    String state = 'UNRESOLVED',
    int? beforeId,
    int limit = 25,
  }) async {
    final data = asMap(
      await _client.get(
        '/payment-exceptions/store',
        query: {
          'state': state,
          'limit': '$limit',
          if (beforeId != null) 'before_id': '$beforeId',
        },
      ),
    );
    if (data == null) throw _unexpected;
    return StoreExceptionPage(
      items: asList(data['items'])
          .map(StoreExceptionItem.fromJson)
          .whereType<StoreExceptionItem>()
          .toList(),
      nextBeforeId: asInt(data['next_before_id']),
    );
  }

  @override
  Future<StoreExceptionDetail> detail(
    int attemptId, {
    bool refresh = false,
  }) async {
    final d = StoreExceptionDetail.fromJson(
      await _client.get(
        '/payment-exceptions/store/$attemptId',
        query: refresh ? {'refresh': 'true'} : null,
      ),
    );
    if (d == null) throw _unexpected;
    return d;
  }
}
