import '../../../core/utils/json_read.dart';

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
  });

  final int id;
  final int productVariationId;
  final int quantity;
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
    final qty = asInt(m['quantity']);
    if (id == null || variation == null || qty == null) return null;
    return CartLine(
      id: id,
      productVariationId: variation,
      quantity: qty,
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
  });

  final int id;
  final int version;
  final String status;
  final List<CartLine> items;
  final CartTotals totals;
  final bool hasUnavailableItems;

  /// Set when the sale was created (`POST /sales {customer_id}`); null = guest.
  final String? customerId;

  bool get isDraft => status == 'draft';

  int get itemCount => items.fold(0, (a, b) => a + b.quantity);

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
    );
  }
}
