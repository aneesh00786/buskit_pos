import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// One row of `GET /sales?status=held`. The backend returns raw sale rows
/// (no items, and totals are null until completion), so only the fields that
/// are useful to a cashier are read. Company/device/idempotency columns that
/// the row also carries are deliberately ignored.
class HeldSaleSummary {
  const HeldSaleSummary({
    required this.id,
    required this.version,
    this.status = 'held',
    this.saleNumber,
    this.salesmanId,
    this.registerId,
    this.grandTotal,
    this.heldAt,
    this.createdAt,
    this.updatedAt,
  });

  final int id;

  /// Version at list time. Resume should prefer the fresher version from the
  /// sale detail; a stale value just produces a safe 409.
  final int version;
  final String status;
  final String? saleNumber;
  final String? salesmanId;
  final int? registerId;
  final double? grandTotal;
  final DateTime? heldAt;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  String get title => (saleNumber != null && saleNumber!.isNotEmpty)
      ? saleNumber!
      : 'Sale #$id';

  static HeldSaleSummary? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final version = asInt(m['version']);
    if (id == null || version == null) return null;
    return HeldSaleSummary(
      id: id,
      version: version,
      status: asString(m['status']) ?? 'held',
      saleNumber: asString(m['sale_number']),
      salesmanId: asString(m['salesman_id']),
      registerId: asInt(m['register_id']),
      grandTotal: asDouble(m['grand_total']),
      heldAt: parseServerTime(m['held_at']),
      createdAt: parseServerTime(m['created_at']),
      updatedAt: parseServerTime(m['updated_at']),
    );
  }
}
