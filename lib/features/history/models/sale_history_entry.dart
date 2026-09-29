import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// One row of `GET /sales?status=completed` — the backend returns raw
/// `pos_sales` columns (no items, no payments), so only the fields useful for
/// a history list are read. Company/device/idempotency columns the row also
/// carries are deliberately ignored. Item names and payment breakdown need a
/// separate `GET /sales/:id` (see [SalesHistoryController.selectSale]).
class SaleHistoryEntry {
  const SaleHistoryEntry({
    required this.id,
    required this.version,
    this.status = 'completed',
    this.saleNumber,
    this.salesmanId,
    this.customerId,
    this.registerId,
    this.subtotal,
    this.taxTotal,
    this.discountTotal,
    this.grandTotal,
    this.createdAt,
    this.completedAt,
  });

  final int id;
  final int version;
  final String status;
  final String? saleNumber;
  final String? salesmanId;
  final String? customerId;
  final int? registerId;
  final double? subtotal;
  final double? taxTotal;
  final double? discountTotal;
  final double? grandTotal;
  final DateTime? createdAt;
  final DateTime? completedAt;

  String get displayNumber =>
      (saleNumber != null && saleNumber!.isNotEmpty) ? saleNumber! : '#$id';

  /// The moment this row sorts/filters by — completion time, falling back to
  /// creation time for the rare row that has neither (defensive only).
  DateTime? get when => completedAt ?? createdAt;

  static SaleHistoryEntry? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final version = asInt(m['version']);
    if (id == null || version == null) return null;
    return SaleHistoryEntry(
      id: id,
      version: version,
      status: asString(m['status']) ?? 'completed',
      saleNumber: asString(m['sale_number']),
      salesmanId: asString(m['salesman_id']),
      customerId: asString(m['customer_id']),
      registerId: asInt(m['register_id']),
      subtotal: asDouble(m['subtotal']),
      taxTotal: asDouble(m['tax_total']),
      discountTotal: asDouble(m['discount_total']),
      grandTotal: asDouble(m['grand_total']),
      createdAt: parseServerTime(m['created_at']),
      completedAt: parseServerTime(m['completed_at']),
    );
  }
}
