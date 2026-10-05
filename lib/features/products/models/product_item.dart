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
    this.cataloguePrice,
    this.priceSource,
    this.priceVersion = 0,
  });

  /// The price POS charges: the POS-only override when one is set,
  /// otherwise the shared catalogue price.
  final double? sellPrice;

  /// The shared catalogue price (web store, Van Sales, B2B). POS never
  /// changes it.
  final double? cataloguePrice;

  /// 'pos' when a POS-only price override is active, else 'catalogue'.
  final String? priceSource;

  /// Optimistic-concurrency token sent back with a price change.
  final int priceVersion;

  bool get hasPosOverride => priceSource == 'pos';
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
      cataloguePrice: asDouble(m['catalogue_price']),
      priceSource: asString(m['price_source']),
      priceVersion: asInt(m['price_version']) ?? 0,
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
    this.sellingMode = 'PIECE',
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
  /// Descriptive pack-size label ("100 Grm", "250 ML") — never decides
  /// whether the product can be sold.
  final String? unitType;

  /// Server-decided POS selling mode: PIECE, WEIGHT or REVIEW. Older servers
  /// don't send it, which means PIECE. Only PIECE can be sold in this app
  /// (WEIGHT waits for the weight-selling phase); the server enforces it.
  final String sellingMode;
  bool get isPosSellable => sellingMode == 'PIECE';

  /// The reason a non-PIECE product can't be added (null when it can).
  String? get notSellableMessage => isPosSellable
      ? null
      : sellingMode == 'WEIGHT'
      ? 'This product is sold by weight, which the POS does not support yet.'
      : 'This product is not configured for POS sale.';
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
      sellingMode: (asString(m['selling_mode']) ?? 'PIECE').toUpperCase(),
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
