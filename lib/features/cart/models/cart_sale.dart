import '../../../core/utils/json_read.dart';
import '../../../core/utils/quantity.dart';
import '../../loyalty/models/loyalty_sale_info.dart';
import '../../promotions/models/promotion.dart';
import 'discount_override.dart';

class CartLine {
  const CartLine({
    required this.id,
    required this.productVariationId,
    required this.quantity,
    this.productName,
    this.barcode,
    this.brandName,
    this.availabilityStatus,
    this.unitPrice,
    this.taxPercent,
    this.taxAmount,
    this.taxIncluded,
    this.discountAmount,
    this.lineTotal,
    this.sellingMode = 'PIECE',
  });

  final int id;
  final int productVariationId;

  /// An int for whole quantities (every PIECE line, exactly as before) or,
  /// for a WEIGHT line, the exact decimal the server sent (e.g. 1.25).
  final num quantity;

  /// Phase 12B: PIECE | WEIGHT (from the server's item view; older servers and
  /// completed-sale views don't send it = PIECE).
  final String sellingMode;
  bool get isWeight => sellingMode == 'WEIGHT';

  /// Exact thousandths of [quantity].
  int get quantityMilli => quantityMilliOf(quantity) ?? 0;

  /// "2" for pieces, "1.250" for a weight.
  String get quantityText => formatQuantity(quantity, weight: isWeight);
  final String? productName;
  final String? barcode;
  final String? brandName;
  final String? availabilityStatus;
  final double? unitPrice;
  final double? taxPercent;
  final double? taxAmount;
  final bool? taxIncluded;

  /// Only present if the server sends it (the live draft view has no
  /// per-line discount; completed sales do).
  final double? discountAmount;
  final double? lineTotal;

  bool get isUnavailable => availabilityStatus == 'unavailable';

  static CartLine? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final variation = asInt(m['product_variation_id']);
    // Exact: whole quantities stay ints; WEIGHT decimals keep 3 places.
    final qtyMilli = quantityMilliOf(m['quantity']);
    if (id == null || variation == null || qtyMilli == null) return null;
    return CartLine(
      id: id,
      productVariationId: variation,
      quantity: quantityFromMilli(qtyMilli),
      sellingMode: (asString(m['selling_mode']) ?? 'PIECE').toUpperCase(),
      productName: asString(m['product_name']),
      barcode: asString(m['barcode']),
      brandName: asString(m['brandname']),
      availabilityStatus: asString(m['availability_status']),
      unitPrice: asDouble(m['unit_price']),
      taxPercent: asDouble(m['tax_percent']),
      taxAmount: asDouble(m['tax_amount']),
      taxIncluded: asBool(m['tax_included']),
      discountAmount: asDouble(m['discount_amount']),
      lineTotal: asDouble(m['line_total']),
    );
  }
}

/// Server-computed totals — displayed exactly as received.
class CartTotals {
  const CartTotals({
    this.subtotal,
    this.taxTotal,
    this.discountTotal,
    this.grandTotal,
  });
  final double? subtotal;
  final double? taxTotal;
  final double? discountTotal;
  final double? grandTotal;

  factory CartTotals.fromJson(Object? json) {
    final m = asMap(json) ?? const <String, dynamic>{};
    return CartTotals(
      subtotal: asDouble(m['subtotal']),
      taxTotal: asDouble(m['tax_total']),
      discountTotal: asDouble(m['discount_total']),
      grandTotal: asDouble(m['grand_total']),
    );
  }
}

/// The draft sale ("cart") as returned by the sales API. [version] is the
/// optimistic-concurrency token the next mutation must echo back.
class CartSale {
  const CartSale({
    required this.id,
    required this.version,
    required this.status,
    required this.items,
    required this.totals,
    this.hasUnavailableItems = false,
    this.customerId,
    this.promotion,
    this.loyalty,
    this.discountOverride,
    this.shiftId,
    this.storeId,
    this.registerId,
    this.isLocal = false,
  });

  final int id;
  final int version;
  final String status;
  final List<CartLine> items;
  final CartTotals totals;
  final bool hasUnavailableItems;

  /// Set when the sale was created (`POST /sales {customer_id}`); null = guest.
  final String? customerId;

  /// The promotion currently attached to this sale, if any — always
  /// recomputed live by the server (never trust an earlier apply/preview).
  /// `promotion.eligible == false` means it's attached but no longer usable
  /// (cart changed, it expired, ...) — shown, not silently dropped.
  final AppliedPromotion? promotion;

  /// Loyalty state (tier discount, any pending points/wallet redemption,
  /// points/cashback to be earned) — null when there's no customer on the
  /// sale or the company has no active loyalty program at all.
  final LoyaltySaleInfo? loyalty;

  /// The manual discount override currently applied, if any — applies LAST,
  /// on top of whatever promotion/loyalty already left. Always recomputed
  /// live by the server.
  final DiscountOverride? discountOverride;

  /// Scope of the sale as the server reports it (null for a local cart).
  final int? shiftId;
  final int? storeId;
  final int? registerId;

  /// True for a cart built on this device while offline: it has no server
  /// sale ([id] is 0), its figures come from the offline catalogue and the
  /// ported tax rule, and it can only be completed as an offline sale.
  final bool isLocal;

  bool get isDraft => status == 'draft';

  /// Pieces in the sale; a weighed line counts as one item (Phase 12B).
  int get itemCount => items.fold(
    0,
    (a, b) => a + (b.isWeight ? 1 : b.quantityMilli ~/ quantityUnit),
  );

  static CartSale? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final version = asInt(m['version']);
    if (id == null || version == null) return null;
    return CartSale(
      id: id,
      version: version,
      status: asString(m['status']) ?? 'draft',
      items: asList(m['items'])
          .map(CartLine.fromJson)
          .whereType<CartLine>()
          .toList(),
      totals: CartTotals.fromJson(m['totals']),
      hasUnavailableItems: asBool(m['has_unavailable_items']) ?? false,
      customerId: asString(m['customer_id']),
      promotion: AppliedPromotion.fromJson(m['promotion']),
      loyalty: LoyaltySaleInfo.fromJson(m['loyalty']),
      discountOverride: DiscountOverride.fromJson(m['discount_override']),
      shiftId: asInt(m['shift_id']),
      storeId: asInt(m['store_id']),
      registerId: asInt(m['register_id']),
    );
  }
}
