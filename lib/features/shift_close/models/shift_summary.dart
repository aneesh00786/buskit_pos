import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';
import 'cash_denominations.dart';

/// Phase 14C-B2 — one counted denomination SENT with a close (value in exact
/// thousandths, whole quantity). The server re-validates and computes.
class DenominationCount {
  const DenominationCount({required this.valueMilli, required this.quantity});
  final int valueMilli;
  final int quantity;

  Map<String, dynamic> toJson() => {
    'value': milliToDecimalText(valueMilli),
    'quantity': quantity,
  };
}

/// Phase 14C-B2 — one stored denomination line of a closed shift's count.
class ShiftCashCountLine {
  const ShiftCashCountLine({
    required this.valueMilli,
    required this.quantity,
    required this.lineMilli,
  });
  final int valueMilli;
  final int quantity;
  final int lineMilli;
}

/// Phase 14C-B2 — the server's stored cash count (`cash_count`) of a closed
/// shift: currency, counted cash and the denomination lines. Display only.
class ShiftCashCount {
  const ShiftCashCount({
    required this.currency,
    required this.countedMilli,
    required this.lines,
  });
  final String currency;
  final int countedMilli;
  final List<ShiftCashCountLine> lines;

  static int _milli(Object? v) => ((asDouble(v) ?? 0) * 1000).round();

  static ShiftCashCount? fromJson(Object? json) {
    final m = asMap(json);
    final lines = asList(m?['denominations']);
    if (m == null || lines.isEmpty) return null;
    return ShiftCashCount(
      currency: asString(m['currency']) ?? '',
      countedMilli: _milli(m['counted']),
      lines: [
        for (final l in lines.map(asMap).whereType<Map<String, dynamic>>())
          ShiftCashCountLine(
            valueMilli: _milli(l['value']),
            quantity: asInt(l['quantity']) ?? 0,
            lineMilli: _milli(l['line_total']),
          ),
      ],
    );
  }
}

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
    this.storeId,
    this.cashCount,
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
  final int? storeId;

  /// Phase 14C-B2: the stored denomination count of a CLOSED shift (null when
  /// none was given, or for shifts closed before cash counts existed).
  final ShiftCashCount? cashCount;
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

  ShiftSummary withCashCount(ShiftCashCount? count) => ShiftSummary(
    shiftId: shiftId,
    status: status,
    storeId: storeId,
    cashCount: count,
    registerCode: registerCode,
    registerName: registerName,
    openedBy: openedBy,
    openedAt: openedAt,
    closedAt: closedAt,
    salesCount: salesCount,
    salesTotal: salesTotal,
    refundsCount: refundsCount,
    refundsTotal: refundsTotal,
    voidsCount: voidsCount,
    voidsTotal: voidsTotal,
    payments: payments,
    cash: cash,
    closableByCurrentStaff: closableByCurrentStaff,
  );

  static ShiftSummary? fromJson(Object? json) {
    final m = asMap(json);
    final shift = asMap(m?['shift']);
    final id = asInt(shift?['id']);
    if (m == null || shift == null || id == null) return null;
    final sales = asMap(m['sales']) ?? const {};
    return ShiftSummary(
      shiftId: id,
      status: asString(shift['status']) ?? 'open',
      storeId: asInt(shift['store_id']),
      cashCount: ShiftCashCount.fromJson(m['cash_count']),
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
