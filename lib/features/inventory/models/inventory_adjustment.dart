import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

enum AdjustmentDirection {
  increase,
  decrease;

  String get wire => name;
  String get label => this == increase ? 'Increase' : 'Decrease';

  static AdjustmentDirection? fromWire(String? v) => switch (v) {
    'increase' => increase,
    'decrease' => decrease,
    _ => null,
  };
}

/// One immutable inventory adjustment (`pos_inventory_adjustments`) as
/// returned by `POST`/`GET /inventory/adjustments`. Quantities are whole
/// pieces — the stock ledger is piece-based.
class InventoryAdjustment {
  const InventoryAdjustment({
    required this.id,
    required this.productVariationId,
    required this.direction,
    required this.quantity,
    required this.previousQuantity,
    required this.resultingQuantity,
    required this.reason,
    this.salesmanId,
    this.createdAt,
  });

  final int id;
  final int productVariationId;
  final AdjustmentDirection direction;
  final int quantity;
  final int previousQuantity;
  final int resultingQuantity;
  final String reason;
  final String? salesmanId;
  final DateTime? createdAt;

  /// e.g. "+10" / "-3".
  String get signedQuantity =>
      direction == AdjustmentDirection.increase ? '+$quantity' : '-$quantity';

  static InventoryAdjustment? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final pv = asInt(m['product_variation_id']);
    final direction = AdjustmentDirection.fromWire(asString(m['direction']));
    final qty = asInt(m['quantity']);
    final prev = asInt(m['previous_quantity']);
    final result = asInt(m['resulting_quantity']);
    final reason = asString(m['reason']);
    if (id == null ||
        pv == null ||
        direction == null ||
        qty == null ||
        prev == null ||
        result == null ||
        reason == null) {
      return null;
    }
    return InventoryAdjustment(
      id: id,
      productVariationId: pv,
      direction: direction,
      quantity: qty,
      previousQuantity: prev,
      resultingQuantity: result,
      reason: reason,
      salesmanId: asString(m['salesman_id']),
      createdAt: parseServerTime(m['created_at']),
    );
  }
}
