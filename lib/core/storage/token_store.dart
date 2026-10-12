import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Minimal key/value persistence for the device credentials. Only the device
/// token and identifier are persisted; the staff token and PIN are never
/// written to disk.
abstract class TokenStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class TokenKeys {
  static const deviceToken = 'pos_device_token';
  static const deviceIdentifier = 'pos_device_identifier';
}

/// Phase 6ZA — the secure storage for the platform the app runs on. macOS
/// uses the legacy (non data-protection) Keychain, as the plugin documents
/// for apps without Keychain Sharing: no `keychain-access-groups`
/// entitlement and no provisioning profile tying the build to one Mac.
/// Android / iOS keep the plugin defaults (unchanged).
FlutterSecureStorage platformSecureStorage([TargetPlatform? platform]) {
  final p = platform ?? defaultTargetPlatform;
  if (!kIsWeb && p == TargetPlatform.macOS) {
    return const FlutterSecureStorage(
      mOptions: MacOsOptions(usesDataProtectionKeychain: false),
    );
  }
  return const FlutterSecureStorage();
}

class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _s = storage ?? platformSecureStorage();
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryTokenStore implements TokenStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String key) async => _m[key];
  @override
  Future<void> write(String key, String value) async => _m[key] = value;
  @override
  Future<void> delete(String key) async => _m.remove(key);
}
