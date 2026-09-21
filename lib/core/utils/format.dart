/// Formats a server-supplied amount for display only (no arithmetic on
/// server-authoritative prices happens in the client). The backend works to
/// 3 decimal places; trailing zeros beyond 2 decimals are trimmed.
String formatMoney(num? value) {
  if (value == null) return '—';
  var s = value.toStringAsFixed(3);
  if (s.endsWith('0')) s = s.substring(0, s.length - 1);
  return s;
}

/// Formats a quantity/stock figure without a pointless ".0".
String formatQty(num? value) {
  if (value == null) return '—';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}
