import 'dart:math';

/// RFC 4122 version-4 UUID from a cryptographically secure source, e.g.
/// `3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c` (36 characters — inside the
/// backend's 8–64 character idempotency-key window).
String generateUuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40; // version 4
  bytes[8] = (bytes[8] & 0x3f) | 0x80; // variant 10xx
  String hex(int from, int to) => bytes
      .sublist(from, to)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}
