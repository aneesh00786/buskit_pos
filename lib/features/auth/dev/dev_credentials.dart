// ============================================================================
// TESTING ONLY — DELETE THIS FOLDER (lib/features/auth/dev/) BEFORE SHIPPING
// A PRODUCTION BUILD. It autofills and self-repairs a local test device/staff
// login so nobody has to hand-type or clipboard-paste credentials while
// testing. It never runs unless kDebugMode is true (see dev_login_helper.dart
// and its call sites in ../ui/auth_pages.dart), but the real removal step is
// deleting this folder and the two call sites that reference it.
// ============================================================================
import '../../../core/storage/token_store.dart';

/// A saved test device + staff sign-in. Deliberately separate from
/// [TokenKeys]/the real session (SessionController never reads or writes
/// these keys) — this is throwaway local testing convenience, not part of
/// the app's real credential model.
class DevCredentials {
  const DevCredentials({
    required this.deviceIdentifier,
    required this.deviceSecret,
    required this.staffId,
    required this.pin,
  });
  final String deviceIdentifier;
  final String deviceSecret;
  final String staffId;
  final String pin;

  DevCredentials copyWith({String? deviceIdentifier, String? deviceSecret}) =>
      DevCredentials(
        deviceIdentifier: deviceIdentifier ?? this.deviceIdentifier,
        deviceSecret: deviceSecret ?? this.deviceSecret,
        staffId: staffId,
        pin: pin,
      );
}

class DevCredentialsStore {
  DevCredentialsStore(this._store);
  final TokenStore _store;

  static const _kId = 'dev_test_device_identifier';
  static const _kSecret = 'dev_test_device_secret';
  static const _kStaff = 'dev_test_staff_id';
  static const _kPin = 'dev_test_staff_pin';

  Future<DevCredentials?> load() async {
    final id = await _store.read(_kId);
    final secret = await _store.read(_kSecret);
    final staff = await _store.read(_kStaff);
    final pin = await _store.read(_kPin);
    if (id == null || secret == null || staff == null || pin == null) {
      return null;
    }
    return DevCredentials(
      deviceIdentifier: id,
      deviceSecret: secret,
      staffId: staff,
      pin: pin,
    );
  }

  /// Records a successful manual device sign-in, so it becomes the seed the
  /// very first time — before this, `load()` has nothing to return.
  Future<void> rememberDevice(String identifier, String secret) async {
    await _store.write(_kId, identifier);
    await _store.write(_kSecret, secret);
  }

  /// Records a successful manual staff sign-in (id + PIN), the other half of
  /// the seed `load()` needs.
  Future<void> rememberStaff(String staffId, String pin) async {
    await _store.write(_kStaff, staffId);
    await _store.write(_kPin, pin);
  }

  Future<void> save(DevCredentials c) async {
    await _store.write(_kId, c.deviceIdentifier);
    await _store.write(_kSecret, c.deviceSecret);
    await _store.write(_kStaff, c.staffId);
    await _store.write(_kPin, c.pin);
  }
}
