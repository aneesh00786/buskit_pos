import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/category.dart';
import '../models/product_page.dart';

abstract class ProductService {
  Future<ProductPage> search({
    String? query,
    int? categoryId,
    String? brand,
    int page = 1,
    int limit = 20,
  });
  Future<List<ProductCategory>> categories();
}

/// Verified against the backend: `GET /products?q=&category_id=&brand=&page=&limit=`
/// (limit 1–100, q ≤ 100 chars) and `GET /categories`.
class ApiProductService implements ProductService {
  ApiProductService(this._client);
  final PosApiClient _client;

  static const maxQueryLength = 100;

  @override
  Future<ProductPage> search({
    String? query,
    int? categoryId,
    String? brand,
    int page = 1,
    int limit = 20,
  }) async {
    final q = <String, String>{'page': '$page', 'limit': '$limit'};
    final text = query?.trim();
    if (text != null && text.isNotEmpty) {
      q['q'] = text.length > maxQueryLength
          ? text.substring(0, maxQueryLength)
          : text;
    }
    if (categoryId != null) q['category_id'] = '$categoryId';
    if (brand != null && brand.trim().isNotEmpty) q['brand'] = brand.trim();
    final data = await _client.get('/products', query: q);
    return ProductPage.fromJson(
      data,
      requestedPage: page,
      requestedLimit: limit,
    );
  }

  @override
  Future<List<ProductCategory>> categories() async {
    final data = await _client.get('/categories');
    return asList(data)
        .map(ProductCategory.fromJson)
        .whereType<ProductCategory>()
        .toList();
  }
}
