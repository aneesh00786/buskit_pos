import '../../../core/utils/json_read.dart';

class CategoryRef {
  const CategoryRef({required this.id, this.name});
  final int id;
  final String? name;

  static CategoryRef? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    if (id == null) return null;
    return CategoryRef(id: id, name: asString(m['name']));
  }
}

/// Server-authoritative pricing for one unit. Displayed as received; the
/// client never recomputes price, tax or totals from these.
class ProductPricing {
  const ProductPricing({
    this.sellPrice,
    this.taxPercent,
    this.taxMode,
    this.taxIncluded,
    this.taxAmount,
    this.pricingStatus,
  });

  final double? sellPrice;
  final double? taxPercent;

  /// 'inclusive' | 'exclusive' | 'none' as sent by the backend.
  final String? taxMode;
  final bool? taxIncluded;
  final double? taxAmount;
  final String? pricingStatus;

  factory ProductPricing.fromJson(Object? json) {
    final m = asMap(json) ?? const <String, dynamic>{};
    return ProductPricing(
      sellPrice: asDouble(m['sell_price']),
      taxPercent: asDouble(m['tax_percent']),
      taxMode: asString(m['tax_mode']),
      taxIncluded: asBool(m['tax_included']),
      taxAmount: asDouble(m['tax_amount']),
      pricingStatus: asString(m['pricing_status']),
    );
  }
}

/// One sellable variation row from `GET /products`. [id] is the numeric
/// `product_variation.id` — the value the cart API expects as
/// `product_variation_id` (NOT the string [variationId]).
class ProductItem {
  const ProductItem({
    required this.id,
    required this.productName,
    this.variationId,
    this.variationName,
    this.productId,
    this.productCode,
    this.brandName,
    this.barcode,
    this.unitType,
    this.imageUrl,
    this.category,
    this.currentStock,
    this.pricing = const ProductPricing(),
  });

  final int id;
  final String productName;
  final String? variationId;
  final String? variationName;
  final String? productId;
  final String? productCode;
  final String? brandName;
  final String? barcode;
  final String? unitType;
  final String? imageUrl;
  final CategoryRef? category;

  /// Informational only (browse-time snapshot). The server enforces stock.
  final double? currentStock;
  final ProductPricing pricing;

  /// Rows without a usable numeric id cannot be added to a cart and are
  /// dropped by the caller.
  static ProductItem? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    if (id == null) return null;
    final name = asString(m['product_name'])?.trim();
    return ProductItem(
      id: id,
      productName: (name == null || name.isEmpty) ? 'Unnamed product' : name,
      variationId: asString(m['variation_id']),
      variationName: asString(m['variation_name']),
      productId: asString(m['product_id']),
      productCode: asString(m['product_code']),
      brandName: asString(m['brandname']),
      barcode: asString(m['barcode']),
      unitType: asString(m['unit_type']),
      imageUrl: _cleanUrl(asString(m['image_url'])),
      category: CategoryRef.fromJson(m['category']),
      currentStock: asDouble(asMap(m['stock'])?['current_stock']),
      pricing: ProductPricing.fromJson(m['pricing']),
    );
  }

  static String? _cleanUrl(String? u) {
    if (u == null) return null;
    final t = u.trim();
    if (t.isEmpty) return null;
    final uri = Uri.tryParse(t);
    return (uri != null && (uri.scheme == 'http' || uri.scheme == 'https'))
        ? t
        : null;
  }
}
