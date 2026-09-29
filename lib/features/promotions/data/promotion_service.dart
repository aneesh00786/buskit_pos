import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../products/models/product_page.dart';
import '../models/promotion.dart';

/// One page of `GET /promotions`.
class PromotionPage {
  const PromotionPage({required this.items, required this.pagination});
  final List<Promotion> items;
  final Pagination pagination;

  bool get hasMore => pagination.page < pagination.totalPages;

  factory PromotionPage.fromJson(
    Object? json, {
    int requestedPage = 1,
    int requestedLimit = 20,
  }) {
    final m = asMap(json) ?? const <String, dynamic>{};
    final items = asList(m['items'])
        .map(Promotion.fromJson)
        .whereType<Promotion>()
        .toList();
    final pg = asMap(m['pagination']) ?? const <String, dynamic>{};
    final totalPages = asInt(pg['total_pages']) ?? 1;
    return PromotionPage(
      items: items,
      pagination: Pagination(
        page: asInt(pg['page']) ?? requestedPage,
        limit: asInt(pg['limit']) ?? requestedLimit,
        total: asInt(pg['total']) ?? items.length,
        totalPages: totalPages < 1 ? 1 : totalPages,
      ),
    );
  }
}

abstract class PromotionService {
  Future<PromotionPage> listPromotions({int page = 1, int limit = 20});

  /// Only the promotions currently eligible for this sale's live lines/
  /// customer — each already carries its computed discount.
  Future<List<AppliedPromotion>> listEligibleForSale(int saleId);
}

/// Verified against the backend: `GET /promotions`, `GET /sales/:id/promotions`
/// — POS-scoped from the device/staff token, never a client-supplied company
/// id. No create/edit/delete anywhere — promotions are Admin/Web-owned.
class ApiPromotionService implements PromotionService {
  ApiPromotionService(this._client);
  final PosApiClient _client;

  @override
  Future<PromotionPage> listPromotions({int page = 1, int limit = 20}) async {
    final data = await _client.get(
      '/promotions',
      query: {'page': '$page', 'limit': '$limit'},
    );
    return PromotionPage.fromJson(
      data,
      requestedPage: page,
      requestedLimit: limit,
    );
  }

  @override
  Future<List<AppliedPromotion>> listEligibleForSale(int saleId) async {
    final data = await _client.get('/sales/$saleId/promotions');
    final m = asMap(data) ?? const <String, dynamic>{};
    return asList(m['items'])
        .map(AppliedPromotion.fromJson)
        .whereType<AppliedPromotion>()
        .toList();
  }
}
