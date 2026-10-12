// Phase 6ZB — Windows desktop support. These tests run on the development
// machine (macOS), NOT on Windows: Dart-level behaviour is exercised with
// the target platform set to Windows, the single-instance lock is exercised
// against a REAL second process (POSIX file locking on this host — Windows'
// LockFileEx path still needs a run on a Windows machine), and the generated
// Windows runner / resources are checked statically.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:buskit_pos/core/desktop/exit_guard.dart';
import 'package:buskit_pos/core/desktop/single_instance.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/barcode/camera_scanner.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

const holderScript = r'''
import 'dart:io';
Future<void> main(List<String> args) async {
  final f = await File(args[0]).open(mode: FileMode.append);
  await f.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdin.drain<void>();
}
''';

/// A separate process holding the lock until [release] is called.
class LockHolder {
  LockHolder._(this._p, this._sub);
  final Process _p;
  final StreamSubscription<String> _sub;

  static Future<LockHolder> start(Directory dir) async {
    final script = File('${dir.path}/holder.dart')..writeAsStringSync(holderScript);
    final p = await Process.start('dart', [script.path, '${dir.path}/${SingleInstanceLock.fileName}']);
    final locked = Completer<void>();
    final sub = p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      if (l.trim() == 'locked' && !locked.isCompleted) locked.complete();
    });
    await locked.future.timeout(const Duration(seconds: 60));
    return LockHolder._(p, sub);
  }

  Future<void> release() async {
    await _p.stdin.close();
    await _p.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
      _p.kill();
      return -1;
    });
    await _sub.cancel();
  }
}

void main() {
  group('Windows feature guards (Dart, target platform = Windows)', () {
    test('voice input is not offered on Windows: the unsupported permission, never permission_handler', () async {
      final mic = defaultMicrophonePermission(TargetPlatform.windows);
      expect(mic, isA<UnsupportedPlatformMicrophone>());
      expect(await mic.request(), VoicePermission.unsupportedPlatform);
      expect(defaultMicrophonePermission(TargetPlatform.linux), isA<UnsupportedPlatformMicrophone>());
      expect(defaultMicrophonePermission(TargetPlatform.android), isA<PermissionHandlerMicrophone>(), reason: 'mobile unchanged');
      expect(defaultMicrophonePermission(TargetPlatform.iOS), isA<PermissionHandlerMicrophone>());
    });

    test('camera scanning is off on Windows and macOS (keyboard-wedge scanners are used), on for Android / iOS', () {
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      for (final p in [TargetPlatform.windows, TargetPlatform.macOS]) {
        debugDefaultTargetPlatformOverride = p;
        expect(const MobileCameraScanner().supported, isFalse, reason: '$p');
      }
      for (final p in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = p;
        expect(const MobileCameraScanner().supported, isTrue, reason: '$p');
      }
    });

    test('Windows keeps the secure-storage defaults (only macOS changes its Keychain option)', () {
      expect('${platformSecureStorage(TargetPlatform.windows).mOptions.toMap()['usesDataProtectionKeychain']}', 'true');
    });

    testWidgets('quit (closing the window) is refused while a cart operation runs on Windows, allowed afterwards', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final h = PageHarness();
      final gate = Completer<CartSale>();
      h.carts.onAdd = (_) => gate.future;
      await pumpProductsPage(tester, h);
      await tester.tap(find.text('Add').first);
      await tester.pump();
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel);
      await tester.pump();
      expect(find.text(exitBlockedMessage), findsOneWidget);
      gate.complete(CartSaleFactory.sale(items: [lineJson(id: 1, name: 'Tea')], total: 112));
      await tester.pumpAndSettle();
      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.exit);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('single instance (real second process on this host)', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('pos_instance_win_'));
    tearDown(() async {
      await SingleInstanceLock.release();
      await dir.delete(recursive: true);
    });

    test('Windows is guarded like macOS', () {
      expect(SingleInstanceLock.appliesTo(TargetPlatform.windows), isTrue);
    });

    test('a running copy is still refused after the short retries (no lock "expires" while it runs)', () async {
      final holder = await LockHolder.start(dir);
      try {
        final watch = Stopwatch()..start();
        final claim = await SingleInstanceLock.acquire(dir, retry: const [Duration(milliseconds: 150), Duration(milliseconds: 150)]);
        expect(claim.ownership, InstanceOwnership.heldElsewhere);
        expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(300), reason: 'both retries were waited');
      } finally {
        await holder.release();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('a lock released during the retry window (e.g. the OS freeing a crashed copy) is then acquired', () async {
      final holder = await LockHolder.start(dir);
      unawaited(Future<void>.delayed(const Duration(milliseconds: 200), holder.release));
      final claim = await SingleInstanceLock.acquire(dir, retry: const [Duration(seconds: 2), Duration(seconds: 2)]);
      expect(claim.ownership, InstanceOwnership.acquired);
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('an open blocked by a Windows sharing violation means another copy; other open failures fail closed', () {
      FileSystemException fail(int code) => FileSystemException('open failed', 'x', OSError('e', code));
      expect(SingleInstanceLock.classifyOpenFailure(fail(32), windows: true), InstanceOwnership.heldElsewhere);
      expect(SingleInstanceLock.classifyOpenFailure(fail(5), windows: true), InstanceOwnership.failed, reason: 'access denied');
      expect(SingleInstanceLock.classifyOpenFailure(fail(32), windows: false), InstanceOwnership.failed);
      expect(SingleInstanceLock.classifyOpenFailure(const FileSystemException('no os error'), windows: true), InstanceOwnership.failed);
    });
  });

  group('generated Windows project (static checks)', () {
    String read(String p) => File(p).readAsStringSync();

    test('plugins registered for Windows: storage, printing, share, TTS, URL; no camera scanner', () {
      final plugins = read('windows/flutter/generated_plugins.cmake');
      for (final p in ['flutter_secure_storage_windows', 'printing', 'share_plus', 'flutter_tts', 'url_launcher_windows']) {
        expect(plugins, contains(p), reason: p);
      }
      expect(plugins.contains('mobile_scanner'), isFalse, reason: 'no Windows implementation; camera scanning is off');
    });

    test('window: ThriveWoo POS title, 1280 x 720 initial size, DPI-aware 1024 x 640 minimum client area', () {
      final mainCpp = read('windows/runner/main.cpp');
      expect(mainCpp, contains('window.Create(L"ThriveWoo POS", origin, size)'));
      expect(mainCpp, contains('Win32Window::Size size(1280, 720);'));
      final win = read('windows/runner/win32_window.cpp');
      expect(win, contains('constexpr int kMinClientWidth = 1024;'));
      expect(win, contains('constexpr int kMinClientHeight = 640;'));
      expect(win, contains('case WM_GETMINMAXINFO:'));
      expect(win, contains('FlutterDesktopGetDpiForMonitor(monitor) / 96.0'));
      expect(win, contains('info->ptMinTrackSize.x'));
      expect(1024, greaterThanOrEqualTo(900), reason: 'stays above the desktop layout breakpoint');
    });

    test('branding, DPI awareness and the Windows 10+ manifest', () {
      final rc = read('windows/runner/Runner.rc');
      expect(rc, contains('VALUE "ProductName", "ThriveWoo POS"'));
      expect(rc, contains('VALUE "CompanyName", "ThriveWoo"'));
      final manifest = read('windows/runner/runner.exe.manifest');
      expect(manifest, contains('PerMonitorV2'));
      expect(manifest, contains('{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}'), reason: 'Windows 10 / 11');
      expect(read('windows/CMakeLists.txt'), contains('set(BINARY_NAME "buskit_pos")'));
    });
  });
}
