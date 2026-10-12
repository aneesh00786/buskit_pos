// Phase 6ZA — macOS platform support: voice reports a clear unsupported state
// on macOS without touching permission_handler; secure storage uses the
// legacy Keychain on macOS only; one app process owns the offline storage
// (an OS file lock, checked against a REAL second process); quitting is
// refused while a sale or payment is in flight; and the native macOS
// configuration grants exactly what the POS needs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:buskit_pos/core/desktop/exit_guard.dart';
import 'package:buskit_pos/core/desktop/instance_blocked_app.dart';
import 'package:buskit_pos/core/desktop/single_instance.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class CountingRecognizer implements SpeechRecognizer {
  int initCalls = 0;
  int listenCalls = 0;
  @override
  Future<bool> initialize({required void Function(String error) onError, required void Function(String status) onStatus}) async {
    initCalls++;
    return true;
  }

  @override
  Future<void> listen({required void Function(String text, bool isFinal) onResult, VoiceLanguage language = VoiceLanguage.english}) async => listenCalls++;
  @override
  Future<void> stop() async {}
  @override
  Future<void> cancel() async {}
}

const staff = PosTokenScope(companyId: 1, storeId: 2, registerId: 3, deviceId: 4, salesmanId: 'S-1');

/// A SEPARATE process that takes the same exclusive lock and holds it until
/// its stdin closes. Prints "locked" once it owns it.
const holderScript = r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final f = await File(args[0]).open(mode: FileMode.append);
  await f.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
}
''';

void main() {
  group('voice on macOS', () {
    test('macOS gets the unsupported-platform permission; Android and iOS keep permission_handler', () {
      expect(defaultMicrophonePermission(TargetPlatform.macOS), isA<UnsupportedPlatformMicrophone>());
      expect(defaultMicrophonePermission(TargetPlatform.android), isA<PermissionHandlerMicrophone>());
      expect(defaultMicrophonePermission(TargetPlatform.iOS), isA<PermissionHandlerMicrophone>());
    });

    test('the unsupported permission never asks and never opens settings', () async {
      const mic = UnsupportedPlatformMicrophone();
      expect(await mic.status(), VoicePermission.unsupportedPlatform);
      expect(await mic.request(), VoicePermission.unsupportedPlatform);
      expect(await mic.openSettings(), isFalse);
    });

    test('starting voice on macOS shows a clear message; the recognizer is never initialized', () async {
      final speech = CountingRecognizer();
      final voice = VoiceController(permission: const UnsupportedPlatformMicrophone(), recognizer: speech, scope: () => staff);
      addTearDown(voice.dispose);
      expect(await voice.start(), isFalse);
      expect(voice.state, VoiceState.error);
      expect(voice.error, contains('not available in the desktop app'));
      expect(voice.needsSettings, isFalse);
      expect((speech.initCalls, speech.listenCalls), (0, 0));
    });
  });

  group('secure storage', () {
    test('macOS uses the legacy Keychain (no keychain-access-groups needed); other platforms keep the defaults', () {
      // What the plugin sends to the native side.
      String dpk(TargetPlatform p) => '${platformSecureStorage(p).mOptions.toMap()['usesDataProtectionKeychain']}';
      expect(dpk(TargetPlatform.macOS), 'false');
      expect(dpk(TargetPlatform.android), 'true');
      expect(dpk(TargetPlatform.iOS), 'true');
    });
  });

  group('single instance', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('pos_instance_'));
    tearDown(() async {
      await SingleInstanceLock.release();
      await Process.run('chmod', ['-R', 'u+w', dir.path]);
      await dir.delete(recursive: true);
    });

    test('only desktop platforms are guarded; Android / iOS get no claim', () async {
      expect(SingleInstanceLock.appliesTo(TargetPlatform.macOS), isTrue);
      expect(SingleInstanceLock.appliesTo(TargetPlatform.windows), isTrue);
      expect(SingleInstanceLock.appliesTo(TargetPlatform.android), isFalse);
      expect(SingleInstanceLock.appliesTo(TargetPlatform.iOS), isFalse);
      expect(await claimDesktopInstance(platform: TargetPlatform.android), isNull);
      expect(await claimDesktopInstance(platform: TargetPlatform.iOS), isNull);
    });

    test('this process acquires the storage; claiming again in the same process is idempotent', () async {
      expect((await SingleInstanceLock.acquire(dir)).ownership, InstanceOwnership.acquired);
      expect((await SingleInstanceLock.acquire(dir)).ownership, InstanceOwnership.acquired);
      expect(File('${dir.path}/${SingleInstanceLock.fileName}').existsSync(), isTrue);
    });

    test('a SECOND PROCESS holding the lock blocks this one; once it exits, ownership is acquired (no stale lock)', () async {
      final script = File('${dir.path}/holder.dart')..writeAsStringSync(holderScript);
      final holder = await Process.start('dart', [script.path, '${dir.path}/${SingleInstanceLock.fileName}']);
      final lines = holder.stdout.transform(utf8.decoder).transform(const LineSplitter());
      final locked = Completer<void>();
      final sub = lines.listen((l) {
        if (l.trim() == 'locked' && !locked.isCompleted) locked.complete();
      });
      try {
        await locked.future.timeout(const Duration(seconds: 60));
        final blocked = await SingleInstanceLock.acquire(dir);
        expect(blocked.ownership, InstanceOwnership.heldElsewhere);
        expect(blocked.acquired, isFalse);
      } finally {
        await holder.stdin.close();
        await holder.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
          holder.kill();
          return -1;
        });
        await sub.cancel();
      }
      expect((await SingleInstanceLock.acquire(dir)).ownership, InstanceOwnership.acquired, reason: 'released when the other process ended');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a folder that cannot be used fails CLOSED (the POS does not start)', () async {
      final ro = Directory('${dir.path}/readonly')..createSync();
      await Process.run('chmod', ['555', ro.path]);
      final claim = await SingleInstanceLock.acquire(Directory('${ro.path}/offline'));
      expect(claim.ownership, InstanceOwnership.failed);
      expect(claim.acquired, isFalse);
    });

    testWidgets('the blocking screens say what to do and start nothing else', (tester) async {
      await tester.pumpWidget(const InstanceBlockedApp(claim: InstanceClaim(InstanceOwnership.heldElsewhere)));
      expect(find.text(InstanceBlockedApp.alreadyRunningTitle), findsOneWidget);
      expect(find.text(InstanceBlockedApp.alreadyRunningMessage), findsOneWidget);
      await tester.pumpWidget(const InstanceBlockedApp(claim: InstanceClaim(InstanceOwnership.failed, detail: 'EACCES')));
      expect(find.text(InstanceBlockedApp.checkFailedTitle), findsOneWidget);
      expect(find.textContaining('EACCES'), findsNothing, reason: 'no raw error text');
    });
  });

  group('quitting the desktop app', () {
    test('refused while a cart operation or a provider payment is in flight; allowed otherwise', () {
      expect(decideAppExit(cartBusy: false, paymentBusy: false), AppExitResponse.exit);
      expect(decideAppExit(cartBusy: true, paymentBusy: false), AppExitResponse.cancel);
      expect(decideAppExit(cartBusy: false, paymentBusy: true), AppExitResponse.cancel);
    });

    test('a tracked payment counts as in flight until it finishes, also when it fails', () async {
      expect(InFlightOperations.busy, isFalse);
      final gate = Completer<String>();
      final running = InFlightOperations.track(() => gate.future);
      expect(InFlightOperations.busy, isTrue);
      expect(decideAppExit(cartBusy: false), AppExitResponse.cancel);
      gate.complete('done');
      expect(await running, 'done');
      expect(InFlightOperations.busy, isFalse);
      await expectLater(InFlightOperations.track<void>(() async => throw StateError('declined')), throwsStateError);
      expect(InFlightOperations.busy, isFalse);
      expect(decideAppExit(cartBusy: false), AppExitResponse.exit);
    });
  });

  group('native macOS configuration', () {
    String read(String p) => File(p).readAsStringSync();

    test('outbound network (API + LAN printer) in debug AND release; no microphone, camera or keychain-group grants', () {
      for (final f in ['macos/Runner/DebugProfile.entitlements', 'macos/Runner/Release.entitlements']) {
        final e = read(f);
        expect(e, contains('<key>com.apple.security.app-sandbox</key>'), reason: f);
        expect(e, contains('<key>com.apple.security.network.client</key>'), reason: f);
        for (final no in ['device.audio-input', 'device.camera', 'keychain-access-groups', 'files.user-selected', 'files.downloads']) {
          expect(e.contains(no), isFalse, reason: '$f must not grant $no');
        }
      }
      expect(read('macos/Runner/Release.entitlements').contains('network.server'), isFalse, reason: 'release accepts no inbound connections');
      final info = read('macos/Runner/Info.plist');
      expect(info.contains('NSMicrophoneUsageDescription'), isFalse);
      expect(info.contains('NSCameraUsageDescription'), isFalse);
    });

    test('the window opens at a till size and never shrinks below the cashier layout minimum', () {
      final w = read('macos/Runner/MainFlutterWindow.swift');
      expect(w, contains('self.contentMinSize = NSSize(width: 1024, height: 700)'));
      expect(w, contains('self.setContentSize(NSSize(width: 1366, height: 860))'));
      expect(1024, greaterThanOrEqualTo(900), reason: 'stays above the 900 px desktop/dialog breakpoint');
    });

    test('the bundle identifier and deployment target', () {
      expect(read('macos/Runner/Configs/AppInfo.xcconfig'), contains('PRODUCT_BUNDLE_IDENTIFIER = com.thrivewoo.buskitPos'));
      expect(read('macos/Podfile'), contains("platform :osx, '12.0'"));
    });
  });
}
