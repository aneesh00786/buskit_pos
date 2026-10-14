// The device activation key (device secret) never expires on its own. Only
// the 12-hour DEVICE TOKEN expires; the device renews it with its stored
// activation key, so time passing never forces re-activation. The key stops
// working only when an administrator resets it (or disables the device);
// then the device asks for the current key — and nothing saved offline is
// touched.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

final expiredDeviceToken = apiError(
  401,
  message: 'Invalid or expired POS token',
);
final rotatedKey = apiError(401, message: 'Invalid device credentials');

void main() {
  late FakeAuthService auth;
  late MemoryTokenStore store;
  late SessionController s;
  late List<String> devicesTokensIssued;

  setUp(() async {
    auth = FakeAuthService();
    store = MemoryTokenStore();
    s = SessionController(auth, store);
    var n = 0;
    devicesTokensIssued = [];
    auth.onDevice = (id, secret) async {
      if (secret != 'KEY-1') throw rotatedKey;
      final t = 'device-token-${++n}';
      devicesTokensIssued.add(t);
      return t;
    };
    await s.restore();
    expect(await s.loginDevice('REG-1', 'KEY-1'), isTrue); // activation
    auth.log.clear();
  });
  tearDown(() => s.dispose());

  int deviceLogins() => auth.log.where((l) => l.startsWith('device:')).length;

  test('expired device token: renewed once with the stored key, the cashier signs in, no re-activation', () async {
    final seen = <String>[];
    auth.onStaff = (deviceToken, id, pin) async {
      seen.add(deviceToken);
      if (deviceToken == 'device-token-1') throw expiredDeviceToken;
      return 'staff-token';
    };
    expect(await s.loginStaff('S1', '1234'), isTrue);
    expect(s.phase, SessionPhase.shiftOpen);
    expect(deviceLogins(), 1, reason: 'one renewal');
    expect(seen, [
      'device-token-1',
      'device-token-2',
    ], reason: 'staff sign-in retried once, with the new token');
    expect(await store.read(TokenKeys.deviceToken), 'device-token-2');
    expect(await store.read(TokenKeys.deviceSecret), 'KEY-1');
  });

  test('the key keeps working however long ago it was entered (many expiries in a row)', () async {
    var current = 'device-token-1';
    auth.onStaff = (deviceToken, id, pin) async {
      if (deviceToken != current) throw expiredDeviceToken;
      return 'staff-token';
    };
    for (var day = 0; day < 30; day++) {
      // Every "day" the device token has expired again.
      current = 'device-token-${day + 2}';
      s.logoutStaff();
      expect(await s.loginStaff('S1', '1234'), isTrue, reason: 'day $day');
    }
    expect(deviceLogins(), 30);
    expect(s.phase, SessionPhase.shiftOpen);
  });

  test('restart with a stored key but no token (token dropped earlier): PIN screen, then renewed at sign-in', () async {
    await store.delete(TokenKeys.deviceToken);
    final s2 = SessionController(auth, store);
    addTearDown(s2.dispose);
    await s2.restore();
    expect(s2.phase, SessionPhase.staffLogin, reason: 'no re-activation');
    auth.onStaff = (deviceToken, id, pin) async => 'staff-token';
    expect(await s2.loginStaff('S1', '1234'), isTrue);
    expect(deviceLogins(), 1);
  });

  test('key reset by an administrator: renewal refused -> activation screen with a clear message; token and key forgotten, identifier kept', () async {
    auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
    auth.onDevice = (id, secret) async =>
        throw rotatedKey; // old key no longer accepted
    expect(await s.loginStaff('S1', '1234'), isFalse);
    expect(s.phase, SessionPhase.deviceLogin);
    expect(s.error!.errorCode, SessionController.activationKeyRefused);
    expect(s.error!.message, contains('activation key'));
    expect(s.error!.message, contains('Sales saved on this device are kept'));
    expect(await store.read(TokenKeys.deviceToken), isNull);
    expect(await store.read(TokenKeys.deviceSecret), isNull);
    expect(s.deviceIdentifier, 'REG-1');
    expect(deviceLogins(), 1, reason: 'one renewal attempt, never a loop');
  });

  test('after a reset, the NEW key activates the device and is stored instead of the old one', () async {
    auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
    auth.onDevice = (id, secret) async {
      if (secret != 'KEY-2') throw rotatedKey;
      return 'device-token-new';
    };
    await s.loginStaff('S1', '1234'); // old key refused -> activation screen
    expect(await s.loginDevice('REG-1', 'KEY-2'), isTrue);
    expect(await store.read(TokenKeys.deviceSecret), 'KEY-2');
    auth.onStaff = (deviceToken, id, pin) async => 'staff-token';
    expect(await s.loginStaff('S1', '1234'), isTrue);
  });

  test('offline / server error while renewing: nothing forgotten, cashier stays on the PIN screen', () async {
    auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
    auth.onDevice = (id, secret) async => throw const ApiException(
      kind: ApiErrorKind.network,
      message: 'offline',
    );
    expect(await s.loginStaff('S1', '1234'), isFalse);
    expect(s.phase, SessionPhase.staffLogin);
    expect(s.error!.kind, ApiErrorKind.network);
    expect(await store.read(TokenKeys.deviceSecret), 'KEY-1');
    expect(await store.read(TokenKeys.deviceToken), 'device-token-1');
  });

  test('register made inactive: the key is kept (still valid) and the server message shown on the PIN screen', () async {
    auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
    auth.onDevice = (id, secret) async => throw apiError(
      401,
      message: "This device's register is inactive. Ask an administrator to reactivate it.",
      code: PosErrorCodes.registerInactive,
    );
    expect(await s.loginStaff('S1', '1234'), isFalse);
    expect(s.phase, SessionPhase.staffLogin);
    expect(s.error!.message, contains('register is inactive'));
    expect(await store.read(TokenKeys.deviceSecret), 'KEY-1');
    // Register reactivated: signing in works again without re-activation.
    auth.onDevice = (id, secret) async => 'device-token-9';
    auth.onStaff = (deviceToken, id, pin) async => 'staff-token';
    expect(await s.loginStaff('S1', '1234'), isTrue);
  });

  test(
    'a wrong PIN never renews the device token or touches the key',
    () async {
      auth.onStaff = (deviceToken, id, pin) async => throw apiError(
        401,
        message: 'Invalid staff credentials or account unavailable',
        code: PosErrorCodes.invalidStaffCredentials,
      );
      expect(await s.loginStaff('S1', 'bad'), isFalse);
      expect(deviceLogins(), 0);
      expect(s.phase, SessionPhase.staffLogin);
      expect(await store.read(TokenKeys.deviceSecret), 'KEY-1');
    },
  );

  test('renewed but the device token is still refused (e.g. device disabled in between): activation screen, no loop', () async {
    auth.onStaff = (deviceToken, id, pin) async =>
        throw apiError(401, message: 'Device is no longer authorized');
    expect(await s.loginStaff('S1', '1234'), isFalse);
    expect(deviceLogins(), 1);
    expect(s.phase, SessionPhase.deviceLogin);
    expect(await store.read(TokenKeys.deviceSecret), isNull);
  });

  test(
    'the activation key never appears in an error message shown to the user',
    () async {
      auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
      auth.onDevice = (id, secret) async => throw rotatedKey;
      await s.loginStaff('S1', '1234');
      expect(s.error!.message.contains('KEY-1'), isFalse);
      expect(s.error.toString().contains('KEY-1'), isFalse);
    },
  );

  test('a key reset never touches offline sales, drafts, the sync queue or payment-recovery markers', () async {
    final dir = await Directory.systemTemp.createTemp('pos_key_offline_');
    addTearDown(() => dir.delete(recursive: true));
    final offline = OfflineStorageService(dir);
    await offline.initialize();
    await offline.addPaymentRecoveryMarker(42);
    for (final sub in ['sales', 'queue', 'drafts']) {
      File(
        '${dir.path}/$sub/local-1.json',
      ).writeAsStringSync(jsonEncode({'local_sale_id': 'local-1', 'in': sub}));
    }
    Future<Map<String, String>> snapshot() async => {
      for (final f in dir.listSync(recursive: true).whereType<File>())
        f.path: f.readAsStringSync(),
    };
    final before = await snapshot();

    auth.onStaff = (deviceToken, id, pin) async => throw expiredDeviceToken;
    auth.onDevice = (id, secret) async => throw rotatedKey;
    await s.loginStaff('S1', '1234'); // key reset -> activation screen
    await s.changeDevice();

    expect(await snapshot(), before);
    expect(await offline.getPaymentRecoveryMarkers(), [42]);
    expect(
      File('lib/features/auth/state/session_controller.dart')
          .readAsStringSync()
          .contains(RegExp(r"import '[^']*offline")),
      isFalse,
      reason: 'the session never imports offline storage',
    );
  });
}
