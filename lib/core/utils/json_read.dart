/// Tolerant JSON readers: an unexpected type or a missing field yields null
/// (or a fallback) instead of throwing.
int? asInt(Object? v) {
  if (v is int) return v;
  if (v is double && v == v.roundToDouble()) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v.trim());
  return null;
}

String? asString(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

bool? asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final s = v.toLowerCase();
    if (s == 'true' || s == '1') return true;
    if (s == 'false' || s == '0') return false;
  }
  return null;
}

Map<String, dynamic>? asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : null;

List<Object?> asList(Object? v) => v is List ? List<Object?>.from(v) : const [];
