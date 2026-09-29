import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/category.dart';
import '../models/product_item.dart';
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

  /// The sellable variation whose barcode is [barcode], or null if the store
  /// has none.
  Future<ProductItem?> findByBarcode(String barcode);

  /// The product variation with this `product_variation_id`, or null if it no
  /// longer exists. Used to resolve names for old sales (the completed-sale
  /// view never carries product names).
  Future<ProductItem?> findById(int id);
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

  /// `GET /products/barcode/:barcode` (1–50 chars): the product, or 404.
  @override
  Future<ProductItem?> findByBarcode(String barcode) async {
    try {
      final data = await _client.get(
        '/products/barcode/${Uri.encodeComponent(barcode)}',
      );
      return ProductItem.fromJson(data);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// `GET /products/:id`: the product, or null on a 404 (deleted/unavailable).
  @override
  Future<ProductItem?> findById(int id) async {
    try {
      final data = await _client.get('/products/$id');
      return ProductItem.fromJson(data);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return null;
      rethrow;
    }
  }
}
