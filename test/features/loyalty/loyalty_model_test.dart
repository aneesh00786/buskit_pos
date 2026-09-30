import 'package:buskit_pos/features/loyalty/models/loyalty_profile.dart';
import 'package:buskit_pos/features/loyalty/models/loyalty_sale_info.dart';
import 'package:buskit_pos/features/loyalty/models/loyalty_tier.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LoyaltyTier.fromJson', () {
    test('parses a full row', () {
      final t = LoyaltyTier.fromJson({
        'id': 2,
        'name': 'Gold',
        'discount_percentage': 5.0,
        'points_multiplier': 2.0,
      })!;
      expect(
        (t.id, t.name, t.discountPercentage, t.pointsMultiplier),
        (2, 'Gold', 5.0, 2.0),
      );
    });

    test('a missing name yields null', () {
      expect(LoyaltyTier.fromJson({'id': 1}), isNull);
      expect(LoyaltyTier.fromJson(null), isNull);
    });
  });

  group('NextTierInfo.fromJson', () {
    test('parses a full row', () {
      final n = NextTierInfo.fromJson({
        'name': 'Gold',
        'remaining_spend': 2500.0,
      })!;
      expect((n.name, n.remainingSpend), ('Gold', 2500.0));
    });

    test('a missing field yields null', () {
      expect(NextTierInfo.fromJson({'name': 'Gold'}), isNull);
    });
  });

  group('LoyaltyProfile.fromJson', () {
    test('enabled: false collapses to the disabled singleton regardless of other fields', () {
      final p = LoyaltyProfile.fromJson({
        'enabled': false,
        'points_balance': 999,
      });
      expect(p.enabled, isFalse);
      expect(p.pointsBalance, 0);
      expect(identical(p, LoyaltyProfile.disabled), isTrue);
    });

    test('a non-map or missing enabled field is treated as disabled', () {
      expect(LoyaltyProfile.fromJson(null).enabled, isFalse);
      expect(LoyaltyProfile.fromJson({}).enabled, isFalse);
    });

    test('parses a full enabled profile', () {
      final p = LoyaltyProfile.fromJson({
        'enabled': true,
        'tier': {'id': 1, 'name': 'Silver', 'discount_percentage': 0},
        'points_balance': 1280,
        'wallet_balance': 245.5,
        'next_tier': {'name': 'Gold', 'remaining_spend': 2500},
      });
      expect(p.enabled, isTrue);
      expect(p.tier!.name, 'Silver');
      expect(p.pointsBalance, 1280);
      expect(p.walletBalance, 245.5);
      expect(p.nextTier!.name, 'Gold');
    });
  });

  group('LoyaltySaleInfo.fromJson', () {
    test(
      'reads the draft-view field names (points_to_earn/cashback_to_earn)',
      () {
        final l = LoyaltySaleInfo.fromJson({
          'tier': {'name': 'Gold'},
          'points_balance': 1280,
          'wallet_balance': 245.5,
          'tier_discount_amount': 10,
          'points_redeemed': 500,
          'points_redeemed_value': 50,
          'wallet_redeemed': 0,
          'points_to_earn': 120,
          'cashback_to_earn': 12.5,
          'eligible': true,
        })!;
        expect(l.pointsEarned, 120);
        expect(l.cashbackEarned, 12.5);
        expect(l.pointsBalance, 1280);
        expect(l.eligible, isTrue);
      },
    );

    test(
      'reads the completed-sale field names (points_earned/cashback_earned)',
      () {
        final l = LoyaltySaleInfo.fromJson({
          'points_earned': 120,
          'cashback_earned': 12.5,
          'wallet_redeemed': 10,
        })!;
        expect(l.pointsEarned, 120);
        expect(l.cashbackEarned, 12.5);
        expect(l.walletRedeemed, 10);
        // A completed sale carries no live balance.
        expect(l.pointsBalance, isNull);
        expect(l.walletBalance, isNull);
      },
    );

    test('an ineligible pending redemption carries its reason, not silently dropped', () {
      final l = LoyaltySaleInfo.fromJson({
        'eligible': false,
        'reason_code': 'LOYALTY_INSUFFICIENT_POINTS',
        'message': 'Insufficient points balance.',
      })!;
      expect(l.eligible, isFalse);
      expect(l.reasonCode, 'LOYALTY_INSUFFICIENT_POINTS');
      expect(l.message, 'Insufficient points balance.');
    });

    test('missing numeric fields default to zero, not null', () {
      final l = LoyaltySaleInfo.fromJson({})!;
      expect(
        (
          l.tierDiscountAmount,
          l.pointsRedeemed,
          l.pointsRedeemedValue,
          l.pointsEarned,
          l.walletRedeemed,
          l.cashbackEarned,
        ),
        (0.0, 0, 0.0, 0, 0.0, 0.0),
      );
      expect(l.eligible, isTrue);
    });

    test('a non-map response yields null', () {
      expect(LoyaltySaleInfo.fromJson(null), isNull);
      expect(LoyaltySaleInfo.fromJson('not a map'), isNull);
    });
  });
}
