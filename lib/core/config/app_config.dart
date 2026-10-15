/// Build-time configuration. The backend origin defaults to the local dev
/// server. Override it without editing code with
/// `--dart-define=POS_BASE_URL=http://host:port` (no trailing path).
///
/// Note: `localhost` works for the iOS simulator and desktop. An Android
/// emulator reaches the host machine at `http://10.0.2.2:3000`, and a physical
/// device needs the computer's LAN address.
///
/// Phase 17E: a RELEASE build must be given an HTTPS server address
/// ([releaseBaseUrlProblem]); the Android release build refuses to compile
/// without one (android/app/build.gradle.kts) and the app refuses to start
/// with one that is missing or not HTTPS (main.dart). Debug builds keep the
/// development default. See docs/ANDROID_RELEASE_BUILD.md.
class AppConfig {
  static const String baseUrl = String.fromEnvironment(
    'POS_BASE_URL',
    defaultValue: 'https://test.thrivewoo.com',
  );

  /// Shown in the sidebar. Keep in step with pubspec.yaml, or pass
  /// `--dart-define=APP_VERSION=1.2.3` from your build script.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
  static const String apiPrefix = '/api/v1/pos';
  static const Duration requestTimeout = Duration(seconds: 15);

  static const Set<String> _developmentHosts = {
    'localhost',
    '10.0.2.2', // Android emulator -> host machine
    '0.0.0.0',
    '::1',
  };

  /// null when [url] may be used by a release build; otherwise the reason it
  /// may not (never echoes the value). Required: an absolute `https://` URL
  /// with a host that is not a development address, and no credentials,
  /// query or fragment. A path prefix is allowed (see PosApiClient.buildUri).
  /// Mirrored by the Android release-build check in build.gradle.kts.
  static String? releaseBaseUrlProblem(String url) {
    final value = url.trim();
    if (value.isEmpty) {
      return 'No server address was set for this build (POS_BASE_URL).';
    }
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return 'The server address of this build (POS_BASE_URL) is not a valid URL.';
    }
    if (uri.scheme != 'https') {
      return 'The server address of this build (POS_BASE_URL) must use https://.';
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      return 'The server address of this build (POS_BASE_URL) must not contain credentials, a query or a fragment.';
    }
    final host = uri.host.toLowerCase();
    if (_developmentHosts.contains(host) || host.startsWith('127.')) {
      return 'The server address of this build (POS_BASE_URL) is a development address.';
    }
    return null;
  }
}
