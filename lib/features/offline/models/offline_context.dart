import '../../../core/utils/json_read.dart';

/// current_shift.json — the register/shift context offline sales are recorded
/// against. A local COPY of what the server said; never authoritative: a
/// future sync must re-validate company/store/register/shift/staff
/// server-side.
class OfflineShiftContext {
  const OfflineShiftContext({
    required this.companyId,
    required this.storeId,
    required this.registerId,
    required this.shiftId,
    required this.salesmanId,
    required this.openedAt,
    required this.status,
    this.deviceId,
    this.currency,
  });

  final int companyId;
  final int storeId;
  final int registerId;

  /// The server's pos_devices.id, when known.
  final int? deviceId;
  final int shiftId;

  /// Staff id (salesman_id) who opened the shift / is signed in.
  final String salesmanId;
  final DateTime openedAt;

  /// 'open' | 'closed' as last known.
  final String status;

  /// Store currency (e.g. INR), for display.
  final String? currency;

  bool get isOpen => status == 'open';

  Map<String, dynamic> toJson() => {
    'company_id': companyId,
    'store_id': storeId,
    'register_id': registerId,
    'device_id': deviceId,
    'shift_id': shiftId,
    'salesman_id': salesmanId,
    'opened_at': openedAt.toUtc().toIso8601String(),
    'status': status,
    'currency': currency,
  };

  static OfflineShiftContext? fromJson(Map<String, dynamic> m) {
    final company = asInt(m['company_id']);
    final store = asInt(m['store_id']);
    final register = asInt(m['register_id']);
    final shift = asInt(m['shift_id']);
    final staff = asString(m['salesman_id']);
    final opened = DateTime.tryParse(asString(m['opened_at']) ?? '');
    final status = asString(m['status']);
    if (company == null || store == null || register == null || shift == null || staff == null || opened == null || status == null) return null;
    return OfflineShiftContext(
      companyId: company,
      storeId: store,
      registerId: register,
      deviceId: asInt(m['device_id']),
      shiftId: shift,
      salesmanId: staff,
      openedAt: opened.toUtc(),
      status: status,
      currency: asString(m['currency']),
    );
  }
}

/// device.json — this installation's identity for offline data.
///
/// [installationId] is generated ONCE (UUID v4) and kept in the app's support
/// directory, so it survives restarts and normal updates. It is not a second
/// login identity: the server identity stays the registered device
/// identifier + device token (secure storage); this id only stamps locally
/// created records so a future sync can tell which installation made them.
/// The user-entered device identifier is stored only as a reference.
class OfflineDeviceInfo {
  const OfflineDeviceInfo({required this.installationId, required this.createdAt, this.deviceIdentifier});
  final String installationId;
  final DateTime createdAt;
  final String? deviceIdentifier;

  OfflineDeviceInfo copyWith({String? deviceIdentifier}) =>
      OfflineDeviceInfo(installationId: installationId, createdAt: createdAt, deviceIdentifier: deviceIdentifier ?? this.deviceIdentifier);

  Map<String, dynamic> toJson() => {
    'installation_id': installationId,
    'created_at': createdAt.toUtc().toIso8601String(),
    'device_identifier': deviceIdentifier,
  };

  static OfflineDeviceInfo? fromJson(Map<String, dynamic> m) {
    final id = asString(m['installation_id']);
    final at = DateTime.tryParse(asString(m['created_at']) ?? '');
    if (id == null || at == null) return null;
    return OfflineDeviceInfo(installationId: id, createdAt: at.toUtc(), deviceIdentifier: asString(m['device_identifier']));
  }
}

/// settings.json — offline behaviour switches.
class OfflineSettings {
  const OfflineSettings({this.offlineManualTenders = const {}});

  /// Manual tenders ('card', 'other') explicitly approved for offline use —
  /// e.g. a standalone card machine that works without this POS being
  /// online. Cash is always allowed; provider payments never are.
  final Set<String> offlineManualTenders;

  Map<String, dynamic> toJson() => {'offline_manual_tenders': offlineManualTenders.toList()..sort()};

  static OfflineSettings fromJson(Map<String, dynamic> m) =>
      OfflineSettings(offlineManualTenders: asList(m['offline_manual_tenders']).map(asString).whereType<String>().where((t) => t == 'card' || t == 'other').toSet());
}
