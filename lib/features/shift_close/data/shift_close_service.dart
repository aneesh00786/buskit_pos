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
  Future<ShiftSummary> close({
    required int shiftId,
    required double closingAmount,
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
  }) async {
    final data = await _client.post(
      '/shifts/$shiftId/close',
      body: {'closing_amount': closingAmount},
    );
    final map = data is Map ? data : null;
    return _summary(ShiftSummary.fromJson(map?['summary']));
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
