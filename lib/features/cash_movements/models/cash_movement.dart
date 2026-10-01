import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// A single cash-drawer movement (`WITHDRAWAL` only today) — the server's
/// immutable record from `POST /shifts/cash-withdrawal` or
/// `GET /shifts/current/cash-movements`.
class CashMovement {
  const CashMovement({
    required this.id,
    required this.amount,
    required this.reason,
    required this.status,
    required this.shiftId,
    this.createdAt,
  });

  final int id;
  final double amount;
  final String? reason;
  final String status;
  final int shiftId;
  final DateTime? createdAt;

  static CashMovement? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final amount = asDouble(m['amount']);
    final status = asString(m['status']);
    final shiftId = asInt(m['shift_id']);
    if (id == null || amount == null || status == null || shiftId == null) {
      return null;
    }
    return CashMovement(
      id: id,
      amount: amount,
      reason: asString(m['reason']),
      status: status,
      shiftId: shiftId,
      createdAt: parseServerTime(m['created_at']),
    );
  }
}

/// The current open shift's summary, as returned alongside its withdrawals
/// by `GET /shifts/current/cash-movements` — `null` when no shift is open.
class CurrentShiftSummary {
  const CurrentShiftSummary({
    required this.id,
    required this.status,
    required this.openingAmount,
    this.openedAt,
  });

  final int id;
  final String status;
  final double openingAmount;
  final DateTime? openedAt;

  static CurrentShiftSummary? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final status = asString(m['status']);
    final openingAmount = asDouble(m['opening_amount']);
    if (id == null || status == null || openingAmount == null) return null;
    return CurrentShiftSummary(
      id: id,
      status: status,
      openingAmount: openingAmount,
      openedAt: parseServerTime(m['opened_at']),
    );
  }
}

/// `GET /shifts/current/cash-movements`'s full response: the shift (or
/// `null` if none is open) plus its withdrawals, newest-first.
class CurrentShiftCashMovements {
  const CurrentShiftCashMovements({required this.shift, required this.movements});

  final CurrentShiftSummary? shift;
  final List<CashMovement> movements;

  static CurrentShiftCashMovements fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return const CurrentShiftCashMovements(shift: null, movements: []);
    return CurrentShiftCashMovements(
      shift: CurrentShiftSummary.fromJson(m['shift']),
      movements: asList(
        m['movements'],
      ).map(CashMovement.fromJson).whereType<CashMovement>().toList(),
    );
  }
}
