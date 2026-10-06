/// An exact port of the server's single POS tax function
/// (buskit-web `services/pos/posTax.js` — `taxMode`, `normalizePercent`,
/// `roundMilli`, `computeLine`), used ONLY to price a sale on this device
/// while the server cannot be reached. Same rules, same integer milli units,
/// same half-up rounding, same order of floating-point operations, so an
/// offline line comes out identical to what the server would compute.
/// Parity is pinned by test/features/offline/pos_tax_parity_test.dart, whose
/// expected values were produced by running the server function itself.
///
/// Rules (copied from the server):
///  - percent = the product's summed category tax, normalised to 4 decimals;
///  - mode 'inclusive': the listed price already contains the tax; tax figure
///    is amount * pct / (100 + pct); charged total = listed amount;
///  - mode 'exclusive': tax = amount * pct / 100; total = amount + tax;
///  - mode 'none' (or percent 0): no tax.
///
/// Promotions, loyalty and manual discounts are NOT ported: they are
/// evaluated by the server only and offline checkout refuses them.
class PosTax {
  const PosTax._();

  /// Server `taxMode(incl_tax)`: the raw product_variation.incl_tax value.
  static String modeFromInclTax(String? inclTax) {
    if (inclTax == 'incl_tax') return 'inclusive';
    if (inclTax == 'N.A') return 'none';
    return 'exclusive';
  }

  /// Server `normalizePercent`: invalid or negative -> 0; 4 decimal places.
  static double normalizePercent(num? value) {
    if (value == null) return 0;
    final n = value.toDouble();
    if (!n.isFinite || n < 0) return 0;
    return (n * 10000).round() / 10000;
  }

  /// Server `roundMilli`: half-up to whole milli for non-negative values.
  static int roundMilli(double x) => (x + 0.5 + 1e-9).floor();

  /// Server `computeLine`, taking the already-resolved tax [mode]
  /// ('inclusive' | 'exclusive' | 'none') the product API sends as
  /// `pricing.tax_mode`. Any other mode value is treated as 'exclusive',
  /// exactly like the server treats any non-'incl_tax'/'N.A' input.
  static PosTaxLine computeLine({
    required int unitPriceMilli,
    required int quantity,
    required num percent,
    required String mode,
  }) {
    final m = (mode == 'inclusive' || mode == 'none') ? mode : 'exclusive';
    final pct = m == 'none' ? 0.0 : normalizePercent(percent);
    final lineSubMilli = unitPriceMilli * quantity;
    int taxMilli;
    int totalMilli;
    if (m == 'inclusive') {
      taxMilli = pct == 0 ? 0 : roundMilli((lineSubMilli * pct) / (100 + pct));
      totalMilli = lineSubMilli;
    } else {
      taxMilli = pct == 0 ? 0 : roundMilli((lineSubMilli * pct) / 100);
      totalMilli = lineSubMilli + taxMilli;
    }
    return PosTaxLine(
      mode: m,
      percent: pct,
      lineSubMilli: lineSubMilli,
      taxMilli: taxMilli,
      totalMilli: totalMilli,
    );
  }
}

class PosTaxLine {
  const PosTaxLine({
    required this.mode,
    required this.percent,
    required this.lineSubMilli,
    required this.taxMilli,
    required this.totalMilli,
  });
  final String mode;
  final double percent;

  /// unit price * quantity (the listed amount; gross for inclusive lines).
  final int lineSubMilli;
  final int taxMilli;
  final int totalMilli;
  bool get taxIncluded => mode == 'inclusive';
}
