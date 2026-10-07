import '../../../core/utils/json_read.dart';

/// Phase 14F-B — the four retail reports (backend Phase 14F-A).
enum ReportKind {
  products('products', 'Product Sales', 'reports.product'),
  cashiers('cashiers', 'Cashier Sales', 'reports.cashier'),
  registers('registers', 'Register Sales', 'reports.sales'),
  tax('tax', 'Tax', 'reports.tax');

  const ReportKind(this.path, this.label, this.permission);

  /// `GET /reports/<path>`.
  final String path;
  final String label;

  /// The existing permission the backend checks (it remains the authority).
  final String permission;
}

/// One report as the server returned it. Display only: every figure,
/// including [totals], is the server's — nothing is re-added here, so the
/// totals stay right even if the server later pages its rows.
class RetailReport {
  const RetailReport({
    required this.from,
    required this.to,
    required this.timezone,
    required this.basis,
    required this.rows,
    required this.totals,
    this.taxComponents,
    this.notes = const [],
  });

  final String? from;
  final String? to;
  final String? timezone;
  final String? basis;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic> totals;

  /// Tax only: null while the POS stores no CGST / SGST / IGST split.
  final Object? taxComponents;
  final List<String> notes;

  bool get isEmpty => rows.isEmpty;

  static RetailReport? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final period = asMap(m['period']) ?? const {};
    return RetailReport(
      from: asString(period['from']),
      to: asString(period['to']),
      timezone: asString(period['timezone']),
      basis: asString(period['basis']),
      rows: asList(m['rows'])
          .map(asMap)
          .whereType<Map<String, dynamic>>()
          .toList(),
      totals: asMap(m['totals']) ?? const {},
      taxComponents: m['tax_components'],
      notes: asList(m['notes']).map(asString).whereType<String>().toList(),
    );
  }
}
