import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/cart_sale.dart';
import '../models/line_pricing.dart';

/// Line discounts and per-sale price overrides (backend migration 055).
/// Only intent is sent — type / value / reason, or a unit price and a reason,
/// plus the sale version; the server checks permission and limits and returns
/// the refreshed sale with every amount. Online only.
abstract class LinePricingService {
  /// `GET /discount-policy` — what the signed-in staff member may do.
  Future<DiscountPolicy> loadPolicy();

  Future<CartSale> setDiscount({
    required int saleId,
    required int itemId,
    required String type,
    required String value,
    required String reason,
    required int expectedVersion,
  });

  Future<CartSale> removeDiscount({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  });

  Future<CartSale> setPrice({
    required int saleId,
    required int itemId,
    required String unitPrice,
    required String reason,
    required int expectedVersion,
  });

  Future<CartSale> removePrice({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  });
}

class ApiLinePricingService implements LinePricingService {
  ApiLinePricingService(this._client);
  final PosApiClient _client;

  CartSale _sale(Object? data) {
    final sale = CartSale.fromJson(data);
    if (sale == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return sale;
  }

  @override
  Future<DiscountPolicy> loadPolicy() async =>
      DiscountPolicy.fromJson(await _client.get('/discount-policy'));

  @override
  Future<CartSale> setDiscount({
    required int saleId,
    required int itemId,
    required String type,
    required String value,
    required String reason,
    required int expectedVersion,
  }) async => _sale(
    await _client.request(
      'PUT',
      '/sales/$saleId/items/$itemId/discount',
      body: {
        'discount_type': type,
        'discount_value': value,
        'reason': reason,
        'expected_version': expectedVersion,
      },
    ),
  );

  @override
  Future<CartSale> removeDiscount({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) async => _sale(
    await _client.request(
      'DELETE',
      '/sales/$saleId/items/$itemId/discount',
      body: {'expected_version': expectedVersion},
    ),
  );

  @override
  Future<CartSale> setPrice({
    required int saleId,
    required int itemId,
    required String unitPrice,
    required String reason,
    required int expectedVersion,
  }) async => _sale(
    await _client.request(
      'PUT',
      '/sales/$saleId/items/$itemId/price',
      body: {
        'unit_price': unitPrice,
        'reason': reason,
        'expected_version': expectedVersion,
      },
    ),
  );

  @override
  Future<CartSale> removePrice({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) async => _sale(
    await _client.request(
      'DELETE',
      '/sales/$saleId/items/$itemId/price',
      body: {'expected_version': expectedVersion},
    ),
  );
}
