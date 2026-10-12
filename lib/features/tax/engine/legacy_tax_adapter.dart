/// POS Phase P2.1 — legacy adapter: today's offline tax, unchanged, in the
/// engine's vocabulary (base + components + total).
///
/// It DELEGATES to the live port, `offline/pos_tax.dart` `PosTax.computeLine`
/// (mode resolved by `PosTax.modeFromInclTax`, exactly like the server's
/// `taxMode`). It adds no rounding and no currency precision: amounts stay in
/// thousandths, exactly as the legacy function returns them. Whole quantities
/// only, like the function it wraps. Not used by any live flow yet.
library;

import '../../offline/pos_tax.dart';

class LegacyTaxComponent {
  const LegacyTaxComponent({
    required this.code,
    required this.percent,
    required this.taxMilli,
  });
  final String code;
  final double percent;
  final int taxMilli;
}

class LegacyTaxLine {
  const LegacyTaxLine({
    required this.mode,
    required this.percent,
    required this.taxIncluded,
    required this.lineSubMilli,
    required this.baseMilli,
    required this.taxMilli,
    required this.totalMilli,
    required this.components,
  });
  final String mode;
  final double percent;
  final bool taxIncluded;
  final int lineSubMilli;

  /// The tax-exclusive amount: inclusive lines contain their tax.
  final int baseMilli;
  final int taxMilli;
  final int totalMilli;
  final List<LegacyTaxComponent> components;
}

LegacyTaxLine calculateLegacyLine({
  required int unitPriceMilli,
  required int quantity,
  required num percent,
  required String? inclTax,
}) {
  final t = PosTax.computeLine(
    unitPriceMilli: unitPriceMilli,
    quantity: quantity,
    percent: percent,
    mode: PosTax.modeFromInclTax(inclTax),
  );
  return LegacyTaxLine(
    mode: t.mode,
    percent: t.percent,
    taxIncluded: t.taxIncluded,
    lineSubMilli: t.lineSubMilli,
    baseMilli: t.taxIncluded ? t.lineSubMilli - t.taxMilli : t.lineSubMilli,
    taxMilli: t.taxMilli,
    totalMilli: t.totalMilli,
    components: t.mode == 'none'
        ? const []
        : [
            LegacyTaxComponent(
              code: 'TAX',
              percent: t.percent,
              taxMilli: t.taxMilli,
            ),
          ],
  );
}
