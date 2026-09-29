// ============================================================================
// TESTING ONLY — see the banner in dev_credentials.dart. Not reachable unless
// the call sites in ../ui/auth_pages.dart are compiled in AND kDebugMode is
// true; delete this whole folder (and those call sites) before a production
// build.
//
// What "auto-generate if expired" can and cannot do:
//  * A device's identifier/secret do NOT expire on their own — only the
//    signed-in TOKEN does (12h/10h), and every normal login already mints a
//    fresh one. So "expired" in practice means the saved device was deleted
//    or revoked server-side (e.g. a previous test rotation).
//  * Recovering from that needs ONE more successful login with the credential
//    that's now failing, to mint its replacement — the backend deliberately
//    has no API that can create a device out of nothing (see
//    database/pos_bootstrap_company.js's own comment on this). So this can
//    self-heal right up until the saved device is actually gone, at which
//    point a human has to create one once (the existing bootstrap CLI, or an
//    already-signed-in device via POST /devices) — this helper reports that
//    plainly rather than pretending to fix it.
// ============================================================================
import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import 'dev_credentials.dart';
import 'dev_jwt.dart';

class DevLoginHelper {
  DevLoginHelper(this._client, this._store);
  final PosApiClient _client;
  final DevCredentialsStore _store;

  /// The saved test credentials, refreshed automatically if they no longer
  /// work. Null when there is nothing to autofill (first run, or the saved
  /// device is gone and could not be replaced automatically) — the login
  /// screens fall back to their normal empty fields in that case.
  Future<DevCredentials?> ensureCredentials() async {
    final saved = await _store.load();
    if (saved == null) return null;
    if (await _worksAsIs(saved)) return saved;
    return regenerate(saved);
  }

  Future<bool> _worksAsIs(DevCredentials c) async {
    try {
      final deviceToken = await _deviceLogin(
        c.deviceIdentifier,
        c.deviceSecret,
      );
      if (deviceToken == null) return false;
      return await _staffLogin(deviceToken, c.staffId, c.pin) != null;
    } on ApiException {
      return false;
    }
  }

  /// Uses [from] (assumed still valid enough for one more login) to mint a
  /// brand-new device on the same store/register, saves it, and returns it.
  /// Returns null if [from] itself can no longer authenticate at all — there
  /// is nothing further this helper can do at that point.
  Future<DevCredentials?> regenerate(DevCredentials from) async {
    try {
      final deviceToken = await _deviceLogin(
        from.deviceIdentifier,
        from.deviceSecret,
      );
      if (deviceToken == null) return null;
      final staffToken = await _staffLogin(deviceToken, from.staffId, from.pin);
      if (staffToken == null) return null;

      final claims = decodeJwtPayloadUnverified(deviceToken);
      final storeId = claims?['store_id'];
      final registerId = claims?['register_id'];
      if (storeId == null) return null;

      final newIdentifier = 'DEV-${DateTime.now().millisecondsSinceEpoch}';
      final created = await _client.post(
        '/devices',
        body: {
          'device_identifier': newIdentifier,
          'store_id': storeId,
          'register_id': ?registerId,
          'device_name': 'Dev auto-login',
        },
        token: staffToken,
      );
      final newSecret = asString(asMap(created)?['device_secret']);
      if (newSecret == null) return null;

      final fresh = from.copyWith(
        deviceIdentifier: newIdentifier,
        deviceSecret: newSecret,
      );
      await _store.save(fresh);
      return fresh;
    } on ApiException {
      return null;
    }
  }

  Future<String?> _deviceLogin(String id, String secret) async {
    final data = await _client.post(
      '/auth/device-login',
      body: {'device_identifier': id, 'device_secret': secret},
      authenticated: false,
    );
    return asString(asMap(data)?['token']);
  }

  Future<String?> _staffLogin(
    String deviceToken,
    String staffId,
    String pin,
  ) async {
    final data = await _client.post(
      '/auth/staff-login',
      body: {'salesman_id': staffId, 'pin': pin},
      token: deviceToken,
      notifyUnauthorized: false,
    );
    return asString(asMap(data)?['token']);
  }
}
