/// Phase 14G — how old the cached product catalogue may be for a NEW offline
/// sale. The single place to change it (no environment / backend setting).
const offlineCatalogueMaxAge = Duration(hours: 24);

/// True when a catalogue cached at [cachedAt] (the last SUCCESSFUL server
/// refresh, `products.json` `cached_at`) may still be used for a new offline
/// sale at [now]:
/// - missing (null) — never assumed fresh;
/// - age <= [maxAge] — fresh (exactly the maximum age still counts);
/// - a timestamp after [now] (device clock moved back) — fresh: a clock
///   change alone must not block the POS.
bool isOfflineCatalogueFresh(
  DateTime? cachedAt,
  DateTime now, {
  Duration maxAge = offlineCatalogueMaxAge,
}) {
  if (cachedAt == null) return false;
  final age = now.toUtc().difference(cachedAt.toUtc());
  return age <= maxAge;
}
