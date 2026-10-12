// TEMPORARY (testing) landscape lock on Android / iOS: landscape-left and
// landscape-right only, requested before runApp(), matching native settings;
// macOS / Windows untouched.
import 'dart:io';

import 'package:buskit_pos/core/platform/landscape_lock.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String read(String p) => File(p).readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          calls.add(call);
          return null;
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('Android: requests landscape-left and landscape-right only', () async {
    expect(landscapeLockApplies(TargetPlatform.android), isTrue);
    await applyLandscapeLock(platform: TargetPlatform.android);
    final orientation = calls
        .where((c) => c.method == 'SystemChrome.setPreferredOrientations')
        .toList();
    expect(orientation, hasLength(1));
    expect(orientation.single.arguments, [
      'DeviceOrientation.landscapeLeft',
      'DeviceOrientation.landscapeRight',
    ]);
  });

  test('iOS: no Dart request (Info.plist covers iPhone; on iPad it would bring back iPadOS 26 letterboxing)', () async {
    expect(
      landscapeLockApplies(TargetPlatform.iOS),
      isTrue,
      reason: 'ForcedLandscape still applies on iOS',
    );
    await applyLandscapeLock(platform: TargetPlatform.iOS);
    expect(calls, isEmpty);
  });

  for (final p in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.linux,
  ]) {
    test(
      '$p (desktop): no orientation request — window sizing and layout unchanged',
      () async {
        expect(landscapeLockApplies(p), isFalse);
        await applyLandscapeLock(platform: p);
        expect(calls, isEmpty);
      },
    );
  }

  test('main() applies the lock right after binding initialisation and before any runApp()', () {
    final main = read('lib/main.dart');
    final init = main.indexOf('WidgetsFlutterBinding.ensureInitialized();');
    final lock = main.indexOf('await applyLandscapeLock();');
    expect(main, contains('runApp(ForcedLandscape('));
    final firstRunApp = main.indexOf('runApp(');
    expect(init, greaterThanOrEqualTo(0));
    expect(lock, greaterThan(init));
    expect(lock, lessThan(firstRunApp));
    expect(lock, lessThan(main.indexOf('claimDesktopInstance()')));
  });

  test('Android: MainActivity is sensorLandscape (no portrait flash before Flutter starts) and opts in on large screens', () {
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:screenOrientation="sensorLandscape"'));
    expect(
      manifest,
      contains('android.window.PROPERTY_COMPAT_ALLOW_RESTRICTED_RESIZABILITY'),
    );
    expect(
      RegExp('android:screenOrientation=').allMatches(manifest),
      hasLength(1),
      reason: 'no conflicting orientation settings',
    );
  });

  test('iOS: iPhone lists only landscape; iPad lists all orientations (full-screen portrait window, turned by ForcedLandscape)', () {
    final plist = read('ios/Runner/Info.plist');
    List<String?> list(String key) {
      final m = RegExp(
        '<key>${RegExp.escape(key)}</key>\\s*<array>(.*?)</array>',
        dotAll: true,
      ).firstMatch(plist);
      expect(m, isNotNull, reason: key);
      return RegExp('<string>([^<]+)</string>')
          .allMatches(m!.group(1)!)
          .map((x) => x.group(1))
          .toList();
    }

    expect(list('UISupportedInterfaceOrientations'), [
      'UIInterfaceOrientationLandscapeLeft',
      'UIInterfaceOrientationLandscapeRight',
    ]);
    expect(list('UISupportedInterfaceOrientations~ipad'), [
      'UIInterfaceOrientationPortrait',
      'UIInterfaceOrientationPortraitUpsideDown',
      'UIInterfaceOrientationLandscapeLeft',
      'UIInterfaceOrientationLandscapeRight',
    ]);
    expect(plist, contains('<key>UIRequiresFullScreen</key>\n\t<true/>'));
  });

  test('desktop window settings are untouched (macOS 1024x700 minimum, Windows 1024x640 minimum)', () {
    expect(read('macos/Runner/MainFlutterWindow.swift'), contains('1024'));
    expect(
      read('windows/runner/win32_window.cpp'),
      contains('constexpr int kMinClientWidth = 1024;'),
    );
  });
}
