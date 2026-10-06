import '../../../core/utils/json_read.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/quantity.dart';
import '../../../core/utils/server_time.dart';
import '../../cart/models/cart_sale.dart';
import '../../cart/models/discount_override.dart';
import '../../history/models/partial_refund.dart';
import '../../history/models/provider_refund.dart';
import '../../loyalty/models/loyalty_sale_info.dart';
import '../../promotions/models/promotion.dart';

/// Tender types the backend accepts. Card and Other are RECORDED only — there
/// is no terminal or gateway integration.
enum TenderMethod {
  cash,
  card,
  other;

  String get wire => name;
  String get label => switch (this) {
    TenderMethod.cash => 'Cash',
    TenderMethod.card => 'Card',
    TenderMethod.other => 'Other',
  };

  static TenderMethod? fromWire(String? s) {
    for (final m in values) {
      if (m.name == s) return m;
    }
    return null;
  }
}

/// One payment line in the completion request.
class PaymentLine {
  const PaymentLine({
    required this.method,
    required this.amountMilli,
    this.tenderedMilli,
    this.reference,
    this.paymentAttemptId,
  });

  final TenderMethod method;
  final int amountMilli;

  /// Cash only (required by the backend, and >= [amountMilli]).
  final int? tenderedMilli;
  final String? reference;

  /// A CAPTURED provider payment (card terminal) backing this tender; the
  /// server verifies it belongs to the sale and matches the amount.
  final int? paymentAttemptId;

  Map<String, dynamic> toJson() => {
    'method': method.wire,
    'amount': milliToJson(amountMilli),
    if (method == TenderMethod.cash && tenderedMilli != null)
      'tendered_amount': milliToJson(tenderedMilli!),
    if (reference != null && reference!.trim().isNotEmpty)
      'reference': reference!.trim(),
    if (paymentAttemptId != null) 'payment_attempt_id': paymentAttemptId,
  };

  /// Stable text for comparing two attempts (idempotency-key reuse rule).
  String get canonical =>
      '${method.wire}:$amountMilli:${tenderedMilli ?? ''}:${reference?.trim() ?? ''}'
      '${paymentAttemptId == null ? '' : ':attempt=$paymentAttemptId'}';
}

/// A payment as recorded by the server (response of `complete`).
class RecordedPayment {
  const RecordedPayment({
    required this.method,
    this.amount,
    this.tendered,
    this.changeDue,
    this.status,
  });
  final String method;
  final double? amount;
  final double? tendered;
  final double? changeDue;
  final String? status;

  static RecordedPayment? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final method = asString(m['method']);
    if (method == null) return null;
    return RecordedPayment(
      method: method,
      amount: asDouble(m['amount']),
      tendered: asDouble(m['tendered_amount']),
      changeDue: asDouble(m['change_due']),
      status: asString(m['status']),
    );
  }
}

/// A FULL-SALE (Phase 17.1) refund, present once `POST /sales/:id/refund`
/// has succeeded. The backend never changes `pos_sales.status` for a refund
/// (it stays 'completed'). Partial refunds (Phase 17.8) are separate — see
/// [CompletedSale.refunds] / [CompletedSale.refundStatus].
class RefundInfo {
  const RefundInfo({
    required this.refundedBy,
    required this.refundAmount,
    this.refundedAt,
  });

  final String refundedBy;
  final double refundAmount;
  final DateTime? refundedAt;

  static RefundInfo? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final refundedBy = asString(m['refunded_by']);
    final amount = asDouble(m['refund_amount']);
    if (refundedBy == null || amount == null) return null;
    return RefundInfo(
      refundedBy: refundedBy,
      refundAmount: amount,
      refundedAt: parseServerTime(m['refunded_at']),
    );
  }
}

/// The immutable completed sale returned by `POST /sales/:id/complete`.
/// Items carry the server's snapshot figures but NO product names.
class CompletedSale {
  const CompletedSale({
    required this.id,
    required this.status,
    required this.items,
    required this.totals,
    required this.payments,
    this.saleNumber,
    this.completedAt,
    this.customerId,
    this.promotion,
    this.loyalty,
    this.refund,
    this.discountOverride,
    this.serverRefundStatus,
    this.refundedTotal,
    this.refundableTotal,
    this.refunds = const [],
    this.itemRefunds = const {},
    this.providerRefunds = const [],
  });

  final int id;
  final String status;
  final String? saleNumber;
  final DateTime? completedAt;
  final String? customerId;
  final List<CartLine> items;
  final CartTotals totals;
  final List<RecordedPayment> payments;

  /// The promotion applied at completion, frozen forever — a later edit or
  /// deletion of the source promotion can never change this receipt.
  final AppliedPromotion? promotion;

  /// Points/cashback earned, any tier discount/points/wallet redeemed —
  /// frozen forever at completion, same rule as [promotion].
  final LoyaltySaleInfo? loyalty;

  /// Non-null once this sale has been refunded (full-sale only). See
  /// [RefundInfo] — `status` itself never changes to reflect this.
  final RefundInfo? refund;

  /// The manual discount override in effect when this sale was completed,
  /// frozen forever — same rule as [promotion]/[loyalty].
  final DiscountOverride? discountOverride;

  /// `refund_status` exactly as the server sent it (null if absent).
  final SaleRefundStatus? serverRefundStatus;

  /// 'none' / 'partial' / 'full' (Phase 17.8). Falls back to [refund] for a
  /// server response that predates the field.
  SaleRefundStatus get refundStatus =>
      serverRefundStatus ??
      (refund != null ? SaleRefundStatus.full : SaleRefundStatus.none);

  final double? refundedTotal;
  final double? refundableTotal;

  /// Partial refunds, oldest first (empty for a 17.1 whole-sale refund).
  final List<PartialRefund> refunds;

  /// Per sale-item refund progress, keyed by sale item id.
  final Map<int, ItemRefundProgress> itemRefunds;

  /// Refunds returned through the payment provider (e.g. Razorpay UPI), with
  /// the provider's status.
  final List<ProviderRefund> providerRefunds;

  bool get hasPendingProviderRefunds =>
      providerRefunds.any((r) => r.status == ProviderRefundStatus.pending);

  /// Quantity of this line still refundable (Phase 12C: exact — an int for
  /// pieces, the decimal for a WEIGHT line). Without server data:
  /// everything, unless the sale was refunded as a whole.
  num refundableQuantity(CartLine line) =>
      itemRefunds[line.id]?.refundable ?? (refund != null ? 0 : line.quantity);

  num refundedQuantity(CartLine line) =>
      itemRefunds[line.id]?.refunded ?? (refund != null ? line.quantity : 0);

  /// The order/invoice number: the server's sale number, else "#id".
  String get displayNumber =>
      (saleNumber != null && saleNumber!.isNotEmpty) ? saleNumber! : '#$id';

  /// Total change the customer is owed, from the server's per-payment figures.
  double get changeDue => payments.fold(0.0, (a, p) => a + (p.changeDue ?? 0));

  static CompletedSale? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    if (id == null) return null;
    return CompletedSale(
      id: id,
      status: asString(m['status']) ?? 'completed',
      saleNumber: asString(m['sale_number']),
      completedAt: parseServerTime(m['completed_at']),
      customerId: asString(m['customer_id']),
      promotion: AppliedPromotion.fromJson(m['promotion']),
      loyalty: LoyaltySaleInfo.fromJson(m['loyalty']),
      refund: RefundInfo.fromJson(m['refund']),
      discountOverride: DiscountOverride.fromJson(m['discount_override']),
      serverRefundStatus: m.containsKey('refund_status')
          ? SaleRefundStatus.fromWire(asString(m['refund_status']))
          : null,
      refundedTotal: asDouble(m['refunded_total']),
      refundableTotal: asDouble(m['refundable_total']),
      refunds: asList(m['refunds'])
          .map(PartialRefund.fromJson)
          .whereType<PartialRefund>()
          .toList(),
      providerRefunds: asList(m['provider_refunds'])
          .map(ProviderRefund.fromJson)
          .whereType<ProviderRefund>()
          .toList(),
      // Phase 12C: exact (whole numbers stay ints; a WEIGHT line keeps its
      // decimals) — a decimal is never dropped or rounded.
      itemRefunds: {
        for (final raw in asList(m['items']))
          if (asMap(raw) case final i?
              when asInt(i['id']) != null &&
                  quantityMilliOf(i['refundable_quantity']) != null)
            asInt(i['id'])!: ItemRefundProgress(
              refunded: quantityFromMilli(
                quantityMilliOf(i['refunded_quantity']) ?? 0,
              ),
              refundable: quantityFromMilli(
                quantityMilliOf(i['refundable_quantity'])!,
              ),
            ),
      },
      items: asList(m['items'])
          .map(CartLine.fromJson)
          .whereType<CartLine>()
          .toList(),
      totals: CartTotals.fromJson(m['totals']),
      payments: asList(m['payments'])
          .map(RecordedPayment.fromJson)
          .whereType<RecordedPayment>()
          .toList(),
    );
  }
}
