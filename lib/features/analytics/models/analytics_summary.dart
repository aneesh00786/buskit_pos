import '../../../core/utils/json_read.dart';

/// One payment method's total for today (`GET /analytics/summary`).
class PaymentBreakdown {
  const PaymentBreakdown({
    required this.method,
    required this.count,
    required this.amount,
  });
  final String method;
  final int count;
  final double amount;

  static PaymentBreakdown? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final method = asString(m['method']);
    if (method == null) return null;
    return PaymentBreakdown(
      method: method,
      count: asInt(m['count']) ?? 0,
      amount: asDouble(m['amount']) ?? 0,
    );
  }
}

/// One product's sales over the last 7 days.
class TopProduct {
  const TopProduct({
    required this.productVariationId,
    this.productName,
    required this.quantitySold,
    required this.revenue,
    this.refundedQuantity = 0,
    this.netQuantity,
    this.netRevenue,
  });
  final int productVariationId;
  final String? productName;

  /// Gross figures (as before).
  final double quantitySold;
  final double revenue;

  /// C4.x: net of refunds recorded against those sales (server-computed).
  /// Absent from older backends — then the gross figures are shown.
  final double refundedQuantity;
  final double? netQuantity;
  final double? netRevenue;
  double get displayQuantity => netQuantity ?? quantitySold;
  double get displayRevenue => netRevenue ?? revenue;

  static TopProduct? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['product_variation_id']);
    if (id == null) return null;
    return TopProduct(
      productVariationId: id,
      productName: asString(m['product_name']),
      quantitySold: asDouble(m['quantity_sold']) ?? 0,
      revenue: asDouble(m['revenue']) ?? 0,
      refundedQuantity: asDouble(m['refunded_quantity']) ?? 0,
      netQuantity: asDouble(m['net_quantity']),
      netRevenue: asDouble(m['net_revenue']),
    );
  }
}

/// One cashier's totals for the period.
class StaffStat {
  const StaffStat({
    required this.salesmanId,
    this.fullname,
    required this.transactionCount,
    required this.salesTotal,
    this.refundedTotal = 0,
    this.netSalesTotal,
  });
  final String salesmanId;
  final String? fullname;
  final int transactionCount;

  /// Gross completed sales (as before).
  final double salesTotal;

  /// C4.x: refunds recorded against this cashier's sales, and the net.
  final double refundedTotal;
  final double? netSalesTotal;
  double get displayTotal => netSalesTotal ?? salesTotal;

  static StaffStat? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asString(m['salesman_id']);
    if (id == null) return null;
    return StaffStat(
      salesmanId: id,
      fullname: asString(m['fullname']),
      transactionCount: asInt(m['transaction_count']) ?? 0,
      salesTotal: asDouble(m['sales_total']) ?? 0,
      refundedTotal: asDouble(m['refunded_total']) ?? 0,
      netSalesTotal: asDouble(m['net_sales_total']),
    );
  }
}

/// A refund total for one method (`refund_payouts`), wallet included.
class MethodAmount {
  const MethodAmount({required this.method, required this.amount});
  final String method;
  final double amount;

  static MethodAmount? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final method = asString(m['method']);
    if (method == null) return null;
    return MethodAmount(method: method, amount: asDouble(m['amount']) ?? 0);
  }
}

/// Phase C4 sales figures (`sales`): gross of sales completed in the period,
/// refunds issued in the period, and the server's net. Flutter never derives
/// these itself.
class SalesTotals {
  const SalesTotals({
    required this.completedCount,
    required this.grossSales,
    required this.refundsTotal,
    required this.netSales,
    this.fullRefundCount = 0,
    this.partialRefundCount = 0,
    this.fullyRefundedSales = 0,
    this.partiallyRefundedSales = 0,
  });

  final int completedCount;
  final double grossSales;
  final double refundsTotal;
  final double netSales;
  final int fullRefundCount;
  final int partialRefundCount;
  final int fullyRefundedSales;
  final int partiallyRefundedSales;

  int get refundCount => fullRefundCount + partialRefundCount;
}

/// Cash drawer deposits/withdrawals for the period — never sales revenue.
class CashMovementTotals {
  const CashMovementTotals({this.deposits = 0, this.withdrawals = 0, this.depositCount = 0, this.withdrawalCount = 0});
  final double deposits;
  final double withdrawals;
  final int depositCount;
  final int withdrawalCount;

  bool get isEmpty => depositCount == 0 && withdrawalCount == 0;
}

/// `GET /analytics/summary` — every figure is computed server-side from
/// POS's own sales tables (store-scoped); Flutter never calculates a total.
/// There is deliberately no "inventory alerts" field — that data isn't in
/// POS's own tables (stock lives outside pos_sales/pos_sale_items/
/// pos_sale_payments), so it isn't invented here.
class AnalyticsSummary {
  const AnalyticsSummary({
    required this.todayTransactionCount,
    required this.todaySalesTotal,
    required this.paymentBreakdown,
    required this.topProducts,
    required this.staffPerformance,
    required this.sales,
    this.refundPayouts = const [],
    this.cashMovements = const CashMovementTotals(),
    this.periodFrom,
    this.periodTo,
    this.timezone,
    this.topProductsFrom,
    this.topProductsTo,
  });

  /// C4.x: the business dates covered (store time zone) and that zone.
  final String? periodFrom;
  final String? periodTo;
  final String? timezone;

  /// The dates the top-products list covers (7 days by default).
  final String? topProductsFrom;
  final String? topProductsTo;

  /// Gross/refunds/net (Phase C4). Against an older backend without `sales`
  /// this falls back to the gross figure with no refunds.
  final SalesTotals sales;
  final List<MethodAmount> refundPayouts;
  final CashMovementTotals cashMovements;

  final int todayTransactionCount;
  final double todaySalesTotal;
  final List<PaymentBreakdown> paymentBreakdown;
  final List<TopProduct> topProducts;
  final List<StaffStat> staffPerformance;

  static AnalyticsSummary? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final today = asMap(m['today']) ?? const <String, dynamic>{};
    final sales = asMap(m['sales']);
    final cash = asMap(m['cash_movements']);
    final period = asMap(m['period']);
    final topPeriod = asMap(m['top_products_period']);
    final legacyCount = asInt(today['transaction_count']) ?? 0;
    final legacyGross = asDouble(today['sales_total']) ?? 0;
    return AnalyticsSummary(
      periodFrom: asString(period?['from']),
      periodTo: asString(period?['to']),
      timezone: asString(period?['timezone']),
      topProductsFrom: asString(topPeriod?['from']),
      topProductsTo: asString(topPeriod?['to']),
      sales: sales == null
          ? SalesTotals(completedCount: legacyCount, grossSales: legacyGross, refundsTotal: 0, netSales: legacyGross)
          : SalesTotals(
              completedCount: asInt(sales['completed_count']) ?? legacyCount,
              grossSales: asDouble(sales['gross_sales']) ?? legacyGross,
              refundsTotal: asDouble(sales['refunds_total']) ?? 0,
              netSales: asDouble(sales['net_sales']) ?? legacyGross,
              fullRefundCount: asInt(sales['full_refund_count']) ?? 0,
              partialRefundCount: asInt(sales['partial_refund_count']) ?? 0,
              fullyRefundedSales: asInt(sales['fully_refunded_sales']) ?? 0,
              partiallyRefundedSales: asInt(sales['partially_refunded_sales']) ?? 0,
            ),
      refundPayouts: asList(m['refund_payouts']).map(MethodAmount.fromJson).whereType<MethodAmount>().toList(),
      cashMovements: cash == null
          ? const CashMovementTotals()
          : CashMovementTotals(
              deposits: asDouble(cash['deposits']) ?? 0,
              withdrawals: asDouble(cash['withdrawals']) ?? 0,
              depositCount: asInt(cash['deposit_count']) ?? 0,
              withdrawalCount: asInt(cash['withdrawal_count']) ?? 0,
            ),
      todayTransactionCount: asInt(today['transaction_count']) ?? 0,
      todaySalesTotal: asDouble(today['sales_total']) ?? 0,
      paymentBreakdown: asList(m['payment_breakdown'])
          .map(PaymentBreakdown.fromJson)
          .whereType<PaymentBreakdown>()
          .toList(),
      topProducts: asList(m['top_products'])
          .map(TopProduct.fromJson)
          .whereType<TopProduct>()
          .toList(),
      staffPerformance: asList(m['staff_performance'])
          .map(StaffStat.fromJson)
          .whereType<StaffStat>()
          .toList(),
    );
  }
}
