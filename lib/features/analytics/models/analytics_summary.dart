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
  });
  final int productVariationId;
  final String? productName;
  final double quantitySold;
  final double revenue;

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
    );
  }
}

/// One cashier's totals for today.
class StaffStat {
  const StaffStat({
    required this.salesmanId,
    this.fullname,
    required this.transactionCount,
    required this.salesTotal,
  });
  final String salesmanId;
  final String? fullname;
  final int transactionCount;
  final double salesTotal;

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
    );
  }
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
  });

  final int todayTransactionCount;
  final double todaySalesTotal;
  final List<PaymentBreakdown> paymentBreakdown;
  final List<TopProduct> topProducts;
  final List<StaffStat> staffPerformance;

  static AnalyticsSummary? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final today = asMap(m['today']) ?? const <String, dynamic>{};
    return AnalyticsSummary(
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
