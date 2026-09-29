// ============================================================================
// TESTING ONLY — see the banner in dev_credentials.dart.
// ============================================================================
import 'dart:convert';

/// Reads a JWT's payload WITHOUT verifying its signature — fine here because
/// it only ever inspects a token this device just received directly from the
/// server a moment ago (never a token from an untrusted source), purely to
/// read `store_id`/`register_id` for minting a replacement device. Never used
/// for anything security-relevant. Null if the token isn't a parseable JWT.
Map<String, dynamic>? decodeJwtPayloadUnverified(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final normalized = base64Url.normalize(parts[1]);
    final decoded = utf8.decode(base64Url.decode(normalized));
    final json = jsonDecode(decoded);
    return json is Map<String, dynamic> ? json : null;
  } catch (_) {
    return null;
  }
}
