import '../../../core/utils/json_read.dart';

/// The manual discount currently applied to a sale, if any — the live sale
/// view's/completed sale's `discount_override` field. EVERY manual discount
/// is an override (the `discounts.override` permission) — there is no
/// "normal discount" tier anywhere in this system; promotion and loyalty
/// remain the only automatic discount sources, untouched by this.
class DiscountOverride {
  const DiscountOverride({
    required this.discountType,
    required this.discountValue,
    this.discountAmount,
    this.reason,
    this.appliedBy,
  });

  /// 'percentage' or 'flat'.
  final String discountType;
  final double discountValue;

  /// The live computed amount — present on the draft sale view; the
  /// completed-sale snapshot omits it (the amount is already correctly
  /// folded into `totals.discount_total`/each item's `discount_amount`).
  final double? discountAmount;
  final String? reason;
  final String? appliedBy;

  static DiscountOverride? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final type = asString(m['discount_type']);
    final value = asDouble(m['discount_value']);
    if (type == null || value == null) return null;
    return DiscountOverride(
      discountType: type,
      discountValue: value,
      discountAmount: asDouble(m['discount_amount']),
      reason: asString(m['reason']),
      appliedBy: asString(m['applied_by']),
    );
  }
}
