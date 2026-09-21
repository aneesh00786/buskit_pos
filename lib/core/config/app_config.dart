/// Build-time configuration. The backend origin defaults to the local dev
/// server. Override it without editing code with
/// `--dart-define=POS_BASE_URL=http://host:port` (no trailing path).
///
/// Note: `localhost` works for the iOS simulator and desktop. An Android
/// emulator reaches the host machine at `http://10.0.2.2:3000`, and a physical
/// device needs the computer's LAN address.
class AppConfig {
  static const String baseUrl = String.fromEnvironment(
    'POS_BASE_URL',
    defaultValue: 'http://localhost:3000',
  );

  /// Shown in the sidebar. Keep in step with pubspec.yaml, or pass
  /// `--dart-define=APP_VERSION=1.2.3` from your build script.
  static const String appVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '1.0.0',
  );
  static const String apiPrefix = '/api/v1/pos';
  static const Duration requestTimeout = Duration(seconds: 15);
}
