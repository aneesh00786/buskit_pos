import '../../../core/utils/json_read.dart';

/// A line's own discount (backend migration 055), exactly as the server sent
/// it: on a draft the live amount, on a completed sale the frozen one. The
/// server computes every amount; nothing here is calculated.
class LineDiscount {
  const LineDiscount({
    required this.type,
    required this.value,
    this.amount,
    this.reason,
    this.appliedBy,
    this.authority,
  });

  /// 'percentage' or 'flat' (one amount for the whole line).
  final String type;
  final double value;
  final double? amount;
  final String? reason;
  final String? appliedBy;
  final String? authority;

  bool get isPercentage => type == 'percentage';

  static LineDiscount? fromJson(Object? json) {
    final m = asMap(json);
    final type = asString(m?['discount_type']);
    final value = asDouble(m?['discount_value']);
    if (type == null || value == null) return null;
    return LineDiscount(
      type: type,
      value: value,
      amount: asDouble(m?['discount_amount']),
      reason: asString(m?['reason']),
      appliedBy: asString(m?['applied_by']),
      authority: asString(m?['authority']),
    );
  }
}

/// A per-sale unit-price override of one line (never the catalogue price).
class LinePriceOverride {
  const LinePriceOverride({
    required this.originalUnitPrice,
    required this.unitPrice,
    this.reason,
    this.appliedBy,
  });

  /// The catalogue / POS price the server had in effect.
  final double originalUnitPrice;
  final double unitPrice;
  final String? reason;
  final String? appliedBy;

  static LinePriceOverride? fromJson(Object? json) {
    final m = asMap(json);
    final original = asDouble(m?['original_unit_price']);
    final unit = asDouble(m?['unit_price']);
    if (original == null || unit == null) return null;
    return LinePriceOverride(
      originalUnitPrice: original,
      unitPrice: unit,
      reason: asString(m?['reason']),
      appliedBy: asString(m?['applied_by']),
    );
  }
}

/// Sent with an add-item response when the product was merged into a line
/// that has a line discount or a price override.
class MergeNotice {
  const MergeNotice({required this.itemId, required this.message});
  final int itemId;
  final String message;

  static MergeNotice? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['item_id']);
    final message = asString(m?['message']);
    if (id == null || message == null || message.isEmpty) return null;
    return MergeNotice(itemId: id, message: message);
  }

  /// Cashier-facing sentence.
  String get text =>
      'Added to the existing line: ${message[0].toLowerCase()}${message.substring(1)}.';
}

/// What THIS signed-in staff member may do (`GET /discount-policy`). Only
/// drives which controls are offered — the server checks every request.
class DiscountPolicy {
  const DiscountPolicy({
    this.lineDiscountAuthority,
    this.lineDiscountMaxPercent = 0,
    this.limitSource,
    this.canOverridePrice = false,
  });

  /// 'discounts.override' | 'discounts.apply' | null (none).
  final String? lineDiscountAuthority;

  /// The most this staff member may discount a line (0 = none).
  final double lineDiscountMaxPercent;

  /// 'override' | 'individual' | 'role' | null.
  final String? limitSource;
  final bool canOverridePrice;

  bool get canDiscount =>
      lineDiscountAuthority != null && lineDiscountMaxPercent > 0;

  static DiscountPolicy fromJson(Object? json) {
    final m = asMap(json);
    return DiscountPolicy(
      lineDiscountAuthority: asString(m?['line_discount_authority']),
      lineDiscountMaxPercent: asDouble(m?['line_discount_max_percent']) ?? 0,
      limitSource: asString(m?['limit_source']),
      canOverridePrice: m?['can_override_price'] == true,
    );
  }
}
