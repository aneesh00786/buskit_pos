import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/money.dart';
import '../models/terminal_payment.dart';

/// Provider payments (card terminal) through the server's provider-neutral
/// payment-attempt API. The server is authoritative for everything: the
/// terminal (from this register's configuration), the amount check, the
/// currency, and the payment state. The till only asks and polls — it never
/// talks to a payment provider and never holds provider credentials.
/// Shown with every abandoned attempt (the server sends its own wording too).
const abandonWarning =
    'Abandoning does not prove that no money was taken. Check the terminal and the Pine Labs settlement for this payment, and refund the customer if a charge appears.';

abstract class PaymentTerminalService {
  /// `GET /payment-providers`.
  Future<List<PaymentProviderInfo>> listProviders();

  /// `POST /sales/:id/payment-attempts {method, provider, amount,
  /// idempotency_key}` (method CARD for a terminal, QR for a QR provider) —
  /// retrying with the same key returns the same attempt.
  Future<PaymentAttempt> start({
    required int saleId,
    required String provider,
    required int amountMilli,
    required String idempotencyKey,
    String method = 'CARD',
  });

  /// `GET /payment-attempts/:id?refresh=true` — the server asks the provider.
  Future<PaymentAttempt> refresh(int attemptId);

  /// `POST /payment-attempts/:id/cancel` — confirmed by the provider or not at all.
  Future<PaymentAttempt> cancel(int attemptId);

  /// Phase 18B.17 — `GET /payment-attempts/:id` WITHOUT refresh: the server's
  /// current view (incl. provider_reference_status), read-only; the provider
  /// is not asked.
  Future<PaymentAttempt> current(int attemptId);

  /// Phase 18B.1 — `POST /payment-attempts/:id/abandon-unconfirmed {reason}`:
  /// a manager ends a terminal attempt that never got a provider reference,
  /// after the auto-cancel window. The server checks permission and timing.
  Future<AbandonResult> abandonUnconfirmed(int attemptId, String reason);
}

class ApiPaymentTerminalService implements PaymentTerminalService {
  ApiPaymentTerminalService(this._client);
  final PosApiClient _client;

  @override
  Future<List<PaymentProviderInfo>> listProviders() async {
    final data = await _client.get('/payment-providers');
    return asList(data)
        .map(PaymentProviderInfo.fromJson)
        .whereType<PaymentProviderInfo>()
        .toList();
  }

  @override
  Future<PaymentAttempt> start({
    required int saleId,
    required String provider,
    required int amountMilli,
    required String idempotencyKey,
    String method = 'CARD',
  }) async => _parse(
    await _client.post(
      '/sales/$saleId/payment-attempts',
      body: {
        'method': method,
        'provider': provider,
        'amount': milliToJson(amountMilli),
        'idempotency_key': idempotencyKey,
      },
    ),
  );

  @override
  Future<PaymentAttempt> refresh(int attemptId) async => _parse(
    await _client.get(
      '/payment-attempts/$attemptId',
      query: {'refresh': 'true'},
    ),
  );

  @override
  Future<PaymentAttempt> current(int attemptId) async =>
      _parse(await _client.get('/payment-attempts/$attemptId'));

  @override
  Future<PaymentAttempt> cancel(int attemptId) async =>
      _parse(await _client.post('/payment-attempts/$attemptId/cancel'));

  @override
  Future<AbandonResult> abandonUnconfirmed(int attemptId, String reason) async {
    final data = asMap(
      await _client.post(
        '/payment-attempts/$attemptId/abandon-unconfirmed',
        body: {'reason': reason},
      ),
    );
    return AbandonResult(
      attempt: _parse(data?['payment_attempt']),
      warning: asString(data?['warning']) ?? abandonWarning,
    );
  }

  PaymentAttempt _parse(Object? data) {
    final a = PaymentAttempt.fromJson(data);
    if (a == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return a;
  }
}
