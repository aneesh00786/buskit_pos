// Phase 6ZD — one application identity on every platform (static checks of
// the platform project files; the macOS bundle produced from them was also
// inspected after `flutter build macos`). Kept identities: the Dart package
// (buskit_pos), the macOS bundle id (com.thrivewoo.buskitPos — also the
// sandbox container that holds the offline data) and the Windows executable
// (buskit_pos.exe). The visible product name is "ThriveWoo POS" everywhere.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String p) => File(p).readAsStringSync();

void main() {
  test('one version source: pubspec drives macOS (CFBundle*) and Windows (FLUTTER_VERSION)', () {
    expect(RegExp(r'^version: \d+\.\d+\.\d+\+\d+$', multiLine: true).hasMatch(read('pubspec.yaml')), isTrue);
    expect(RegExp(r'^name: buskit_pos$', multiLine: true).hasMatch(read('pubspec.yaml')), isTrue, reason: 'Dart package identity kept');
    final plist = read('macos/Runner/Info.plist');
    expect(plist, contains('<string>\$(FLUTTER_BUILD_NAME)</string>'));
    expect(plist, contains('<string>\$(FLUTTER_BUILD_NUMBER)</string>'));
    final rc = read('windows/runner/Runner.rc');
    expect(rc, contains('#define VERSION_AS_STRING FLUTTER_VERSION'));
    expect(rc, contains('#define VERSION_AS_NUMBER FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,FLUTTER_VERSION_PATCH,FLUTTER_VERSION_BUILD'));
  });

  test('macOS: "ThriveWoo POS" (Dock, menu, app bundle), bundle id unchanged, ThriveWoo copyright, Business category', () {
    final info = read('macos/Runner/Configs/AppInfo.xcconfig');
    expect(info, contains('PRODUCT_NAME = ThriveWoo POS'));
    expect(info, contains('PRODUCT_BUNDLE_IDENTIFIER = com.thrivewoo.buskitPos'), reason: 'unchanged: the sandbox container holding the offline data');
    expect(info, contains('PRODUCT_COPYRIGHT = Copyright © 2026 ThriveWoo. All rights reserved.'));
    final plist = read('macos/Runner/Info.plist');
    expect(plist, contains('<key>CFBundleName</key>\n\t<string>\$(PRODUCT_NAME)</string>'));
    expect(plist, contains('<string>public.app-category.business</string>'));
    expect(read('macos/Runner/Base.lproj/MainMenu.xib'), contains('APP_NAME'), reason: 'menu titles follow PRODUCT_NAME');
  });

  test('Windows: "ThriveWoo POS" product, ThriveWoo company and copyright, executable buskit_pos.exe kept', () {
    final rc = read('windows/runner/Runner.rc');
    expect(rc, contains('VALUE "ProductName", "ThriveWoo POS"'));
    expect(rc, contains('VALUE "FileDescription", "ThriveWoo POS"'));
    expect(rc, contains('VALUE "CompanyName", "ThriveWoo"'));
    expect(rc, contains('VALUE "LegalCopyright", "Copyright (C) 2026 ThriveWoo. All rights reserved."'));
    expect(rc, contains('VALUE "OriginalFilename", "buskit_pos.exe"'));
    expect(read('windows/CMakeLists.txt'), contains('set(BINARY_NAME "buskit_pos")'));
    expect(read('windows/runner/main.cpp'), contains('L"ThriveWoo POS"'), reason: 'window title');
  });

  test('Android and iOS already show the same name (unchanged)', () {
    expect(read('android/app/src/main/AndroidManifest.xml'), contains('android:label="ThriveWoo POS"'));
    expect(read('ios/Runner/Info.plist'), contains('<key>CFBundleDisplayName</key>\n\t<string>ThriveWoo POS</string>'));
  });

  test('icons exist for both desktop platforms (still the Flutter default artwork — no ThriveWoo icon asset is in the repository)', () {
    for (final f in ['macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_1024.png', 'windows/runner/resources/app_icon.ico']) {
      expect(File(f).existsSync(), isTrue, reason: f);
    }
    expect(read('windows/runner/Runner.rc'), contains('IDI_APP_ICON            ICON                    "resources\\\\app_icon.ico"'));
  });
}
