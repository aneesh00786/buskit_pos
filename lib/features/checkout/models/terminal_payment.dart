import '../../../core/utils/json_read.dart';

/// A payment provider as the server lists it (`GET /payment-providers`):
/// name, methods and capability flags only — the server never sends
/// configuration or credentials. For card-terminal providers it also says
/// whether THIS register has a terminal configured (display name only).
class PaymentProviderInfo {
  const PaymentProviderInfo({
    required this.name,
    required this.methods,
    required this.cardTerminal,
    required this.statusPolling,
    required this.cancel,
    this.qr = false,
    this.currencies = const [],
    this.terminalConfigured = false,
    this.terminalName,
    this.autoCancelMinutes,
  });

  final String name;
  final List<String> methods;
  final bool cardTerminal;
  final bool statusPolling;
  final bool cancel;

  /// Issues a QR the customer scans (e.g. UPI QR).
  final bool qr;

  /// Currencies the provider accepts (empty = any).
  final List<String> currencies;
  final bool terminalConfigured;
  final String? terminalName;

  /// Phase 18B.3: minutes after which the terminal cancels an unpaid
  /// transaction by itself (server `terminal.auto_cancel_minutes`, the same
  /// value the server sends to the terminal). Null when the server does not
  /// say (older server) — then the server's own default applies.
  final int? autoCancelMinutes;

  /// The server's default (PINE_LABS_AUTO_CANCEL_MINUTES unset).
  static const int defaultAutoCancelMinutes = 5;

  /// Time allowed after the auto-cancel for the terminal's own cancellation
  /// (or a last-moment approval) to be reported back by the server.
  static const Duration autoCancelReportGrace = Duration(seconds: 30);

  /// How long the till waits for a terminal payment before it says the wait
  /// is longer than expected: the terminal's auto-cancel window + the grace.
  Duration get terminalWaitWindow =>
      Duration(minutes: autoCancelMinutes ?? defaultAutoCancelMinutes) + autoCancelReportGrace;

  /// A card terminal this register can actually use right now.
  bool get isUsableCardTerminal =>
      cardTerminal && terminalConfigured && methods.contains('CARD');

  /// A QR provider (no terminal needed).
  bool get isUsableQr => qr && methods.contains('QR');

  String get label => switch (name) {
    'PINE_LABS' => 'Pine Labs',
    'RAZORPAY' => 'Razorpay',
    _ => name,
  };

  static PaymentProviderInfo? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final name = asString(m['name']);
    if (name == null) return null;
    final caps = asMap(m['capabilities']) ?? const {};
    final terminal = asMap(m['terminal']);
    final methods = (m['methods'] is List)
        ? (m['methods'] as List).map(asString).whereType<String>().toList()
        : const <String>[];
    return PaymentProviderInfo(
      name: name,
      methods: methods,
      cardTerminal: caps['cardTerminal'] == true,
      statusPolling: caps['statusPolling'] == true,
      cancel: caps['cancel'] == true,
      qr: caps['qr'] == true,
      currencies: asList(m['currencies']).map(asString).whereType<String>().toList(),
      terminalConfigured: terminal?['configured'] == true,
      terminalName: asString(terminal?['display_name']),
      autoCancelMinutes: switch (asInt(terminal?['auto_cancel_minutes'])) {
        final int m when m > 0 && m <= 120 => m,
        _ => null,
      },
    );
  }
}

/// The EXTERNAL payment's state (server `pos_payment_attempts.status`).
enum AttemptStatus {
  pending,
  authorized,
  captured,
  failed,
  cancelled,
  refunded,
  partiallyRefunded,
  unknown;

  static AttemptStatus fromWire(String? s) => switch (s) {
    'PENDING' => pending,
    'AUTHORIZED' => authorized,
    'CAPTURED' => captured,
    'FAILED' => failed,
    'CANCELLED' => cancelled,
    'REFUNDED' => refunded,
    'PARTIALLY_REFUNDED' => partiallyRefunded,
    _ => unknown,
  };

  bool get isOpen => this == pending || this == authorized;
}

/// Phase 18B.17 — the server's `provider_reference_status` (derived from its
/// database; never set by the till). [unknown] = missing or unrecognised
/// (an older backend): the till then falls back to the server's refusals.
enum ProviderReferenceStatus {
  attached,
  recordedUnattached,
  notRecorded,
  unknown;

  static ProviderReferenceStatus fromWire(Object? v) => switch (v) {
    'ATTACHED' => attached,
    'RECORDED_UNATTACHED' => recordedUnattached,
    'NOT_RECORDED' => notRecorded,
    _ => unknown,
  };
}

/// A provider payment attempt (server view). Only references and neutral
/// texts — never card data.
class PaymentAttempt {
  const PaymentAttempt({
    required this.id,
    required this.status,
    required this.amount,
    this.provider,
    this.currency,
    this.providerReference,
    this.providerPaymentId,
    this.instruction,
    this.failureCode,
    this.failureMessage,
    this.qrImageUrl,
    this.qrPayload,
    this.expiresAt,
    this.unconfirmed = false,
    this.referenceStatus = ProviderReferenceStatus.unknown,
  });

  final int id;
  final AttemptStatus status;
  final double amount;
  final String? provider;
  final String? currency;
  final String? providerReference;

  /// The provider's own id for this payment (Pine Labs PTRID / Razorpay QR
  /// id) once the server has it attached. Phase 18B.15: an attempt that has
  /// one is checked or cancelled through the provider — never abandoned.
  final String? providerPaymentId;
  bool get hasProviderReference =>
      (providerPaymentId != null && providerPaymentId!.isNotEmpty) || referenceStatus == ProviderReferenceStatus.attached;

  /// Phase 18B.17: see [ProviderReferenceStatus].
  final ProviderReferenceStatus referenceStatus;
  final String? instruction;
  final String? failureCode;
  final String? failureMessage;

  /// QR to show the customer: the provider's hosted image (https), and/or a
  /// payload. Never generated by an external service on the till.
  final String? qrImageUrl;
  final String? qrPayload;

  /// When the provider will stop accepting payment (UTC from the server).
  final DateTime? expiresAt;

  /// Closed by the provider at its expiry, without payment.
  bool get isExpired => status == AttemptStatus.cancelled && failureCode == 'EXPIRED';

  /// Phase 18B.1: an open terminal attempt that never got a provider
  /// reference (server decides). Only a manager can end it, by abandoning it
  /// after the terminal's auto-cancel window.
  final bool unconfirmed;

  /// Ended by a manager without the provider's confirmation — NOT proof that
  /// no money was taken.
  bool get isAbandoned => status == AttemptStatus.cancelled && failureCode == 'ABANDONED_UNCONFIRMED';

  static PaymentAttempt? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    if (id == null) return null;
    final action = asMap(m['client_action']);
    final image = asString(action?['image_url']);
    return PaymentAttempt(
      id: id,
      status: AttemptStatus.fromWire(asString(m['status'])),
      amount: asDouble(m['amount']) ?? 0,
      provider: asString(m['provider']),
      currency: asString(m['currency']),
      providerReference: asString(m['provider_reference']),
      providerPaymentId: asString(m['provider_payment_id']),
      instruction: asString(action?['instruction']),
      failureCode: asString(m['failure_code']),
      failureMessage: asString(m['failure_message']),
      qrImageUrl: image != null && image.startsWith('https://') ? image : null,
      qrPayload: asString(action?['qr_payload']),
      expiresAt: DateTime.tryParse(asString(m['expires_at']) ?? '')?.toUtc(),
      unconfirmed: m['unconfirmed'] == true,
      referenceStatus: ProviderReferenceStatus.fromWire(m['provider_reference_status']),
    );
  }
}

/// Phase 18B.1: the server's answer to abandoning an unconfirmed attempt.
class AbandonResult {
  const AbandonResult({required this.attempt, required this.warning});
  final PaymentAttempt attempt;

  /// The server's reconciliation warning, shown to the cashier/manager.
  final String warning;
}
