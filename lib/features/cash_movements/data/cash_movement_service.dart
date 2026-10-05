import '../../../core/network/pos_api_client.dart';
import '../models/cash_movement.dart';

abstract class CashMovementService {
  Future<CashMovement?> withdraw({
    required String amount,
    String? reason,
    required String idempotencyKey,
  });

  Future<CashMovement?> deposit({
    required String amount,
    String? reason,
    required String idempotencyKey,
  });

  Future<CurrentShiftCashMovements> listCurrentShift();
}

class ApiCashMovementService implements CashMovementService {
  ApiCashMovementService(this._client);
  final PosApiClient _client;

  @override
  Future<CashMovement?> withdraw({
    required String amount,
    String? reason,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/shifts/cash-withdrawal',
      body: {
        'amount': amount,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        'idempotency_key': idempotencyKey,
      },
    );
    return CashMovement.fromJson(data);
  }

  @override
  Future<CashMovement?> deposit({
    required String amount,
    String? reason,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/shifts/cash-deposit',
      body: {
        'amount': amount,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        'idempotency_key': idempotencyKey,
      },
    );
    return CashMovement.fromJson(data);
  }

  @override
  Future<CurrentShiftCashMovements> listCurrentShift() async {
    final data = await _client.get('/shifts/current/cash-movements');
    return CurrentShiftCashMovements.fromJson(data);
  }
}
