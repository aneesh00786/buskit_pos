import '../../../core/utils/json_read.dart';

/// A POS category from `GET /categories` (`{cid, category}` rows).
class ProductCategory {
  const ProductCategory({required this.id, required this.name});
  final int id;
  final String name;

  static ProductCategory? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['cid']) ?? asInt(m['id']);
    if (id == null) return null;
    final name = asString(m['category']) ?? asString(m['name']);
    return ProductCategory(
      id: id,
      name: (name == null || name.trim().isEmpty)
          ? 'Category $id'
          : name.trim(),
    );
  }
}
