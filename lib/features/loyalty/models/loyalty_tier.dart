import '../../../core/utils/json_read.dart';

/// A customer's loyalty tier — admin-assigned (POS never sets or computes
/// tier transitions; see the backend's posLoyaltyEngine.js for why).
class LoyaltyTier {
  const LoyaltyTier({
    this.id,
    required this.name,
    this.discountPercentage,
    this.pointsMultiplier,
  });

  final int? id;
  final String name;
  final double? discountPercentage;
  final double? pointsMultiplier;

  static LoyaltyTier? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final name = asString(m['name']);
    if (name == null) return null;
    return LoyaltyTier(
      id: asInt(m['id']),
      name: name,
      discountPercentage: asDouble(m['discount_percentage']),
      pointsMultiplier: asDouble(m['points_multiplier']),
    );
  }
}

/// How much further (POS-visible) spend is needed to reach the next tier.
/// Only reflects spend seen by this POS — cross-channel spend isn't visible
/// here, so this is a partial, honestly-labelled figure, not a guarantee.
class NextTierInfo {
  const NextTierInfo({required this.name, required this.remainingSpend});
  final String name;
  final double remainingSpend;

  static NextTierInfo? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final name = asString(m['name']);
    final remaining = asDouble(m['remaining_spend']);
    if (name == null || remaining == null) return null;
    return NextTierInfo(name: name, remainingSpend: remaining);
  }
}
