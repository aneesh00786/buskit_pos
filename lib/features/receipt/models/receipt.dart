import '../../../core/utils/server_time.dart';

/// One printed line of the receipt.
class ReceiptLine {
  const ReceiptLine({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    this.variant,
    this.taxNote,
    this.barcode,
    this.notes = const [],
  });

  final String name;

  /// The product's barcode when the sale line has one (Phase 11A; shown only
  /// when a layout asks for it).
  final String? barcode;

  /// Variation / unit label remembered from the cart (display only).
  final String? variant;

  /// Whole number for pieces; the exact decimal for a weighed line (Phase
  /// 12B), printed with 3 decimals.
  final num quantity;

  /// Server figures, already formatted for display (e.g. `50.00`).
  final String unitPrice;
  final String lineTotal;
  final String? taxNote;

  /// Backend migration 055: (label, amount) rows printed under the line — a
  /// per-sale price change ("Price changed from 200.00", "") and the line's
  /// own discount ("Line discount 10%", "-30.00"). Empty for ordinary lines,
  /// which therefore print exactly as before.
  final List<(String, String)> notes;
}

class ReceiptPayment {
  const ReceiptPayment({
    required this.method,
    required this.amount,
    this.tendered,
    this.change,
  });
  final String method;
  final String amount;
  final String? tendered;
  final String? change;
}

/// Everything a receipt shows, from the SERVER's completed sale plus the
/// display-only names/variants cached from the cart. Immutable; renderers (text,
/// PDF, thermal bitmap) only lay it out.
class ReceiptData {
  const ReceiptData({
    required this.title,
    required this.orderNumber,
    required this.customerLabel,
    required this.lines,
    required this.subtotal,
    required this.tax,
    required this.total,
    required this.payments,
    this.discount,
    this.discountLabel = 'Discount',
    this.pointsEarned,
    this.cashbackEarned,
    this.walletRedeemed,
    this.changeDue,
    this.completedAt,
    this.staffId,
    this.deviceId,
    this.footer = 'Thank you!',
    this.headerLines = const [],
    this.registerLabel,
  });

  /// Phase 11A — optional lines under the title (e.g. the store's address,
  /// from the store settings). Empty = nothing printed (unchanged receipts).
  final List<String> headerLines;

  /// Phase 11A — the register (e.g. its code), when the caller knows it.
  final String? registerLabel;

  final String title;
  final String orderNumber;
  final DateTime? completedAt;
  final String? staffId;
  final String? deviceId;
  final String customerLabel;
  final List<ReceiptLine> lines;
  final String subtotal;
  final String tax;
  final String? discount;

  /// The line label shown next to [discount] — the applied promotion's name
  /// when known (e.g. "10% OFF"), else the generic "Discount".
  final String discountLabel;

  /// Loyalty figures from this sale, already formatted — `null` when not
  /// applicable. There is no "new balance" here (the completed-sale snapshot
  /// only carries what happened on THIS sale, not the account's live
  /// balance — see LoyaltySaleInfo).
  final String? pointsEarned;
  final String? cashbackEarned;
  final String? walletRedeemed;
  final String total;
  final List<ReceiptPayment> payments;
  final String? changeDue;
  final String footer;

  /// `21 Sep 15:23` in local time, or null when the server sent no time.
  String? get dateText =>
      completedAt == null ? null : formatTimestamp(completedAt!);

  /// A one-line summary (SMS bodies, share previews).
  String get shortText {
    final when = dateText == null ? '' : ', $dateText';
    final how = payments.isEmpty
        ? ''
        : ' (${payments.map((p) => p.method).join(' + ')})';
    return '$title receipt $orderNumber$when. Total $total$how. $footer';
  }
}
