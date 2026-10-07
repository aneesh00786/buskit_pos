import '../../../core/network/pos_api_client.dart';

/// Phase 14A — records a manual "open drawer / no sale" on the server
/// (`POST /drawer/no-sale`, permission `payments.cash_drawer`). The server
/// takes staff / device / register / store / shift from the session; this
/// sends only the idempotency key and an optional reason. It creates no
/// sale, payment, stock or cash movement.
abstract class NoSaleService {
  Future<void> recordNoSale({required String idempotencyKey, String? reason});
}

class ApiNoSaleService implements NoSaleService {
  ApiNoSaleService(this._client);
  final PosApiClient _client;

  @override
  Future<void> recordNoSale({
    required String idempotencyKey,
    String? reason,
  }) async {
    await _client.post(
      '/drawer/no-sale',
      body: {
        'idempotency_key': idempotencyKey,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
  }
}
