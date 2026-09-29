import 'package:buskit_pos/features/promotions/models/promotion.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_promotion_service.dart';
import '../../support/fakes.dart' show appliedPromotionJson;

void main() {
  group('Promotion.fromJson', () {
    test('parses a full row', () {
      final p = Promotion.fromJson(
        promotionJson(
          id: 1,
          title: '10% OFF',
          description: 'Sitewide',
          discountType: 'percentage',
          discountValue: 10,
          maxDiscount: 500,
          minOrderValue: 1000,
          endDate: '2026-09-30 00:00:00',
        ),
      )!;
      expect(p.id, 1);
      expect(p.title, '10% OFF');
      expect(p.description, 'Sitewide');
      expect(p.discountType, 'percentage');
      expect(p.discountValue, 10);
      expect(p.maxDiscount, 500);
      expect(p.minOrderValue, 1000);
      expect(p.endDate, isNotNull);
    });

    test('missing id or title yields null (no crash on a malformed row)', () {
      final row = promotionJson();
      expect(Promotion.fromJson({...row, 'id': null}), isNull);
      expect(Promotion.fromJson({...row, 'title': null}), isNull);
      expect(Promotion.fromJson(null), isNull);
      expect(Promotion.fromJson('not a map'), isNull);
    });

    test('discountLabel reads percentage and flat types, falling back to the title', () {
      expect(
        Promotion.fromJson(
          promotionJson(discountType: 'percentage', discountValue: 10),
        )!.discountLabel,
        '10% off',
      );
      expect(
        Promotion.fromJson(
          promotionJson(discountType: 'flat', discountValue: 100),
        )!.discountLabel,
        '100 off',
      );
      expect(
        Promotion.fromJson(
          promotionJson(
            title: 'Mystery Deal',
            discountType: null,
            discountValue: null,
          ),
        )!.discountLabel,
        'Mystery Deal',
      );
    });
  });

  group('AppliedPromotion.fromJson', () {
    test(
      'parses eligibility and the discount already computed by the server',
      () {
        final p = AppliedPromotion.fromJson(
          appliedPromotionJson(
            eligible: false,
            reasonCode: 'PROMOTION_MINIMUM_AMOUNT_NOT_MET',
            message: 'Minimum purchase amount is 1000.',
            discountAmount: 0,
          ),
        )!;
        expect(p.eligible, isFalse);
        expect(p.reasonCode, 'PROMOTION_MINIMUM_AMOUNT_NOT_MET');
        expect(p.message, 'Minimum purchase amount is 1000.');
      },
    );

    test('defaults eligible to true when the field is absent (a completed-sale snapshot)', () {
      final p = AppliedPromotion.fromJson({
        'id': 1,
        'title': '10% OFF',
        'discount_type': 'percentage',
        'discount_value': 10,
        'discount_amount': 500,
      })!;
      expect(p.eligible, isTrue);
      expect(p.discountAmount, 500);
    });

    test('missing id or title yields null', () {
      expect(AppliedPromotion.fromJson(null), isNull);
      expect(
        AppliedPromotion.fromJson({...appliedPromotionJson(), 'id': null}),
        isNull,
      );
    });
  });
}
