import '../../../core/utils/json_read.dart';

/// The part of a refund returned through the payment provider that took the
/// money (e.g. a Razorpay UPI QR payment), with the provider's status. The
/// server decides the status; the till only displays it.
enum ProviderRefundStatus {
  pending,
  succeeded,
  failed,
  unknown;

  static ProviderRefundStatus fromWire(String? s) => switch (s) {
    'PENDING' => pending,
    'SUCCEEDED' => succeeded,
    'FAILED' => failed,
    _ => unknown,
  };
}

class ProviderRefund {
  const ProviderRefund({
    required this.id,
    required this.provider,
    required this.amount,
    required this.status,
    this.currency,
    this.failureMessage,
  });

  final int id;
  final String provider;
  final double amount;
  final String? currency;
  final ProviderRefundStatus status;
  final String? failureMessage;

  String get providerLabel => switch (provider) {
    'RAZORPAY' => 'UPI (Razorpay)',
    _ => provider,
  };

  /// Cashier-facing status line.
  String get statusText => switch (status) {
    ProviderRefundStatus.succeeded => 'Refunded to the customer',
    ProviderRefundStatus.pending => 'Refund pending with the payment provider',
    ProviderRefundStatus.failed =>
      'Provider refund failed — return this amount another way',
    ProviderRefundStatus.unknown => 'Refund status unknown',
  };

  static ProviderRefund? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final provider = asString(m['provider']);
    final amount = asDouble(m['amount']);
    if (id == null || provider == null || amount == null) return null;
    return ProviderRefund(
      id: id,
      provider: provider,
      amount: amount,
      currency: asString(m['currency']),
      status: ProviderRefundStatus.fromWire(asString(m['status'])),
      failureMessage: asString(m['failure_message']),
    );
  }
}
