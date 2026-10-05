import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// A completed sale's refund state (`refund_status`, Phase 17.8). `full`
/// covers both a 17.1 whole-sale refund and partial refunds that have used
/// up every line.
enum SaleRefundStatus {
  none,
  partial,
  full;

  static SaleRefundStatus fromWire(String? s) => switch (s) {
    'partial' => SaleRefundStatus.partial,
    'full' => SaleRefundStatus.full,
    _ => SaleRefundStatus.none,
  };

  String? get label => switch (this) {
    SaleRefundStatus.none => null,
    SaleRefundStatus.partial => 'Partially refunded',
    SaleRefundStatus.full => 'Refunded',
  };
}

/// One line of a refund request: quantity-based only (no amount field —
/// every amount is computed by the server).
class RefundRequestLine {
  const RefundRequestLine({
    required this.saleItemId,
    required this.quantity,
    this.damagedQuantity = 0,
  });

  final int saleItemId;
  final int quantity;
  final int damagedQuantity;

  Map<String, dynamic> toJson() => {
    'sale_item_id': saleItemId,
    'quantity': quantity,
    if (damagedQuantity > 0) 'damaged_quantity': damagedQuantity,
  };

  String get canonical => '$saleItemId:$quantity:$damagedQuantity';
}

class RefundPayout {
  const RefundPayout({required this.method, required this.amount});
  final String method;
  final double amount;

  static RefundPayout? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final method = asString(m['method']);
    final amount = asDouble(m['amount']);
    if (method == null || amount == null) return null;
    return RefundPayout(method: method, amount: amount);
  }
}

/// One refunded line, as computed (preview) or recorded (history) by the
/// server.
class RefundLine {
  const RefundLine({
    required this.saleItemId,
    required this.quantity,
    required this.refundAmount,
    this.damagedQuantity = 0,
    this.restockedQuantity,
    this.unitPrice,
    this.subtotalAmount,
    this.discountAmount,
    this.taxAmount,
  });

  final int saleItemId;
  final int quantity;
  final int damagedQuantity;
  final int? restockedQuantity;
  final double? unitPrice;
  final double? subtotalAmount;
  final double? discountAmount;
  final double? taxAmount;
  final double refundAmount;

  static RefundLine? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['sale_item_id']);
    final qty = asInt(m['quantity']);
    final amount = asDouble(m['refund_amount']);
    if (id == null || qty == null || amount == null) return null;
    return RefundLine(
      saleItemId: id,
      quantity: qty,
      damagedQuantity: asInt(m['damaged_quantity']) ?? 0,
      restockedQuantity: asInt(m['restocked_quantity']),
      unitPrice: asDouble(m['unit_price']),
      subtotalAmount: asDouble(m['subtotal_amount']),
      discountAmount: asDouble(m['discount_amount']),
      taxAmount: asDouble(m['tax_amount']),
      refundAmount: amount,
    );
  }
}

/// Loyalty effects reversed by a refund (all zero for a sale without loyalty).
class RefundLoyalty {
  const RefundLoyalty({
    this.pointsEarnedReversed = 0,
    this.pointsRedeemedReturned = 0,
    this.cashbackReversed = 0,
    this.walletReturned = 0,
  });

  final int pointsEarnedReversed;
  final int pointsRedeemedReturned;
  final double cashbackReversed;
  final double walletReturned;

  bool get isEmpty =>
      pointsEarnedReversed == 0 &&
      pointsRedeemedReturned == 0 &&
      cashbackReversed == 0 &&
      walletReturned == 0;

  static RefundLoyalty fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return const RefundLoyalty();
    return RefundLoyalty(
      pointsEarnedReversed: asInt(m['points_earned_reversed']) ?? 0,
      pointsRedeemedReturned: asInt(m['points_redeemed_returned']) ?? 0,
      cashbackReversed: asDouble(m['cashback_reversed']) ?? 0,
      walletReturned: asDouble(m['wallet_returned']) ?? 0,
    );
  }
}

/// Shared money breakdown of a preview or a recorded refund.
abstract class RefundAmounts {
  double get refundAmount;
  double? get subtotalAmount;
  double? get discountAmount;
  double? get taxAmount;
  double get walletAmount;
  List<RefundPayout> get payouts;
  List<RefundLine> get items;
  RefundLoyalty get loyalty;
}

/// `POST /sales/:id/refunds/preview` — the server's authoritative
/// calculation. Nothing is written; the POS sends [refundAmount] back as
/// `expected_refund_amount` so the server can reject a stale preview.
class RefundPreview implements RefundAmounts {
  const RefundPreview({
    required this.refundAmount,
    required this.items,
    this.subtotalAmount,
    this.discountAmount,
    this.taxAmount,
    this.walletAmount = 0,
    this.payouts = const [],
    this.loyalty = const RefundLoyalty(),
    this.fullyRefundedAfter = false,
    this.remainingAfter,
  });

  @override
  final double refundAmount;
  @override
  final double? subtotalAmount;
  @override
  final double? discountAmount;
  @override
  final double? taxAmount;
  @override
  final double walletAmount;
  @override
  final List<RefundPayout> payouts;
  @override
  final List<RefundLine> items;
  @override
  final RefundLoyalty loyalty;
  final bool fullyRefundedAfter;
  final double? remainingAfter;

  static RefundPreview? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final amount = asDouble(m['refund_amount']);
    if (amount == null) return null;
    return RefundPreview(
      refundAmount: amount,
      subtotalAmount: asDouble(m['subtotal_amount']),
      discountAmount: asDouble(m['discount_amount']),
      taxAmount: asDouble(m['tax_amount']),
      walletAmount: asDouble(m['wallet_amount']) ?? 0,
      payouts: asList(m['payouts']).map(RefundPayout.fromJson).whereType<RefundPayout>().toList(),
      items: asList(m['items']).map(RefundLine.fromJson).whereType<RefundLine>().toList(),
      loyalty: RefundLoyalty.fromJson(m['loyalty']),
      fullyRefundedAfter: m['fully_refunded_after'] == true,
      remainingAfter: asDouble(m['remaining_refundable_after']),
    );
  }
}

/// One recorded partial refund (the sale view's `refunds[]`, oldest-first).
class PartialRefund implements RefundAmounts {
  const PartialRefund({
    required this.id,
    required this.refundAmount,
    required this.items,
    this.subtotalAmount,
    this.discountAmount,
    this.taxAmount,
    this.walletAmount = 0,
    this.payouts = const [],
    this.loyalty = const RefundLoyalty(),
    this.reason,
    this.refundedBy,
    this.refundedAt,
  });

  final int id;
  @override
  final double refundAmount;
  @override
  final double? subtotalAmount;
  @override
  final double? discountAmount;
  @override
  final double? taxAmount;
  @override
  final double walletAmount;
  @override
  final List<RefundPayout> payouts;
  @override
  final List<RefundLine> items;
  @override
  final RefundLoyalty loyalty;
  final String? reason;
  final String? refundedBy;
  final DateTime? refundedAt;

  int get unitCount => items.fold(0, (s, i) => s + i.quantity);

  static PartialRefund? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final amount = asDouble(m['refund_amount']);
    if (id == null || amount == null) return null;
    return PartialRefund(
      id: id,
      refundAmount: amount,
      subtotalAmount: asDouble(m['subtotal_amount']),
      discountAmount: asDouble(m['discount_amount']),
      taxAmount: asDouble(m['tax_amount']),
      walletAmount: asDouble(m['wallet_amount']) ?? 0,
      payouts: asList(m['payouts']).map(RefundPayout.fromJson).whereType<RefundPayout>().toList(),
      items: asList(m['items']).map(RefundLine.fromJson).whereType<RefundLine>().toList(),
      loyalty: RefundLoyalty.fromJson(m['loyalty']),
      reason: asString(m['reason']),
      refundedBy: asString(m['refunded_by']),
      refundedAt: parseServerTime(m['refunded_at']),
    );
  }
}

/// Per-line refund progress from the sale view's items.
class ItemRefundProgress {
  const ItemRefundProgress({required this.refunded, required this.refundable});
  final int refunded;
  final int refundable;
}
