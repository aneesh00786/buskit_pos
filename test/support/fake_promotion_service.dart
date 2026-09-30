import 'package:buskit_pos/features/promotions/data/promotion_service.dart';
import 'package:buskit_pos/features/promotions/models/promotion.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';

Map<String, dynamic> promotionJson({
  int id = 1,
  String title = 'Test 10% Off',
  String? description = '10% off everything',
  String? discountType = 'percentage',
  double? discountValue = 10,
  double? maxDiscount,
  double? minOrderValue,
  String? startDate,
  String? endDate,
}) => {
  'id': id,
  'title': title,

  'description': description,
  'discount_type': discountType,
  'discount_value': discountValue,
  'max_discount': maxDiscount,
  'min_order_value': minOrderValue,
  'start_date': startDate,
  'end_date': endDate,
};

class PromotionSearchCall {
  PromotionSearchCall(this.page, this.limit);
  final int page;
  final int limit;
}

class FakePromotionService implements PromotionService {
  final List<PromotionSearchCall> listCalls = [];
  final List<int> eligibleForSaleCalls = [];

  Future<PromotionPage> Function(PromotionSearchCall call) onList = (c) async =>
      PromotionPage(
        items: const [],
        pagination: Pagination(page: 1, limit: 20, total: 0, totalPages: 1),
      );
  Future<List<AppliedPromotion>> Function(int saleId) onEligibleForSale = (
    _,
  ) async => const [];

  @override
  Future<PromotionPage> listPromotions({int page = 1, int limit = 20}) {
    final c = PromotionSearchCall(page, limit);
    listCalls.add(c);
    return onList(c);
  }

  @override
  Future<List<AppliedPromotion>> listEligibleForSale(int saleId) {
    eligibleForSaleCalls.add(saleId);
    return onEligibleForSale(saleId);
  }
}
