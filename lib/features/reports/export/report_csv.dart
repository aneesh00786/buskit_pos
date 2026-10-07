import 'dart:convert';
import 'dart:typed_data';

import '../../../core/utils/json_read.dart';
import '../models/retail_report.dart';

/// Phase 14F-C — CSV export of one retail report EXACTLY as the server
/// returned it: the server's rows, the server's `totals` object (never a sum
/// of the rows), the server's `period`, and — for the tax report with no
/// `tax_components` — the server's notes. No GST split, no payment method
/// and no figure the server did not send is added.
///
/// Layout (RFC 4180, CRLF line ends):
///   metadata  (Report / From / To / Timezone / Basis [/ Note])
///   blank line
///   header row + one line per server row
///   blank line
///   "Totals", the server totals' labels, their values

enum _Fmt { text, count, qty, money, rate }

typedef _Col = (String label, String key, _Fmt fmt);

const List<_Col> _money = [
  ('Gross Sales', 'gross_sales', _Fmt.money),
  ('Refunds', 'refunds', _Fmt.money),
  ('Net Sales', 'net_sales', _Fmt.money),
  ('Tax', 'tax', _Fmt.money),
  ('Refund Tax', 'refund_tax', _Fmt.money),
  ('Net Tax', 'net_tax', _Fmt.money),
];

List<_Col> _columns(ReportKind k) => switch (k) {
  ReportKind.products => const [
    ('Product Variation ID', 'product_variation_id', _Fmt.text),
    ('Product Name', 'product_name', _Fmt.text),
    ('Variation Name', 'variation_name', _Fmt.text),
    ('SKU', 'sku', _Fmt.text),
    ('Barcode', 'barcode', _Fmt.text),
    ('Sales Count', 'sales_count', _Fmt.count),
    ('Quantity Sold', 'quantity_sold', _Fmt.qty),
    ('Quantity Refunded', 'quantity_refunded', _Fmt.qty),
    ('Net Quantity', 'net_quantity', _Fmt.qty),
    ..._money,
  ],
  ReportKind.cashiers => const [
    ('Staff ID', 'staff_id', _Fmt.text),
    ('Staff Name', 'staff_name', _Fmt.text),
    ('Sales Count', 'sales_count', _Fmt.count),
    ('Refunds Count', 'refunds_count', _Fmt.count),
    ..._money,
  ],
  ReportKind.registers => const [
    ('Register ID', 'register_id', _Fmt.text),
    ('Register Name', 'register_name', _Fmt.text),
    ('Register Code', 'register_code', _Fmt.text),
    ('Sales Count', 'sales_count', _Fmt.count),
    ('Refunds Count', 'refunds_count', _Fmt.count),
    ..._money,
  ],
  ReportKind.tax => const [
    ('Tax Rate', 'tax_rate', _Fmt.rate),
    ('Sales Count', 'sales_count', _Fmt.count),
    ('Line Count', 'line_count', _Fmt.count),
    ('Taxable Amount', 'taxable_amount', _Fmt.money),
    ('Tax Amount', 'tax_amount', _Fmt.money),
    ('Refund Line Count', 'refund_line_count', _Fmt.count),
    ('Refund Taxable Amount', 'refund_taxable_amount', _Fmt.money),
    ('Refund Tax Amount', 'refund_tax_amount', _Fmt.money),
    ('Net Taxable Amount', 'net_taxable_amount', _Fmt.money),
    ('Net Tax Amount', 'net_tax_amount', _Fmt.money),
  ],
};

const _fileStem = {
  ReportKind.products: 'retail_product_sales',
  ReportKind.cashiers: 'retail_cashier_sales',
  ReportKind.registers: 'retail_register_sales',
  ReportKind.tax: 'retail_tax',
};

/// The CSV text (no byte-order mark; see [reportCsvBytes]).
String reportCsv(ReportKind kind, RetailReport r) {
  final lines = <List<String>>[];
  void meta(String label, String? value) =>
      lines.add([label, _text(value ?? '')]);

  meta('Report', kind.label);
  meta('From', r.from);
  meta('To', r.to);
  meta('Timezone', r.timezone);
  meta('Basis', r.basis);
  if (kind == ReportKind.tax && r.taxComponents == null) {
    for (final n in r.notes) {
      meta('Note', n);
    }
  }
  lines.add(const []);

  final cols = _columns(kind);
  // Payment methods exactly as the server listed them (first-seen order);
  // a row without a method leaves its cells empty — nothing is invented.
  final methods = <String>[];
  if (kind == ReportKind.cashiers || kind == ReportKind.registers) {
    for (final row in r.rows) {
      for (final p in _payments(row)) {
        final m = asString(p['method']);
        if (m != null && !methods.contains(m)) methods.add(m);
      }
    }
  }
  lines.add([
    for (final c in cols) c.$1,
    for (final m in methods) ...[
      '${_text(m)} Tendered',
      '${_text(m)} Refunded',
      '${_text(m)} Net',
    ],
  ]);
  for (final row in r.rows) {
    final pays = {
      for (final p in _payments(row))
        if (asString(p['method']) != null) asString(p['method'])!: p,
    };
    lines.add([
      for (final c in cols) _cell(row[c.$2], c.$3),
      for (final m in methods) ...[
        _cell(pays[m]?['tendered'], _Fmt.money),
        _cell(pays[m]?['refunded'], _Fmt.money),
        _cell(pays[m]?['net'], _Fmt.money),
      ],
    ]);
  }
  lines.add(const []);

  // The server's totals object, as sent: known keys in column order, then
  // any other key it returned (so nothing is silently dropped).
  final known = {for (final c in cols) c.$2: c};
  final keys = [
    for (final c in cols)
      if (r.totals.containsKey(c.$2)) c.$2,
    for (final k in r.totals.keys)
      if (!known.containsKey(k)) k,
  ];
  lines.add(const ['Totals']);
  lines.add([for (final k in keys) known[k]?.$1 ?? _text(k)]);
  lines.add([
    for (final k in keys) _cell(r.totals[k], known[k]?.$3 ?? _Fmt.money),
  ]);

  return '${lines.map((l) => l.map(_escape).join(',')).join('\r\n')}\r\n';
}

/// UTF-8 with a byte-order mark, so spreadsheet apps read non-ASCII names
/// (e.g. Malayalam) correctly.
Uint8List reportCsvBytes(ReportKind kind, RetailReport r) =>
    Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(reportCsv(kind, r))]);

/// e.g. `retail_product_sales_2026-10-01_to_2026-10-07.csv`. The dates are
/// the server's period; anything but digits, letters and '-' becomes '_'.
String reportFileName(ReportKind kind, RetailReport r) {
  String part(String? v) {
    final s = (v ?? '').replaceAll(RegExp(r'[^A-Za-z0-9-]'), '_');
    final t = s.length > 32 ? s.substring(0, 32) : s;
    return t.isEmpty ? 'today' : t;
  }

  return '${_fileStem[kind]}_${part(r.from)}_to_${part(r.to)}.csv';
}

List<Map<String, dynamic>> _payments(Map<String, dynamic> row) =>
    asList(row['payments'])
        .map(asMap)
        .whereType<Map<String, dynamic>>()
        .toList();

// ---------------------------------------------------------------- values

String _cell(Object? v, _Fmt fmt) {
  if (v == null) return '';
  if (fmt == _Fmt.text) return _text(asString(v) ?? jsonEncode(v));
  if (fmt == _Fmt.count) return asInt(v)?.toString() ?? _text('$v');
  final m = _milli(v);
  // Not a number: written as received rather than dropped.
  if (m == null) return _text(asString(v) ?? jsonEncode(v));
  return switch (fmt) {
    // 2 decimals, or 3 when the server has a third (as on screen).
    _Fmt.money => _decimal(m, m % 10 == 0 ? 2 : 3),
    // Whole quantities as integers; WEIGHT always to 3 (1.250 stays 1.250).
    _Fmt.qty => m % 1000 == 0 ? (m ~/ 1000).toString() : _decimal(m, 3),
    _Fmt.rate => _trimmed(m),
    _ => _decimal(m, 3),
  };
}

/// A number or decimal string → exact integer thousandths (no
/// floating-point sums; the server sends at most 3 decimals). Null when the
/// value is not a number or has more than 3 decimals (never rounded away).
int? _milli(Object v) {
  if (v is int) return v * 1000;
  if (v is double) {
    if (!v.isFinite) return null;
    final m = (v * 1000).round();
    return (m / 1000 - v).abs() < 1e-9 * (v.abs() + 1) ? m : null;
  }
  if (v is String) {
    final x = RegExp(r'^(-?)(\d+)(?:\.(\d{1,3}))?$').firstMatch(v.trim());
    if (x == null) return null;
    final m =
        int.parse(x[2]!) * 1000 + int.parse((x[3] ?? '').padRight(3, '0'));
    return x[1] == '-' ? -m : m;
  }
  return null;
}

String _decimal(int milli, int places) {
  final neg = milli < 0;
  final a = milli.abs();
  final frac = (a % 1000).toString().padLeft(3, '0').substring(0, places);
  return '${neg ? '-' : ''}${a ~/ 1000}.$frac';
}

String _trimmed(int milli) {
  if (milli % 1000 == 0) return (milli ~/ 1000).toString();
  return _decimal(milli, 3).replaceFirst(RegExp(r'0+$'), '');
}

/// Server text is kept as-is, except that a leading = + - @ (or tab / CR)
/// is prefixed with ' so a spreadsheet cannot run it as a formula.
String _text(String s) => RegExp(r'^[=+\-@\t\r]').hasMatch(s) ? "'$s" : s;

/// RFC 4180: quote a field containing a comma, quote, CR or LF (or with
/// leading/trailing spaces); double any quote inside.
String _escape(String f) {
  if (f.contains(RegExp(r'[",\r\n]')) || f != f.trim()) {
    return '"${f.replaceAll('"', '""')}"';
  }
  return f;
}
