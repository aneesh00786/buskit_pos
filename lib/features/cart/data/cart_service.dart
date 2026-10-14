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
    required num quantity,
    required int expectedVersion,
  });
  Future<CartSale> updateItem({
    required int saleId,
    required int itemId,
    required num quantity,
    required int expectedVersion,
  });
  Future<CartSale> removeItem({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  });
  /// [tableRef] (Phase 2.1, optional): parks the sale at that table; null
  /// leaves the sale's table as it is.
  Future<CartSale> holdSale({
    required int saleId,
    required int expectedVersion,
    String? tableRef,
  });
  /// [voice] (Phase 2, optional): `{voice_session_id, request_id}` of the
  /// voice request billing this order — the server records the audit link
  /// in the same transaction. Absent: unchanged.
  Future<CartSale> resumeSale({
    required int saleId,
    required int expectedVersion,
    Map<String, String>? voice,
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

  /// `PATCH /sales/:id/discount {discount_type, discount_value, reason?, expected_version}`
  /// — apply or replace the sale's manual discount override
  /// (`discounts.override` permission; backend-enforced). The server
  /// recalculates the discount amount; nothing discount-related beyond the
  /// cashier's typed type/value/reason is ever sent here.
  Future<CartSale> applyDiscountOverride({
    required int saleId,
    required String discountType,
    required String discountValue,
    String? reason,
    required int expectedVersion,
  });

  /// `DELETE /sales/:id/discount {expected_version}`.
  Future<CartSale> removeDiscountOverride({
    required int saleId,
    required int expectedVersion,
  });

  /// `POST /sales/:id/loyalty/redeem-points {points, expected_version}` —
  /// `points: 0` clears any pending points redemption. The discount is
  /// recalculated server-side; nothing discount-related is ever sent here.
  Future<CartSale> redeemLoyaltyPoints({
    required int saleId,
    required int points,
    required int expectedVersion,
  });

  /// `POST /sales/:id/loyalty/redeem-wallet {amount, expected_version}` —
  /// `amount: 0` clears any pending wallet redemption. Wallet does not
  /// change the sale total (it's a payment-tender substitute, not a
  /// discount) — it just reduces what cash/card/other must cover at pay time.
  Future<CartSale> redeemLoyaltyWallet({
    required int saleId,
    required double amount,
    required int expectedVersion,
  });

  /// `DELETE /sales/:id/loyalty/redemption {expected_version}` — clears any
  /// pending points/wallet redemption (the automatic tier discount, if any,
  /// is unaffected).
  Future<CartSale> removeLoyaltyRedemption({
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
    required num quantity,
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
    required num quantity,
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
    String? tableRef,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/hold',
      body: {'expected_version': expectedVersion, 'table_ref': ?tableRef},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/resume {expected_version}` — held -> draft, re-assigned to
  /// the caller's current shift by the server. Returns the sale view.
  @override
  Future<CartSale> resumeSale({
    required int saleId,
    required int expectedVersion,
    Map<String, String>? voice,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/resume',
      body: {'expected_version': expectedVersion, 'voice': ?voice},
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

  /// `PATCH /sales/:id/discount {discount_type, discount_value, reason?, expected_version}`.
  @override
  Future<CartSale> applyDiscountOverride({
    required int saleId,
    required String discountType,
    required String discountValue,
    String? reason,
    required int expectedVersion,
  }) async {
    final data = await _client.patch(
      '/sales/$saleId/discount',
      body: {
        'discount_type': discountType,
        'discount_value': discountValue,
        if (reason != null && reason.isNotEmpty) 'reason': reason,
        'expected_version': expectedVersion,
      },
    );
    return _parse(data);
  }

  /// `DELETE /sales/:id/discount {expected_version}`.
  @override
  Future<CartSale> removeDiscountOverride({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.delete(
      '/sales/$saleId/discount',
      query: {'expected_version': '$expectedVersion'},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/loyalty/redeem-points {points, expected_version}`.
  @override
  Future<CartSale> redeemLoyaltyPoints({
    required int saleId,
    required int points,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/loyalty/redeem-points',
      body: {'points': points, 'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `POST /sales/:id/loyalty/redeem-wallet {amount, expected_version}`.
  @override
  Future<CartSale> redeemLoyaltyWallet({
    required int saleId,
    required double amount,
    required int expectedVersion,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/loyalty/redeem-wallet',
      body: {'amount': amount, 'expected_version': expectedVersion},
    );
    return _parse(data);
  }

  /// `DELETE /sales/:id/loyalty/redemption {expected_version}`.
  @override
  Future<CartSale> removeLoyaltyRedemption({
    required int saleId,
    required int expectedVersion,
  }) async {
    final data = await _client.delete(
      '/sales/$saleId/loyalty/redemption',
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
