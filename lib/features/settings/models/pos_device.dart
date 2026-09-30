import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

class PosDevice {
  const PosDevice({
    required this.id,
    required this.storeId,
    this.registerId,
    required this.deviceIdentifier,
    this.deviceName,
    this.platform,
    required this.status,
    this.lastSeenAt,
  });

  final int id;
  final int storeId;
  final int? registerId;
  final String deviceIdentifier;
  final String? deviceName;
  final String? platform;
  final String status;
  final DateTime? lastSeenAt;

  bool get isRevoked => status == 'revoked';
  bool get isActive => status == 'active';

  static PosDevice? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final storeId = asInt(m['store_id']);
    final identifier = asString(m['device_identifier']);
    if (id == null || storeId == null || identifier == null) return null;
    return PosDevice(
      id: id,
      storeId: storeId,
      registerId: asInt(m['register_id']),
      deviceIdentifier: identifier,
      deviceName: asString(m['device_name']),
      platform: asString(m['platform']),
      status: asString(m['status']) ?? 'active',
      lastSeenAt: parseServerTime(m['last_seen_at']),
    );
  }
}
