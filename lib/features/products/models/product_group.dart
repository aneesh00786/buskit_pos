import 'product_item.dart';

/// The backend returns one flat row per variation. A [ProductGroup] gathers
/// the rows that share a `product_id` so variations can be shown together.
class ProductGroup {
  ProductGroup({
    required this.key,
    required this.name,
    required this.variations,
  });

  final String key;
  final String name;
  final List<ProductItem> variations;

  bool get hasMultipleVariations => variations.length > 1;
  ProductItem get first => variations.first;
  String? get imageUrl => variations
      .map((v) => v.imageUrl)
      .firstWhere((u) => u != null, orElse: () => null);

  double? get minPrice =>
      _prices.isEmpty ? null : _prices.reduce((a, b) => a < b ? a : b);
  double? get maxPrice =>
      _prices.isEmpty ? null : _prices.reduce((a, b) => a > b ? a : b);
  Iterable<double> get _prices =>
      variations.map((v) => v.pricing.sellPrice).whereType<double>();

  /// Groups in first-seen order; a product whose variations straddle a page
  /// boundary is merged when the next page is appended.
  static List<ProductGroup> group(Iterable<ProductItem> items) {
    final map = <String, ProductGroup>{};
    for (final it in items) {
      final key = it.productId != null && it.productId!.isNotEmpty
          ? 'p:${it.productId}'
          : 'v:${it.id}';
      final g = map.putIfAbsent(
        key,
        () => ProductGroup(key: key, name: it.productName, variations: []),
      );
      if (!g.variations.any((v) => v.id == it.id)) g.variations.add(it);
    }
    return map.values.toList();
  }
}
