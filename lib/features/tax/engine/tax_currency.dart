/// POS Phase P2.1 — currency minor units and exact parsing of amounts and
/// rates (decimal strings only, never doubles). A port of buskit-web
/// `services/pos/tax/taxCurrency.js`.
library;

import 'tax_rational.dart';

/// ISO 4217 minor units for the currencies the engine is tested with. A
/// currency missing here is refused, never guessed.
const currencyMinorUnits = <String, int>{
  'INR': 2,
  'AUD': 2,
  'USD': 2,
  'EUR': 2,
  'GBP': 2,
  'JPY': 0,
  'KWD': 3,
  'BHD': 3,
  'OMR': 3,
};

final _amountRe = RegExp(r'^(\d+)(?:\.(\d+))?$');
final _rateRe = RegExp(r'^(\d+)(?:\.(\d{1,6}))?$');

int minorUnits(Object? currency) {
  final mu = currencyMinorUnits[currency];
  if (mu == null) {
    throw TaxEngineException('UNKNOWN_CURRENCY', 'Unknown currency: $currency');
  }
  return mu;
}

BigInt _pow10(int e) => BigInt.from(10).pow(e);

/// "100.5" in INR -> 10050 (paise). More decimals than the currency has is refused.
BigInt parseAmount(Object? value, Object? currency) {
  final mu = minorUnits(currency);
  if (value is! String) {
    throw const TaxEngineException('INVALID_AMOUNT', 'Amounts must be decimal strings');
  }
  final m = _amountRe.firstMatch(value);
  if (m == null) throw TaxEngineException('INVALID_AMOUNT', 'Invalid amount: $value');
  final fraction = m.group(2) ?? '';
  if (fraction.length > mu) {
    throw TaxEngineException(
      'AMOUNT_NOT_REPRESENTABLE',
      '$value is not representable in $currency ($mu decimal places)',
    );
  }
  final padded = fraction.padRight(mu, '0');
  return BigInt.parse(m.group(1)!) * _pow10(mu) +
      (padded.isEmpty ? BigInt.zero : BigInt.parse(padded));
}

/// 10050 in INR -> "100.50"; negative values (residues) keep their sign.
String formatAmount(BigInt minor, Object? currency) {
  final mu = minorUnits(currency);
  final sign = minor.isNegative ? '-' : '';
  final abs = minor.abs();
  if (mu == 0) return '$sign$abs';
  final scale = _pow10(mu);
  return '$sign${abs ~/ scale}.${(abs % scale).toString().padLeft(mu, '0')}';
}

/// A percentage string ("9", "9.975", at most 6 decimals) -> exact fraction of 1.
Fraction parseRate(Object? value) {
  if (value is! String) {
    throw const TaxEngineException('INVALID_RATE', 'Rates must be decimal strings');
  }
  final m = _rateRe.firstMatch(value);
  if (m == null) throw TaxEngineException('INVALID_RATE', 'Invalid rate: $value');
  final fraction = m.group(2) ?? '';
  return Fraction(
    BigInt.parse('${m.group(1)}$fraction'),
    _pow10(fraction.length) * BigInt.from(100),
  );
}
