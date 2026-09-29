import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';
import '../../products/models/product_page.dart';

/// One completed sale in a customer's purchase history
/// (`GET /customers/:id/purchases`). No item/product detail — same minimal
/// shape as the backend's own `pos_sales` read, not the full Sales History
/// detail view.
class CustomerPurchase {
  const CustomerPurchase({
    required this.id,
    this.saleNumber,
    this.grandTotal,
    this.completedAt,
  });
  final int id;
  final String? saleNumber;
  final double? grandTotal;
  final DateTime? completedAt;

  String get displayNumber =>
      (saleNumber != null && saleNumber!.isNotEmpty) ? saleNumber! : '#$id';

  static CustomerPurchase? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    if (id == null) return null;
    return CustomerPurchase(
      id: id,
      saleNumber: asString(m['sale_number']),
      grandTotal: asDouble(m['grand_total']),
      completedAt: parseServerTime(m['completed_at']),
    );
  }
}

/// The `summary` object alongside a purchase-history page.
class CustomerPurchaseSummary {
  const CustomerPurchaseSummary({
    required this.transactionCount,
    required this.totalPurchases,
    this.lastPurchaseAt,
  });
  final int transactionCount;
  final double totalPurchases;
  final DateTime? lastPurchaseAt;

  static CustomerPurchaseSummary fromJson(Object? json) {
    final m = asMap(json) ?? const <String, dynamic>{};
    return CustomerPurchaseSummary(
      transactionCount: asInt(m['transaction_count']) ?? 0,
      totalPurchases: asDouble(m['total_purchases']) ?? 0,
      lastPurchaseAt: parseServerTime(m['last_purchase_at']),
    );
  }
}

/// One page of `GET /customers/:id/purchases`.
class CustomerPurchasePage {
  const CustomerPurchasePage({
    required this.summary,
    required this.items,
    required this.pagination,
  });
  final CustomerPurchaseSummary summary;
  final List<CustomerPurchase> items;
  final Pagination pagination;

  bool get hasMore => pagination.page < pagination.totalPages;

  factory CustomerPurchasePage.fromJson(
    Object? json, {
    int requestedPage = 1,
    int requestedLimit = 20,
  }) {
    final m = asMap(json) ?? const <String, dynamic>{};
    final items = asList(m['items'])
        .map(CustomerPurchase.fromJson)
        .whereType<CustomerPurchase>()
        .toList();
    final pg = asMap(m['pagination']) ?? const <String, dynamic>{};
    final totalPages = asInt(pg['total_pages']) ?? 1;
    return CustomerPurchasePage(
      summary: CustomerPurchaseSummary.fromJson(m['summary']),
      items: items,
      pagination: Pagination(
        page: asInt(pg['page']) ?? requestedPage,
        limit: asInt(pg['limit']) ?? requestedLimit,
        total: asInt(pg['total']) ?? items.length,
        totalPages: totalPages < 1 ? 1 : totalPages,
      ),
    );
  }
}
