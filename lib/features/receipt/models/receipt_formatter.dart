import '../../../core/utils/format.dart';
import '../../checkout/models/payment.dart';
import 'receipt.dart';

/// Merges the backend's completed sale (prices, tax, totals, payments and the
/// change — all server values) with the display-only names and variants cached
/// from the cart when the sale was paid (the completed view has neither).
class ReceiptFormatter {
  const ReceiptFormatter._();

  static ReceiptData build({
    required CompletedSale sale,
    Map<int, String> names = const {},
    Map<int, String> variants = const {},
    String title = 'ThriveWoo POS',
    String? staffId,
    String? deviceId,
  }) {
    String money(double? v) => formatMoney(v);
    return ReceiptData(
      title: title,
      orderNumber: sale.displayNumber,
      completedAt: sale.completedAt,
      staffId: staffId,
      deviceId: deviceId,
      customerLabel: sale.customerId == null
          ? 'Guest checkout'
          : 'Customer ${sale.customerId}',
      lines: [
        for (final l in sale.items)
          ReceiptLine(
            name: names[l.id] ?? 'Item ${l.productVariationId}',
            variant: variants[l.id],
            quantity: l.quantity,
            unitPrice: money(l.unitPrice),
            lineTotal: money(l.lineTotal),
          ),
      ],
      subtotal: money(sale.totals.subtotal),
      tax: money(sale.totals.taxTotal),
      discount:
          (sale.totals.discountTotal != null && sale.totals.discountTotal != 0)
          ? money(sale.totals.discountTotal)
          : null,
      discountLabel: sale.promotion?.title ?? 'Discount',
      total: money(sale.totals.grandTotal),
      payments: [
        for (final p in sale.payments)
          ReceiptPayment(
            method: TenderMethod.fromWire(p.method)?.label ?? p.method,
            amount: money(p.amount),
            tendered: p.tendered == null ? null : money(p.tendered),
            change: (p.changeDue ?? 0) > 0 ? money(p.changeDue) : null,
          ),
      ],
      changeDue: sale.changeDue > 0 ? money(sale.changeDue) : null,
    );
  }
}

/// Fixed-width plain-text layout of a receipt (ASCII only, so it prints on any
/// thermal code page and renders in core PDF fonts).
extension ReceiptText on ReceiptData {
  static String _ascii(String s) => s
      .replaceAll('×', 'x')
      .replaceAll('·', '-')
      .replaceAll('–', '-')
      .replaceAll('—', '-')
      .replaceAll(RegExp(r'[^\x20-\x7E]'), '?');

  static String _center(String s, int cols) {
    final t = s.length > cols ? s.substring(0, cols) : s;
    final pad = (cols - t.length) ~/ 2;
    return '${' ' * pad}$t';
  }

  /// `left ....... right` on one line; the left text is cut with `~` if the pair
  /// would not fit.
  static String _pair(String left, String right, int cols) {
    final r = right;
    final maxLeft = cols - r.length - 1;
    var l = left;
    if (maxLeft < 1) {
      return r.length > cols ? r.substring(0, cols) : r.padLeft(cols);
    }
    if (l.length > maxLeft) l = '${l.substring(0, maxLeft - 1)}~';
    return '$l${' ' * (cols - l.length - r.length)}$r';
  }

  static List<String> _wrap(String text, int cols) {
    final out = <String>[];
    var line = '';
    for (final word in text.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      var w = word;
      while (w.length > cols) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(w.substring(0, cols));
        w = w.substring(cols);
      }
      if (line.isEmpty) {
        line = w;
      } else if (line.length + 1 + w.length <= cols) {
        line = '$line $w';
      } else {
        out.add(line);
        line = w;
      }
    }
    if (line.isNotEmpty) out.add(line);
    return out;
  }

  /// The receipt as lines of at most [columns] characters (default 42 = 80 mm
  /// paper; use 32 for 58 mm).
  List<String> toLines({int columns = 42}) {
    final rule = '-' * columns;
    final out = <String>[
      _center(_ascii(title), columns),
      '',
      _pair('Order', _ascii(orderNumber), columns),
      if (dateText != null) _pair('Date', _ascii(dateText!), columns),
      if (staffId != null) _pair('Staff', _ascii(staffId!), columns),
      if (deviceId != null) _pair('Device', _ascii(deviceId!), columns),
      _pair('Customer', _ascii(customerLabel), columns),
      rule,
    ];
    for (final l in lines) {
      final name = _ascii(
        l.variant == null || l.variant!.isEmpty
            ? l.name
            : '${l.name} (${l.variant})',
      );
      out.addAll(_wrap(name, columns));
      out.add(
        _pair('  ${l.quantity} x ${l.unitPrice}', _ascii(l.lineTotal), columns),
      );
    }
    out.add(rule);
    out.add(_pair('Subtotal', subtotal, columns));
    out.add(_pair('Tax', tax, columns));
    if (discount != null) {
      out.add(_pair(_ascii(discountLabel), '-$discount', columns));
    }
    out.add(_pair('TOTAL', total, columns));
    out.add(rule);
    for (final p in payments) {
      out.add(_pair(_ascii(p.method), p.amount, columns));
      if (p.tendered != null) {
        out.add(_pair('  Tendered', p.tendered!, columns));
      }
      if (p.change != null) out.add(_pair('  Change', p.change!, columns));
    }
    if (changeDue != null) out.add(_pair('CHANGE DUE', changeDue!, columns));
    out.add(rule);
    out.add(_center(_ascii(footer), columns));
    return out;
  }

  String toPlainText({int columns = 42}) =>
      toLines(columns: columns).join('\n');
}
