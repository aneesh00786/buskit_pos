import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/shift_summary.dart';

abstract class ShiftCloseService {
  /// `GET /shifts/current/summary` — the shift open on this device's register.
  /// The server decides which shift that is; the app never sends an id here.
  Future<ShiftSummary> currentSummary();

  /// `POST /shifts/:id/close {closing_amount}` — [shiftId] is the id the
  /// server itself returned in [currentSummary]. Returns the server's final
  /// summary (expected, counted and variance).
  ///
  /// Phase 14C-B2: with [denominations] the count is sent too (no currency:
  /// the server applies the shift's store currency, validates the count and
  /// checks it equals [closingAmount]); the returned summary then carries the
  /// stored `cash_count`.
  Future<ShiftSummary> close({
    required int shiftId,
    required double closingAmount,
    List<DenominationCount>? denominations,
  });
}

class ApiShiftCloseService implements ShiftCloseService {
  ApiShiftCloseService(this._client);
  final PosApiClient _client;

  @override
  Future<ShiftSummary> currentSummary() async {
    final data = await _client.get('/shifts/current/summary');
    return _summary(ShiftSummary.fromJson(data));
  }

  @override
  Future<ShiftSummary> close({
    required int shiftId,
    required double closingAmount,
    List<DenominationCount>? denominations,
  }) async {
    final data = await _client.post(
      '/shifts/$shiftId/close',
      body: {
        'closing_amount': closingAmount,
        if (denominations != null && denominations.isNotEmpty)
          'denominations': [for (final d in denominations) d.toJson()],
      },
    );
    final map = data is Map ? data : null;
    return _summary(ShiftSummary.fromJson(map?['summary']))
        .withCashCount(ShiftCashCount.fromJson(map?['cash_count']));
  }

  ShiftSummary _summary(ShiftSummary? s) {
    if (s == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return s;
  }
}
