import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/inventory_adjustment.dart';

abstract class InventoryService {
  /// `POST /inventory/adjustments` (`inventory.adjust`, backend-enforced).
  /// Only business input is sent — the server resolves company/store/staff/
  /// device and computes the previous/resulting stock itself.
  Future<InventoryAdjustment?> adjust({
    required int productVariationId,
    required AdjustmentDirection direction,
    required String quantity,
    required String reason,
    required String idempotencyKey,
  });

  /// `GET /inventory/adjustments[?product_variation_id=]` (`inventory.view`),
  /// newest-first.
  Future<List<InventoryAdjustment>> listHistory({int? productVariationId});
}

class ApiInventoryService implements InventoryService {
  ApiInventoryService(this._client);
  final PosApiClient _client;

  @override
  Future<InventoryAdjustment?> adjust({
    required int productVariationId,
    required AdjustmentDirection direction,
    required String quantity,
    required String reason,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/inventory/adjustments',
      body: {
        'product_variation_id': productVariationId,
        'direction': direction.wire,
        'quantity': quantity,
        'reason': reason,
        'idempotency_key': idempotencyKey,
      },
    );
    return InventoryAdjustment.fromJson(data);
  }

  @override
  Future<List<InventoryAdjustment>> listHistory({
    int? productVariationId,
  }) async {
    final data = await _client.get(
      '/inventory/adjustments',
      query: productVariationId == null
          ? null
          : {'product_variation_id': '$productVariationId'},
    );
    return asList(asMap(data)?['items'])
        .map(InventoryAdjustment.fromJson)
        .whereType<InventoryAdjustment>()
        .toList();
  }
}
