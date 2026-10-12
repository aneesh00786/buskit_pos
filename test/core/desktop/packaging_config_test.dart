// Phase 6ZD — release packaging invariants (static checks). The packaging
// scripts themselves were run on macOS (scripts/package_macos.sh); the
// Windows script has NOT been run (needs a Windows host).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String p) => File(p).readAsStringSync();

Set<String> entitlementKeys(String plist) =>
    RegExp(r'<key>([^<]+)</key>').allMatches(plist).map((m) => m.group(1)!).toSet();

void main() {
  test('macOS release entitlements: sandbox + outbound network only (no JIT, inbound server, mic, camera or files)', () {
    expect(entitlementKeys(read('macos/Runner/Release.entitlements')), {
      'com.apple.security.app-sandbox',
      'com.apple.security.network.client',
    });
  });

  test('macOS packaging signs nested code first with the release entitlements; Developer ID uses hardened runtime + timestamp', () {
    final s = read('scripts/package_macos.sh');
    expect(s, contains('ENTITLEMENTS="macos/Runner/Release.entitlements"'));
    expect(s, contains('--timestamp --options runtime --sign "\$DEVELOPER_ID_APPLICATION"'));
    expect(s.indexOf('find "\$APP/Contents/Frameworks" -depth'), lessThan(s.indexOf('--entitlements "\$ENTITLEMENTS" "\$APP"')));
    for (final forbidden in ['get-task-allow', 'cs.allow-jit', 'network.server', 'device.audio-input', 'device.camera']) {
      expect(s, contains('com.apple.security.$forbidden'), reason: 'rejected by the entitlement check: $forbidden');
    }
    expect(s, contains('xcrun notarytool submit'));
    expect(s, contains('xcrun stapler staple'));
    expect(s, contains('scripts/verify_desktop_artifact.sh "\$zip"'));
  });

  test('Windows packaging keeps buskit_pos.exe and ships the whole Release folder', () {
    final s = read('scripts/package_windows.ps1');
    expect(s, contains("'buskit_pos.exe'"));
    expect(s, contains(r"build\windows\x64\runner\Release"));
    expect(s, contains("'data\\app.so'"));
  });

  test('no server address is hard-coded in the packaging scripts, and only assets/images/ is bundled as Flutter assets', () {
    final url = RegExp(r'https://[a-z0-9]');
    for (final f in ['scripts/package_macos.sh', 'scripts/package_windows.ps1', 'scripts/verify_desktop_artifact.sh']) {
      expect(url.hasMatch(read(f)), isFalse, reason: f);
    }
    final pubspec = read('pubspec.yaml');
    final section = RegExp(r'^  assets:\n((?:    - .*\n)+)', multiLine: true).firstMatch(pubspec);
    final entries = section == null ? <String>[] : RegExp(r'- (.*)').allMatches(section.group(1)!).map((m) => m.group(1)!.trim()).toList();
    expect(entries, ['assets/images/'], reason: 'nothing else from the repository (e.g. .env files) is packaged as an asset');
    final images = Directory('assets/images').listSync(recursive: true).whereType<File>().map((f) => f.path.split('/').last);
    expect(images.where((n) => n.startsWith('.env') || RegExp(r'\.(p12|pfx|p8|pem|key|jks|keystore|json|yaml)$').hasMatch(n)), isEmpty,
        reason: 'assets/images holds images only');
  });
}
