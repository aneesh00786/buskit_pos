import '../../../core/network/pos_api_client.dart';
import '../models/price_change.dart';

/// POS-only price override API (`products.price_change`, backend-enforced).
/// Never touches the shared catalogue price used by other channels.
abstract class ProductPriceService {
  Future<ProductPriceState?> setPrice({
    required int productId,
    required String price,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  });

  Future<ProductPriceState?> resetPrice({
    required int productId,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  });

  Future<ProductPriceState?> history(int productId);
}

class ApiProductPriceService implements ProductPriceService {
  ApiProductPriceService(this._client);
  final PosApiClient _client;

  @override
  Future<ProductPriceState?> setPrice({
    required int productId,
    required String price,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) async {
    final data = await _client.request(
      'PUT',
      '/products/$productId/price',
      body: {
        'price': price,
        'expected_version': expectedVersion,
        'idempotency_key': idempotencyKey,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      },
    );
    return ProductPriceState.fromJson(data);
  }

  @override
  Future<ProductPriceState?> resetPrice({
    required int productId,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) async {
    final data = await _client.post(
      '/products/$productId/price/reset',
      body: {
        'expected_version': expectedVersion,
        'idempotency_key': idempotencyKey,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
      },
    );
    return ProductPriceState.fromJson(data);
  }

  @override
  Future<ProductPriceState?> history(int productId) async {
    final data = await _client.get('/products/$productId/price-history');
    return ProductPriceState.fromJson(data);
  }
}
