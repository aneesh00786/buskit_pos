import 'package:buskit_pos/features/history/models/sale_history_entry.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> row({
  int id = 7,
  int version = 1,
  String status = 'completed',
  String? saleNumber = 'POS-00000007',
  String? salesmanId = 'SALES1',
  String? customerId,
  int? registerId = 3,
  double? subtotal = 100,
  double? taxTotal = 12,
  double? discountTotal = 0,
  double? grandTotal = 112,
  String? createdAt = '2026-09-22 09:00:00',
  String? completedAt = '2026-09-22 09:01:00',
}) => {
  'id': id,
  'version': version,
  'status': status,
  'sale_number': saleNumber,
  'salesman_id': salesmanId,
  'customer_id': customerId,
  'register_id': registerId,
  'subtotal': subtotal,
  'tax_total': taxTotal,
  'discount_total': discountTotal,
  'grand_total': grandTotal,
  'created_at': createdAt,
  'completed_at': completedAt,
};

void main() {
  test('parses a raw pos_sales row', () {
    final e = SaleHistoryEntry.fromJson(row())!;
    expect(e.id, 7);
    expect(e.displayNumber, 'POS-00000007');
    expect(e.salesmanId, 'SALES1');
    expect(e.grandTotal, 112);
    expect(e.when, e.completedAt);
  });

  test('missing id or version yields null (no crash on a malformed row)', () {
    expect(SaleHistoryEntry.fromJson(row()..remove('id')), isNull);
    expect(SaleHistoryEntry.fromJson(row()..remove('version')), isNull);
    expect(SaleHistoryEntry.fromJson(null), isNull);
    expect(SaleHistoryEntry.fromJson('not a map'), isNull);
  });

  test('an empty/missing sale_number falls back to "#id"', () {
    expect(
      SaleHistoryEntry.fromJson(row(saleNumber: null))!.displayNumber,
      '#7',
    );
    expect(SaleHistoryEntry.fromJson(row(saleNumber: ''))!.displayNumber, '#7');
  });

  test('"when" falls back to created_at if completed_at is missing', () {
    final e = SaleHistoryEntry.fromJson(row(completedAt: null))!;
    expect(e.when, e.createdAt);
    expect(e.when, isNotNull);
  });

  test('"when" is null when both timestamps are missing (defensive)', () {
    final e = SaleHistoryEntry.fromJson(
      row(completedAt: null, createdAt: null),
    )!;
    expect(e.when, isNull);
  });
}
