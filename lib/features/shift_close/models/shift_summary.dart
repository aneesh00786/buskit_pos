import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// One payment method's takings for the shift, as summed by the server.
class ShiftPaymentLine {
  const ShiftPaymentLine({
    required this.method,
    required this.count,
    required this.amount,
  });

  final String method;
  final int count;
  final double amount;

  static ShiftPaymentLine? fromJson(Object? json) {
    final m = asMap(json);
    final method = asString(m?['method']);
    if (m == null || method == null) return null;
    return ShiftPaymentLine(
      method: method,
      count: asInt(m['count']) ?? 0,
      amount: asDouble(m['amount']) ?? 0,
    );
  }
}

/// The drawer reconciliation computed by the server. [counted] and
/// [variance] are present only on the result of a close.
class ShiftCash {
  const ShiftCash({
    required this.opening,
    required this.cashSales,
    required this.cashRefunds,
    required this.deposits,
    required this.withdrawals,
    required this.expected,
    this.counted,
    this.variance,
  });

  final double opening;
  final double cashSales;
  final double cashRefunds;
  final double deposits;
  final double withdrawals;
  final double expected;
  final double? counted;
  final double? variance;

  static ShiftCash fromJson(Object? json) {
    final m = asMap(json) ?? const {};
    return ShiftCash(
      opening: asDouble(m['opening']) ?? 0,
      cashSales: asDouble(m['cash_sales']) ?? 0,
      cashRefunds: asDouble(m['cash_refunds']) ?? 0,
      deposits: asDouble(m['deposits']) ?? 0,
      withdrawals: asDouble(m['withdrawals']) ?? 0,
      expected: asDouble(m['expected']) ?? 0,
      counted: asDouble(m['counted']),
      variance: asDouble(m['variance']),
    );
  }
}

/// `GET /shifts/current/summary` (and the `summary` of a close response):
/// the server's authoritative totals for one shift. Display only — the app
/// never recomputes these figures.
class ShiftSummary {
  const ShiftSummary({
    required this.shiftId,
    required this.status,
    this.registerCode,
    this.registerName,
    this.openedBy,
    this.openedAt,
    this.closedAt,
    required this.salesCount,
    required this.salesTotal,
    required this.refundsCount,
    required this.refundsTotal,
    required this.voidsCount,
    required this.voidsTotal,
    required this.payments,
    required this.cash,
    required this.closableByCurrentStaff,
  });

  final int shiftId;
  final String status;
  final String? registerCode;
  final String? registerName;
  final String? openedBy;
  final DateTime? openedAt;
  final DateTime? closedAt;
  final int salesCount;
  final double salesTotal;
  final int refundsCount;
  final double refundsTotal;
  final int voidsCount;
  final double voidsTotal;
  final List<ShiftPaymentLine> payments;
  final ShiftCash cash;

  /// Server-decided: the shift is open and the signed-in staff member opened
  /// it (only they may close it).
  final bool closableByCurrentStaff;

  bool get isOpen => status == 'open';

  String get registerLabel =>
      registerName ?? registerCode ?? 'Register';

  static ShiftSummary? fromJson(Object? json) {
    final m = asMap(json);
    final shift = asMap(m?['shift']);
    final id = asInt(shift?['id']);
    if (m == null || shift == null || id == null) return null;
    final sales = asMap(m['sales']) ?? const {};
    return ShiftSummary(
      shiftId: id,
      status: asString(shift['status']) ?? 'open',
      registerCode: asString(shift['register_code']),
      registerName: asString(shift['register_name']),
      openedBy: asString(shift['opened_by']),
      openedAt: parseServerTime(shift['opened_at']),
      closedAt: parseServerTime(shift['closed_at']),
      salesCount: asInt(sales['count']) ?? 0,
      salesTotal: asDouble(sales['total']) ?? 0,
      refundsCount: asInt(sales['refunds_count']) ?? 0,
      refundsTotal: asDouble(sales['refunds_total']) ?? 0,
      voidsCount: asInt(sales['voids_count']) ?? 0,
      voidsTotal: asDouble(sales['voids_total']) ?? 0,
      payments: asList(m['payments'])
          .map(ShiftPaymentLine.fromJson)
          .whereType<ShiftPaymentLine>()
          .toList(),
      cash: ShiftCash.fromJson(m['cash']),
      closableByCurrentStaff: asBool(m['closable_by_current_staff']) ?? false,
    );
  }
}
