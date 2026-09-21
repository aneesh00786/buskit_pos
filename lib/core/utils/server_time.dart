/// Parses a timestamp from the POS backend. Production returns MySQL
/// `YYYY-MM-DD HH:MM:SS` strings that are UTC but carry no zone marker (the
/// server pool is configured with timezone 'Z' and dateStrings); other
/// environments return ISO-8601 with a `Z`. Both are read as UTC. Anything
/// unparseable yields null.
DateTime? parseServerTime(Object? value) {
  if (value is! String) return null;
  var s = value.trim();
  if (s.isEmpty) return null;
  s = s.replaceFirst(' ', 'T');
  final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(s);
  return DateTime.tryParse(hasZone ? s : '${s}Z');
}

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// e.g. `21 Sep 15:23` in the device's local time.
String formatTimestamp(DateTime t) {
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.day} ${_months[l.month - 1]} ${two(l.hour)}:${two(l.minute)}';
}
