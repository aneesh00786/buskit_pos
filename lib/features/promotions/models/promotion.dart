import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// A promotion available to browse (`GET /promotions`). Read-only — POS has
/// no create/edit/delete/activate anywhere; promotions are defined entirely
/// by the existing Admin/Web system.
class Promotion {
  const Promotion({
    required this.id,
    required this.title,
    this.description,
    this.discountType,
    this.discountValue,
    this.maxDiscount,
    this.minOrderValue,
    this.startDate,
    this.endDate,
  });

  final int id;
  final String title;
  final String? description;
  final String? discountType;
  final double? discountValue;
  final double? maxDiscount;
  final double? minOrderValue;
  final DateTime? startDate;
  final DateTime? endDate;

  /// Short, human line for a card/list row, e.g. "10% off" or "$100 off".
  String get discountLabel {
    if (discountType == 'percentage' && discountValue != null) {
      return '${_trimZeros(discountValue!)}% off';
    }
    if (discountType == 'flat' && discountValue != null) {
      return '${_trimZeros(discountValue!)} off';
    }
    return title;
  }

  static Promotion? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final title = asString(m['title']);
    if (id == null || title == null) return null;
    return Promotion(
      id: id,
      title: title,
      description: asString(m['description']),
      discountType: asString(m['discount_type']),
      discountValue: asDouble(m['discount_value']),
      maxDiscount: asDouble(m['max_discount']),
      minOrderValue: asDouble(m['min_order_value']),
      startDate: parseServerTime(m['start_date']),
      endDate: parseServerTime(m['end_date']),
    );
  }
}

String _trimZeros(double v) {
  var s = v.toStringAsFixed(2);
  if (s.endsWith('00')) s = s.substring(0, s.length - 3);
  return s;
}

/// The promotion attached to a sale (the sale view's `promotion` field, or
/// one row of `GET /sales/:id/promotions`) — carries live eligibility, never
/// just the bare definition. `eligible: false` means it's still attached but
/// no longer usable (cart changed, it expired, etc.) — a non-blocking
/// warning the UI should surface, not something silently hidden.
class AppliedPromotion {
  const AppliedPromotion({
    required this.id,
    required this.title,
    this.discountType,
    this.discountValue,
    this.maxDiscount,
    required this.eligible,
    this.reasonCode,
    this.message,
    required this.discountAmount,
  });

  final int id;
  final String title;
  final String? discountType;
  final double? discountValue;
  final double? maxDiscount;
  final bool eligible;
  final String? reasonCode;
  final String? message;
  final double discountAmount;

  static AppliedPromotion? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final title = asString(m['title']);
    if (id == null || title == null) return null;
    return AppliedPromotion(
      id: id,
      title: title,
      discountType: asString(m['discount_type']),
      discountValue: asDouble(m['discount_value']),
      maxDiscount: asDouble(m['max_discount']),
      // Absent entirely on a completed sale's frozen snapshot (it's history,
      // not a live check) — default true there; the live sale view always
      // sends this field explicitly, true or false.
      eligible: asBool(m['eligible']) ?? true,
      reasonCode: asString(m['reason_code']),
      message: asString(m['message']),
      discountAmount: asDouble(m['discount_amount']) ?? 0,
    );
  }
}
