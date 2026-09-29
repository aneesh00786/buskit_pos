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
  });

  final String name;

  /// Variation / unit label remembered from the cart (display only).
  final String? variant;
  final int quantity;

  /// Server figures, already formatted for display (e.g. `50.00`).
  final String unitPrice;
  final String lineTotal;
  final String? taxNote;
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
    this.changeDue,
    this.completedAt,
    this.staffId,
    this.deviceId,
    this.footer = 'Thank you!',
  });

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
