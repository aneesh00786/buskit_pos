import '../../../core/config/app_config.dart';
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
  /// don't send it, which means PIECE. PIECE sells in whole units; WEIGHT
  /// (Phase 12B) by an entered weight — the server decides whether weight
  /// sales are enabled and refuses them when not. REVIEW is never sold.
  final String sellingMode;
  bool get isWeight => sellingMode == 'WEIGHT';
  bool get isPosSellable => sellingMode == 'PIECE' || isWeight;

  /// The reason the product can't be added (null when it can).
  String? get notSellableMessage =>
      isPosSellable ? null : 'This product is not configured for POS sale.';
  final String? imageUrl;
  final CategoryRef? category;

  /// Informational only (browse-time snapshot). The server enforces stock.
  final double? currentStock;
  final ProductPricing pricing;

  /// Rows without a usable numeric id cannot be added to a cart and are
  /// dropped by the caller.
  static ProductItem? fromJson(Object? json, {String? baseUrl}) {
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
      imageUrl: cleanUrl(_extractImageString(m), baseUrl: baseUrl),
      category: CategoryRef.fromJson(m['category']),
      currentStock: asDouble(asMap(m['stock'])?['current_stock']),
      pricing: ProductPricing.fromJson(m['pricing']),
    );
  }

  static String? _extractImageString(Map<String, dynamic> m) {
    final direct = asString(m['image_url']) ??
        asString(m['image']) ??
        asString(m['image_path']) ??
        asString(m['product_image']) ??
        asString(m['thumbnail']) ??
        asString(m['img']) ??
        asString(m['photo']);
    if (direct != null && direct.trim().isNotEmpty) return direct.trim();

    final images = m['images'] ?? m['media'] ?? m['photos'];
    if (images is List && images.isNotEmpty) {
      final first = images.first;
      if (first is String && first.trim().isNotEmpty) return first.trim();
      if (first is Map) {
        final nested = asString(first['url']) ??
            asString(first['src']) ??
            asString(first['image_url']) ??
            asString(first['image_path']) ??
            asString(first['path']);
        if (nested != null && nested.trim().isNotEmpty) return nested.trim();
      }
    }
    return null;
  }

  /// Cleans and resolves a product image URL or relative file path to a fully
  /// qualified web address.
  static String? cleanUrl(String? u, {String? baseUrl}) {
    if (u == null) return null;
    var t = u.trim();
    if (t.isEmpty ||
        t.toLowerCase() == 'null' ||
        t.toLowerCase() == 'undefined') {
      return null;
    }

    final lower = t.toLowerCase();
    if (lower.startsWith('javascript:') ||
        lower.startsWith('file:') ||
        lower.startsWith('data:') ||
        lower.startsWith('about:')) {
      return null;
    }

    final rawBase = (baseUrl != null && baseUrl.trim().isNotEmpty)
        ? baseUrl.trim()
        : AppConfig.baseUrl;
    final baseOrigin = rawBase.replaceAll(RegExp(r'/+$'), '');

    // Already an absolute HTTP/HTTPS URL
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      if (lower.startsWith('http://')) {
        // Upgrade to https for ATS / cleartext compliance
        t = 'https://${t.substring(7)}';
      }
      if (t.contains('/uploads/')) {
        final uri = Uri.tryParse(t);
        if (uri != null &&
            (RegExp(r'^\d+\.\d+\.\d+\.\d+').hasMatch(uri.host) ||
                uri.host == 'localhost' ||
                (uri.port != 80 && uri.port != 443 && uri.port != 0))) {
          final uploadPath = t.split('/uploads/').last;
          return '$baseOrigin/uploads/$uploadPath';
        }
      }
      return t;
    }

    // Relative path validation: ensure it has an image extension or path prefix.
    final hasImageExt = RegExp(
      r'\.(jpg|jpeg|png|webp|gif|svg|bmp|avif)(\?.*)?$',
      caseSensitive: false,
    ).hasMatch(t);
    final hasPathPrefix = t.startsWith('/') ||
        lower.startsWith('uploads/') ||
        lower.startsWith('product/') ||
        lower.startsWith('products/') ||
        lower.startsWith('media/') ||
        lower.startsWith('images/');

    if (!hasImageExt && !hasPathPrefix) {
      return null;
    }
    if (t.contains(' ') && !t.contains('/')) {
      return null;
    }

    // Relative path or filename: normalize and mount under uploads/
    var path = t.replaceAll(RegExp(r'^/+'), '');
    if (path.toLowerCase().startsWith('uploads/')) {
      path = path.substring(8).replaceAll(RegExp(r'^/+'), '');
    }

    return '$baseOrigin/uploads/$path';
  }
}
