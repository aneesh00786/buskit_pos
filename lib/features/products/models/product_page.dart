import '../../../core/utils/json_read.dart';
import 'product_item.dart';

class Pagination {
  const Pagination({
    required this.page,
    required this.limit,
    required this.total,
    required this.totalPages,
  });
  final int page;
  final int limit;
  final int total;
  final int totalPages;
}

/// One page of `GET /products`.
class ProductPage {
  const ProductPage({
    required this.items,
    required this.pagination,
    this.skipped = 0,
  });
  final List<ProductItem> items;
  final Pagination pagination;

  /// Rows discarded because they had no usable id.
  final int skipped;

  bool get hasMore => pagination.page < pagination.totalPages;

  factory ProductPage.fromJson(
    Object? json, {
    int requestedPage = 1,
    int requestedLimit = 20,
  }) {
    final m = asMap(json) ?? const <String, dynamic>{};
    final raw = asList(m['items']);
    final items = <ProductItem>[];
    for (final r in raw) {
      final p = ProductItem.fromJson(r);
      if (p != null) items.add(p);
    }
    final pg = asMap(m['pagination']) ?? const <String, dynamic>{};
    final page = asInt(pg['page']) ?? requestedPage;
    final total = asInt(pg['total']) ?? items.length;
    final limit = asInt(pg['limit']) ?? requestedLimit;
    final totalPages = asInt(pg['total_pages']) ?? 1;
    return ProductPage(
      items: items,
      skipped: raw.length - items.length,
      pagination: Pagination(
        page: page,
        limit: limit,
        total: total,
        totalPages: totalPages < 1 ? 1 : totalPages,
      ),
    );
  }
}
