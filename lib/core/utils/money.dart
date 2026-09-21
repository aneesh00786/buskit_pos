// Money helpers in integer thousandths ("milli"), the unit the backend uses
// for payments. Used for INPUT parsing and the change-due PREVIEW only; the
// sale total and the actual change come from the server.

/// Parses user input such as `20`, `20.5`, `20.500`. Accepts at most three
/// decimals (the backend rejects more) and no sign. Returns null if invalid.
int? parseMilli(String input) {
  final s = input.trim();
  if (!RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(s)) return null;
  final parts = s.split('.');
  final whole = int.parse(parts[0]);
  final frac = parts.length == 2 ? int.parse(parts[1].padRight(3, '0')) : 0;
  return whole * 1000 + frac;
}

/// Server-provided decimal (e.g. 133.28) to milli-units.
int milliFromDouble(double v) => (v * 1000).round();

/// The JSON number to send for a milli amount (e.g. 11200 -> 11.2).
double milliToJson(int milli) => milli / 1000;

/// `11200` -> `11.20`; keeps a third decimal only when needed.
String formatMilli(int milli) {
  final negative = milli < 0;
  final abs = milli.abs();
  final whole = abs ~/ 1000;
  final frac = (abs % 1000).toString().padLeft(3, '0');
  final trimmed = frac.endsWith('0') ? frac.substring(0, 2) : frac;
  return '${negative ? '-' : ''}$whole.$trimmed';
}
