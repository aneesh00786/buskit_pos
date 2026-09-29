import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../checkout/models/payment.dart';
import '../models/cart_sale.dart';

abstract class CartService {
  Future<CartSale> createSale({String? customerId});
  Future<CartSale> getSale(int saleId);
  Future<CartSale> addItem({
    required int saleId,
    required int productVariationId,
    required int quantity,
    required int expectedVersion,
  });
  Future<CartSale> updateItem({
    required int saleId,
    required int itemId,
    required int quantity,
    required int expectedVersion,
  });
  Future<CartSale> removeItem({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  });
  Future<CartSale> holdSale({
    required int saleId,
    required int expectedVersion,
  });
  Future<CartSale> resumeSale({
    required int saleId,
    required int expectedVersion,
  });
  Future<CartSale> cancelSale({
    required int saleId,
    required int expectedVersion,
  });
  Future<CompletedSale> completeSale({
    required int saleId,
    required int expectedVersion,
    required String idempotencyKey,
    required List<PaymentLine> payments,
  });
  Future<CartSale> applyPromotion({
    required int saleId,
    required int promotionId,
    required int expectedVersion,
  });
  Future<CartSale> removePromotion({
    required int saleId,
    required int expectedVersion,
  });
}

/// Verified against the backend: `POST /sales`, `GET /sales/:id`,
/// `POST /sales/:id/items` with `{product_variation_id, quantity, expected_version}`,
/// `PATCH` / `DELETE /sales/:id/items/:itemId`.
/// company/store/register/shift are derived server-side from the token —
/// none are sent.
class ApiCartService implements CartService {
  ApiCartService(this._client);
  final PosApiClient _client;

  @override
  Future<CartSale> createSale({String? customerId}) async {
    // company/store/register/shift come from the token. The only client-chosen
    // field is the optional customer, which the server validates (404 if unknown).
    final id = customerId?.trim();
    return _parse(
      await _client.post(
        '/sales',
        body: {if (id != null && id.isNotEmpty) 'customer_id': id},
      ),
    );
  }

  @override
  Future<CartSale> getSale(int saleId) async =>
      _parse(await _client.get('/sales/$saleId'));

  @override
  Future<CartSale> addItem({
    required int saleId,
    required int productVariationId,
    required int quantity,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/items',
      body: {
        'product_variation_id': productVariationId,
        'quantity': quantity,
        'expected_version': expectedVersion,
      },
    );
    return _parse(data);
  }

  /// `PATCH /sales/:id/items/:itemId {quantity, expected_version}` — `itemId`
  /// is the sale LINE id (`items[].id`), not the variation id. The response is
  /// the refreshed sale view.
  @override
  Future<CartSale> updateItem({
    required int saleId,
    required int itemId,
    required int quantity,
    required int expectedVersion,
  }) async {
    final data = await _client.patch(
      '/sales/$saleId/items/$itemId',
      body: {'quantity': quantity, 'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `DELETE /sales/:id/items/:itemId?expected_version=N` (the backend accepts
  /// the version from the query string or body). Returns the refreshed sale.
  @override
  Future<CartSale> removeItem({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) async {
    final data = await _client.delete(
      '/sales/$saleId/items/$itemId',
      query: {'expected_version': '$expectedVersion'},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/hold {expected_version}` — draft -> held. The response is
  /// the sale view with `status: 'held'`.
  @override
  Future<CartSale> holdSale({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/hold',
      body: {'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/resume {expected_version}` — held -> draft, re-assigned to
  /// the caller's current shift by the server. Returns the sale view.
  @override
  Future<CartSale> resumeSale({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/resume',
      body: {'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/cancel {expected_version}` — a draft on the caller's
  /// shift, or a held sale in the caller's store. Returns the sale (status
  /// `canceled`).
  @override
  Future<CartSale> cancelSale({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/cancel',
      body: {'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/complete {expected_version, idempotency_key, payments[]}`.
  /// Nothing price-related is sent — the server recomputes totals from live
  /// data and requires the payments to sum to its total exactly. The
  /// idempotency key travels in the BODY (the backend does not read a header).
  @override
  Future<CompletedSale> completeSale({
    required int saleId,
    required int expectedVersion,
    required String idempotencyKey,
    required List<PaymentLine> payments,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/complete',
      body: {
        'expected_version': expectedVersion,
        'idempotency_key': idempotencyKey,
        'payments': payments.map((p) => p.toJson()).toList(),
      },
    );
    final sale = CompletedSale.fromJson(data);
    if (sale == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return sale;
  }

  /// `POST /sales/:id/promotion {promotion_id, expected_version}` — apply or
  /// replace the sale's one promotion. The server recalculates the discount;
  /// nothing discount-related is ever sent here.
  @override
  Future<CartSale> applyPromotion({
    required int saleId,
    required int promotionId,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/promotion',
      body: {'promotion_id': promotionId, 'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `DELETE /sales/:id/promotion {expected_version}`.
  @override
  Future<CartSale> removePromotion({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.delete(
      '/sales/$saleId/promotion',
      query: {'expected_version': '$expectedVersion'},
    );
    return _parse(data);
  }

  CartSale _parse(Object? data) {
    final sale = CartSale.fromJson(data);
    if (sale == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return sale;
  }
}
