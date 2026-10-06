/// Phase 12B — sale quantities without binary floating point, the same rule
/// the backend uses (services/pos/posQuantity.js): quantities are exact
/// integer thousandths ("milli", as money is).
///
///   PIECE  : a whole number 1 … 9999 (unchanged).
///   WEIGHT : a positive decimal with at most 3 decimal places,
///            0.001 … 9999 (e.g. 0.250, 1.25, 2.500).
///   REVIEW : never sold (decided elsewhere).
///
/// The server stays the authority (it may still refuse WEIGHT sales when they
/// are not enabled there); nothing here rounds or truncates a quantity.
library;

const int quantityUnit = 1000; // milli per whole unit
const int maxQuantity = 9999;
const int maxQuantityMilli = maxQuantity * quantityUnit;

const _decimal = r'^(\d{1,9})(?:\.(\d{1,3}))?$';

/// Exact thousandths of [value] (an int, a double as sent in JSON, or decimal
/// text such as "1.250"), or null when it is not a non-negative number with
/// at most 3 decimal places. Uses the decimal TEXT, never `value * 1000`.
int? quantityMilliOf(Object? value) {
  if (value == null || value is bool) return null;
  if (value is int) return value < 0 ? null : value * quantityUnit;
  String text;
  if (value is double) {
    if (!value.isFinite || value < 0) return null;
    text = value.toString(); // shortest round-trip text, e.g. 1.25
    if (text.contains('e')) return null;
    if (text.endsWith('.0')) text = text.substring(0, text.length - 2);
  } else {
    text = value.toString().trim();
  }
  final m = RegExp(_decimal).firstMatch(text);
  if (m == null) return null;
  final frac = (m.group(2) ?? '').padRight(3, '0');
  return int.parse(m.group(1)!) * quantityUnit + int.parse(frac);
}

/// The value to keep / send for [milli]: an int when whole (so PIECE stays
/// exactly as before), else the decimal (1250 -> 1.25, exact in JSON).
num quantityFromMilli(int milli) =>
    milli % quantityUnit == 0 ? milli ~/ quantityUnit : milli / quantityUnit;

/// Display text: whole numbers as before ("2"); decimals with 3 places
/// ("1.250", "0.250").
String formatQuantity(num quantity, {bool weight = false}) {
  final milli = quantityMilliOf(quantity);
  if (milli == null) return '$quantity';
  if (!weight && milli % quantityUnit == 0) return '${milli ~/ quantityUnit}';
  return '${milli ~/ quantityUnit}.${(milli % quantityUnit).toString().padLeft(3, '0')}';
}

/// Null when [value] is a valid quantity for [sellingMode], else the message.
String? quantityError(String sellingMode, Object? value) {
  final milli = quantityMilliOf(value);
  if (sellingMode == 'WEIGHT') {
    if (milli == null || milli <= 0 || milli > maxQuantityMilli) {
      return 'Enter a weight from 0.001 to $maxQuantity, with at most 3 decimal places.';
    }
    return null;
  }
  if (milli == null ||
      milli % quantityUnit != 0 ||
      milli < quantityUnit ||
      milli > maxQuantityMilli) {
    return 'Quantity must be a whole number from 1 to $maxQuantity.';
  }
  return null;
}
