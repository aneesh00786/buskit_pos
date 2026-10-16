import '../../../core/utils/json_read.dart';
import '../../customers/models/customer.dart';
import '../../products/models/product_item.dart';

int _milli(num v) => (v * 1000).round();

/// A POS product as cached for offline use — only what browsing, barcode
/// lookup and a future offline sale need. Prices are the SERVER's figures at
/// cache time (`pricing.sell_price`, already including a POS price override);
/// tax inputs are exactly what the server's single tax function uses
/// (buskit-web services/pos/posTax.js): the summed category tax percent and
/// the tax mode (inclusive / exclusive / none).
class OfflineProduct {
  const OfflineProduct({
    required this.productVariationId,
    required this.productName,
    required this.sellingMode,
    required this.sellPriceMilli,
    required this.taxPercent,
    required this.taxMode,
    this.variationId,
    this.productId,
    this.variationName,
    this.productCode,
    this.barcode,
    this.unitType,
    this.categoryId,
    this.imageUrl,
    this.active = true,
  });

  /// product_variation.id — the id every POS API uses.
  final int productVariationId;
  final String? variationId;
  final String? productId;
  final String productName;
  final String? variationName;

  /// The catalogue's product code (the POS's searchable code).
  final String? productCode;
  final String? barcode;
  final String? unitType;

  /// PIECE / WEIGHT / REVIEW — unchanged rules: only PIECE can be sold.
  final String sellingMode;
  final int sellPriceMilli;
  final double taxPercent;

  /// 'inclusive' | 'exclusive' | 'none' (server tax mode).
  final String taxMode;
  final int? categoryId;
  final String? imageUrl;
  final bool active;

  bool get isPosSellable => active && sellingMode == 'PIECE';

  /// From the online catalogue model (GET /products), keeping the server's
  /// pricing and tax figures as they are.
  static OfflineProduct? fromProductItem(ProductItem p) {
    final price = p.pricing.sellPrice;
    if (price == null) return null;
    return OfflineProduct(
      productVariationId: p.id,
      variationId: p.variationId,
      productId: p.productId,
      productName: p.productName,
      variationName: p.variationName,
      productCode: p.productCode,
      barcode: p.barcode,
      unitType: p.unitType,
      sellingMode: p.sellingMode,
      sellPriceMilli: _milli(price),
      taxPercent: p.pricing.taxPercent ?? 0,
      taxMode:
          p.pricing.taxMode ??
          (p.pricing.taxIncluded == true ? 'inclusive' : 'exclusive'),
      categoryId: p.category?.id,
      imageUrl: p.imageUrl,
    );
  }

  /// Back to the browse model, for showing the cached catalogue while
  /// offline. [stock] is the OFFLINE available quantity (last server stock
  /// minus unsynced local sales), when known.
  ProductItem toProductItem({double? stock}) => ProductItem(
    id: productVariationId,
    productName: productName,
    variationId: variationId,
    variationName: variationName,
    productId: productId,
    productCode: productCode,
    barcode: barcode,
    unitType: unitType,
    sellingMode: sellingMode,
    imageUrl: imageUrl,
    category: categoryId == null ? null : CategoryRef(id: categoryId!),
    currentStock: stock,
    pricing: ProductPricing(
      sellPrice: sellPriceMilli / 1000,
      taxPercent: taxPercent,
      taxMode: taxMode,
      taxIncluded: taxMode == 'inclusive',
    ),
  );

  Map<String, dynamic> toJson() => {
    'product_variation_id': productVariationId,
    'variation_id': variationId,
    'product_id': productId,
    'product_name': productName,
    'variation_name': variationName,
    'product_code': productCode,
    'barcode': barcode,
    'unit_type': unitType,
    'selling_mode': sellingMode,
    'sell_price_milli': sellPriceMilli,
    'tax_percent': taxPercent,
    'tax_mode': taxMode,
    'category_id': categoryId,
    'image_url': imageUrl,
    'active': active,
  };

  static OfflineProduct? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['product_variation_id']);
    final name = asString(m?['product_name']);
    final price = asInt(m?['sell_price_milli']);
    if (m == null || id == null || name == null || price == null) return null;
    return OfflineProduct(
      productVariationId: id,
      variationId: asString(m['variation_id']),
      productId: asString(m['product_id']),
      productName: name,
      variationName: asString(m['variation_name']),
      productCode: asString(m['product_code']),
      barcode: asString(m['barcode']),
      unitType: asString(m['unit_type']),
      sellingMode: (asString(m['selling_mode']) ?? 'REVIEW').toUpperCase(),
      sellPriceMilli: price,
      taxPercent: asDouble(m['tax_percent']) ?? 0,
      taxMode: asString(m['tax_mode']) ?? 'exclusive',
      categoryId: asInt(m['category_id']),
      imageUrl: asString(m['image_url']),
      active: asBool(m['active']) ?? true,
    );
  }
}

/// products.json — the catalogue snapshot for one company/store.
class OfflineCatalogue {
  const OfflineCatalogue({
    required this.companyId,
    required this.storeId,
    required this.cachedAt,
    required this.products,
  });
  final int companyId;
  final int storeId;
  final DateTime cachedAt;
  final List<OfflineProduct> products;

  Map<String, dynamic> toJson() => {
    'company_id': companyId,
    'store_id': storeId,
    'cached_at': cachedAt.toUtc().toIso8601String(),
    'products': products.map((p) => p.toJson()).toList(),
  };

  static OfflineCatalogue? fromJson(Map<String, dynamic> m) {
    final company = asInt(m['company_id']);
    final store = asInt(m['store_id']);
    final at = DateTime.tryParse(asString(m['cached_at']) ?? '');
    if (company == null || store == null || at == null) return null;
    return OfflineCatalogue(
      companyId: company,
      storeId: store,
      cachedAt: at.toUtc(),
      products: asList(m['products'])
          .map(OfflineProduct.fromJson)
          .whereType<OfflineProduct>()
          .toList(),
    );
  }
}

/// One variation's last KNOWN server stock (inventory.json). A snapshot, never
/// real-time: offline availability is computed from it minus what unsynced
/// local sales consumed (see `OfflineStockLevel`).
class InventorySnapshotEntry {
  const InventorySnapshotEntry({
    required this.productVariationId,
    required this.serverQuantity,
  });
  final int productVariationId;
  final double serverQuantity;

  Map<String, dynamic> toJson() => {
    'product_variation_id': productVariationId,
    'server_quantity': serverQuantity,
  };

  static InventorySnapshotEntry? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['product_variation_id']);
    final q = asDouble(m?['server_quantity']);
    if (id == null || q == null) return null;
    return InventorySnapshotEntry(productVariationId: id, serverQuantity: q);
  }
}

class InventorySnapshot {
  const InventorySnapshot({required this.syncedAt, required this.entries});

  /// When the server quantities were fetched.
  final DateTime syncedAt;
  final List<InventorySnapshotEntry> entries;

  Map<String, dynamic> toJson() => {
    'synced_at': syncedAt.toUtc().toIso8601String(),
    'entries': entries.map((e) => e.toJson()).toList(),
  };

  static InventorySnapshot? fromJson(Map<String, dynamic> m) {
    final at = DateTime.tryParse(asString(m['synced_at']) ?? '');
    if (at == null) return null;
    return InventorySnapshot(
      syncedAt: at.toUtc(),
      entries: asList(m['entries'])
          .map(InventorySnapshotEntry.fromJson)
          .whereType<InventorySnapshotEntry>()
          .toList(),
    );
  }
}

/// Offline availability of one variation:
///   available = last server quantity - quantity sold in local sales that the
///   server has not confirmed yet.
/// Always STALE: the label must say so ([staleLabel]).
class OfflineStockLevel {
  const OfflineStockLevel({
    required this.productVariationId,
    required this.serverQuantity,
    required this.offlineConsumedQuantity,
    required this.lastSyncedAt,
  });
  final int productVariationId;
  final double serverQuantity;
  final double offlineConsumedQuantity;
  final DateTime lastSyncedAt;

  double get availableQuantity => serverQuantity - offlineConsumedQuantity;

  String get staleLabel =>
      'Offline stock — last updated ${lastSyncedAt.toLocal().toIso8601String().substring(0, 16).replaceFirst('T', ' ')}';
}

/// Only what the POS needs to find and attach a customer offline: the ids,
/// name, mobile and email it already shows. No addresses, notes or loyalty
/// balances are cached.
class OfflineCustomer {
  const OfflineCustomer({
    required this.id,
    required this.customerId,
    required this.fullname,
    this.mobileno,
    this.email,
  });
  final int id;

  /// The customer reference a sale carries (`pos_sales.customer_id`).
  final String customerId;
  final String fullname;
  final String? mobileno;
  final String? email;

  static OfflineCustomer fromCustomer(Customer c) => OfflineCustomer(
    id: c.id,
    customerId: c.customerId,
    fullname: c.fullname,
    mobileno: c.mobileno,
    email: c.email,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'customer_id': customerId,
    'fullname': fullname,
    'mobileno': mobileno,
    'email': email,
  };

  static OfflineCustomer? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['id']);
    final cid = asString(m?['customer_id']);
    final name = asString(m?['fullname']);
    if (id == null || cid == null || name == null) return null;
    return OfflineCustomer(
      id: id,
      customerId: cid,
      fullname: name,
      mobileno: asString(m!['mobileno']),
      email: asString(m['email']),
    );
  }
}
