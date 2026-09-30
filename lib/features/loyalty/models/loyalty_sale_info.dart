import '../../../core/utils/json_read.dart';
import 'loyalty_tier.dart';

/// The loyalty state folded onto a sale — the draft view's `loyalty` field
/// (live, with a balance/eligibility preview) or a completed sale's `loyalty`
/// field (frozen forever at completion). The two shapes differ slightly
/// (draft: `points_to_earn`/`cashback_to_earn`/`points_balance`/
/// `wallet_balance`/`eligible`; completed: `points_earned`/`cashback_earned`,
/// no live balance) — this model reads either tolerantly, since a receipt and
/// a live cart panel both just want "what happened/will happen here."
class LoyaltySaleInfo {
  const LoyaltySaleInfo({
    this.tier,
    this.pointsBalance,
    this.walletBalance,
    this.tierDiscountAmount = 0,
    this.pointsRedeemed = 0,
    this.pointsRedeemedValue = 0,
    this.pointsEarned = 0,
    this.walletRedeemed = 0,
    this.cashbackEarned = 0,
    this.eligible = true,
    this.reasonCode,
    this.message,
  });

  final LoyaltyTier? tier;

  /// Only present on the live draft view — a completed sale shows what
  /// happened, not the running balance (see the profile endpoint for that).
  final double? pointsBalance;
  final double? walletBalance;

  final double tierDiscountAmount;
  final int pointsRedeemed;
  final double pointsRedeemedValue;
  final int pointsEarned;
  final double walletRedeemed;
  final double cashbackEarned;

  /// False means a requested points/wallet redemption is no longer valid
  /// (balance changed, etc.) — shown, never silently dropped. Always true on
  /// a completed sale (nothing invalid could have survived to completion).
  final bool eligible;
  final String? reasonCode;
  final String? message;

  static LoyaltySaleInfo? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    return LoyaltySaleInfo(
      tier: LoyaltyTier.fromJson(m['tier']),
      pointsBalance: asDouble(m['points_balance']),
      walletBalance: asDouble(m['wallet_balance']),
      tierDiscountAmount: asDouble(m['tier_discount_amount']) ?? 0,
      pointsRedeemed: asInt(m['points_redeemed']) ?? 0,
      pointsRedeemedValue: asDouble(m['points_redeemed_value']) ?? 0,
      pointsEarned:
          asInt(m['points_earned']) ?? asInt(m['points_to_earn']) ?? 0,
      walletRedeemed: asDouble(m['wallet_redeemed']) ?? 0,
      cashbackEarned:
          asDouble(m['cashback_earned']) ??
          asDouble(m['cashback_to_earn']) ??
          0,
      eligible: asBool(m['eligible']) ?? true,
      reasonCode: asString(m['reason_code']),
      message: asString(m['message']),
    );
  }
}
