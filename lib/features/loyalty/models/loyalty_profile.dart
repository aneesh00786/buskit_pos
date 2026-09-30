import '../../../core/utils/json_read.dart';
import 'loyalty_tier.dart';

/// `GET /customers/:id/loyalty` — read-only. `enabled: false` means this
/// company has no active loyalty program at all (not an error — POS never
/// invents one); every other field is meaningless in that case.
class LoyaltyProfile {
  const LoyaltyProfile({
    required this.enabled,
    this.tier,
    this.pointsBalance = 0,
    this.walletBalance = 0,
    this.nextTier,
  });

  final bool enabled;
  final LoyaltyTier? tier;
  final double pointsBalance;
  final double walletBalance;
  final NextTierInfo? nextTier;

  static const disabled = LoyaltyProfile(enabled: false);

  static LoyaltyProfile fromJson(Object? json) {
    final m = asMap(json);
    if (m == null || asBool(m['enabled']) != true) return disabled;
    return LoyaltyProfile(
      enabled: true,
      tier: LoyaltyTier.fromJson(m['tier']),
      pointsBalance: asDouble(m['points_balance']) ?? 0,
      walletBalance: asDouble(m['wallet_balance']) ?? 0,
      nextTier: NextTierInfo.fromJson(m['next_tier']),
    );
  }
}
