import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeAuthService auth;
  late MemoryTokenStore store;
  late SessionController s;

  setUp(() {
    auth = FakeAuthService();
    store = MemoryTokenStore();
    s = SessionController(auth, store);
  });
  tearDown(() => s.dispose());

  test('starts at device login when nothing is stored', () async {
    await s.restore();
    expect(s.phase, SessionPhase.deviceLogin);
    expect(s.activeToken, isNull);
  });

  test('a stored device token skips straight to staff sign-in', () async {
    await store.write(TokenKeys.deviceToken, 'saved');
    await store.write(TokenKeys.deviceIdentifier, 'REG-1');
    await s.restore();
    expect(s.phase, SessionPhase.staffLogin);
    expect(s.deviceIdentifier, 'REG-1');
    expect(s.activeToken, 'saved');
  });

  test('full flow: device -> staff -> shift -> ready, using the right token at each step', () async {
    await s.restore();
    String? staffSawDeviceToken;
    String? shiftSawStaffToken;
    auth.onStaff = (d, i, p) async {
      staffSawDeviceToken = d;
      return 'staff-token';
    };
    auth.onShift = (t, a) async {
      shiftSawStaffToken = t;
      return 3;
    };
    expect(await s.loginDevice(' REG-1 ', 'secret'), isTrue);
    expect(s.phase, SessionPhase.staffLogin);
    expect(await s.loginStaff('S1', '1234'), isTrue);
    expect(s.phase, SessionPhase.shiftOpen);
    expect(await s.openShift(100), isTrue);
    expect(s.phase, SessionPhase.ready);
    expect(staffSawDeviceToken, 'device-token');
    expect(shiftSawStaffToken, 'staff-token');
    expect(s.activeToken, 'staff-token');
    expect(auth.log, [
      'device:REG-1',
      'staff:S1',
      'authContext',
      'shift:100.0',
    ]);
  });

  test('only the device token and identifier are persisted — never the staff token, PIN or secret', () async {
    await s.restore();
    await s.loginDevice('REG-1', 'the-secret');
    await s.loginStaff('S1', '9999');
    expect(await store.read(TokenKeys.deviceToken), 'device-token');
    expect(await store.read(TokenKeys.deviceIdentifier), 'REG-1');
    final all = [
      for (final k in [
        'pos_device_token',
        'pos_device_identifier',
        'staff',
        'pin',
        'secret',
        'pos_staff_token',
      ])
        await store.read(k),
    ];
    expect(all.whereType<String>().toSet(), {'device-token', 'REG-1'});
  });

  test('bad device credentials: error kept, stays on device login', () async {
    await s.restore();
    auth.onDevice = (_, _) async =>
        throw apiError(401, message: 'Invalid device credentials');
    expect(await s.loginDevice('x', 'y'), isFalse);
    expect(s.phase, SessionPhase.deviceLogin);
    expect(s.error!.message, 'Invalid device credentials');
    expect(await store.read(TokenKeys.deviceToken), isNull);
  });

  test(
    'wrong PIN keeps the cashier on the PIN screen (device stays registered)',
    () async {
      await s.restore();
      await s.loginDevice('REG-1', 's');
      auth.onStaff = (_, _, _) async => throw apiError(
        401,
        message: 'Invalid staff credentials or account unavailable',
        code: 'POS_INVALID_STAFF_CREDENTIALS',
      );
      expect(await s.loginStaff('S1', 'bad'), isFalse);
      expect(s.phase, SessionPhase.staffLogin);
      expect(await store.read(TokenKeys.deviceToken), 'device-token');
    },
  );

  test('a stored device token that has actually expired bounces back to device '
      'login with a clear message, instead of showing the raw backend error on '
      'the PIN screen as if the PIN were wrong', () async {
    await store.write(TokenKeys.deviceToken, 'stale');
    await store.write(TokenKeys.deviceIdentifier, 'REG-1');
    await s.restore();
    expect(
      s.phase,
      SessionPhase.staffLogin,
      reason: 'restore() trusts the stored token at first',
    );
    // The backend's posDeviceAuth rejects the token itself, before the PIN
    // is ever checked — no POS_INVALID_STAFF_CREDENTIALS code.
    auth.onStaff = (_, _, _) async =>
        throw apiError(401, message: 'Invalid or expired POS token');
    expect(await s.loginStaff('S1', '1234'), isFalse);
    expect(s.phase, SessionPhase.deviceLogin);
    expect(s.error!.message, 'This device needs to be signed in again.');
    expect(
      await store.read(TokenKeys.deviceToken),
      isNull,
      reason: 'the dead device token is forgotten, not retried forever',
    );
  });

  test('other 401 reasons for the device token during staff-login are treated the same way', () async {
    await s.restore();
    await s.loginDevice('REG-1', 's');
    for (final message in [
      'Device is no longer authorized',
      'Token is missing device binding',
      'A valid device token is required before staff login',
    ]) {
      await s.loginDevice('REG-1', 's'); // re-register between cases
      auth.onStaff = (_, _, _) async => throw apiError(401, message: message);
      expect(await s.loginStaff('S1', '1234'), isFalse, reason: message);
      expect(s.phase, SessionPhase.deviceLogin, reason: message);
    }
  });

  test(
    'a register that already has an open shift (409) continues normally',
    () async {
      await s.restore();
      await s.loginDevice('REG-1', 's');
      await s.loginStaff('S1', '1');
      auth.onShift = (_, _) async => throw apiError(
        409,
        message: 'This register already has an open shift',
      );
      expect(await s.openShift(0), isTrue);
      expect(s.phase, SessionPhase.ready);
      expect(s.notice, contains('already has an open shift'));
    },
  );

  test('other shift errors are surfaced and keep the shift screen', () async {
    await s.restore();
    await s.loginDevice('REG-1', 's');
    await s.loginStaff('S1', '1');
    auth.onShift = (_, _) async =>
        throw apiError(422, message: 'opening_amount is required');
    expect(await s.openShift(0), isFalse);
    expect(s.phase, SessionPhase.shiftOpen);
    expect(s.error!.kind, ApiErrorKind.validation);
  });

  test(
    'a network failure during login is reported and does not advance',
    () async {
      await s.restore();
      auth.onDevice = (_, _) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      expect(await s.loginDevice('a', 'b'), isFalse);
      expect(s.phase, SessionPhase.deviceLogin);
      expect(s.error!.isRetryable, isTrue);
    },
  );

  test('double-submitting a login sends one request', () async {
    await s.restore();
    final f1 = s.loginDevice('a', 'b');
    final f2 = s.loginDevice('a', 'b');
    expect(await f2, isFalse);
    await f1;
    expect(auth.log.where((l) => l.startsWith('device')), hasLength(1));
  });

  group('expired sessions (401 from an authenticated call)', () {
    setUp(() async {
      await s.restore();
      await s.loginDevice('REG-1', 's');
      await s.loginStaff('S1', '1');
      await s.openShift(0);
    });

    test(
      'staff token expiry returns to the PIN screen and drops the staff token',
      () {
        s.handleUnauthorized();
        expect(s.phase, SessionPhase.staffLogin);
        expect(s.activeToken, 'device-token');
        expect(s.error!.isUnauthorized, isTrue);
      },
    );

    test('parallel 401s from the same expired staff token sign out once and do NOT forget the device', () async {
      s.handleUnauthorized('staff-token');
      s.handleUnauthorized('staff-token');
      s.handleUnauthorized('staff-token');
      expect(s.phase, SessionPhase.staffLogin);
      expect(s.activeToken, 'device-token');
      expect(await store.read(TokenKeys.deviceToken), 'device-token');
    });

    test('a 401 for a token that is no longer active is ignored', () {
      s.handleUnauthorized('some-old-token');
      expect(s.phase, SessionPhase.ready);
    });

    test(
      'device token expiry returns to device login and clears the stored token',
      () async {
        s.handleUnauthorized(); // staff -> pin screen
        s.handleUnauthorized(); // device -> device login
        expect(s.phase, SessionPhase.deviceLogin);
        await Future<void>.delayed(Duration.zero);
        expect(await store.read(TokenKeys.deviceToken), isNull);
      },
    );
  });

  test('logoutStaff clears the staff token but keeps the device', () async {
    await s.restore();
    await s.loginDevice('REG-1', 's');
    await s.loginStaff('S1', '1');
    s.logoutStaff();
    expect(s.phase, SessionPhase.staffLogin);
    expect(s.activeToken, 'device-token');
  });

  test('changeDevice forgets the device', () async {
    await s.restore();
    await s.loginDevice('REG-1', 's');
    await s.changeDevice();
    expect(s.phase, SessionPhase.deviceLogin);
    expect(await store.read(TokenKeys.deviceToken), isNull);
  });

  group('auth context (Phase 17.1)', () {
    PosAuthContext ctx(List<String> permissions) => PosAuthContext(
      staff: const StaffInfo(
        salesmanId: 'S1',
        name: 'Test Staff',
        role: StaffRole(id: 5, name: 'Cashier'),
      ),
      permissions: permissions,
    );

    test(
      'a successful staff login fetches and stores the auth context in memory',
      () async {
        auth.onAuthContext = (t) async => ctx(['sales.view', 'sales.create']);
        await s.restore();
        await s.loginDevice('REG-1', 's');
        await s.loginStaff('S1', '1');

        expect(s.authContext, isNotNull);
        expect(s.authContext!.staff.role!.name, 'Cashier');
        expect(s.permissions.hasPermission('sales.view'), isTrue);
        expect(s.authContextError, isNull);
      },
    );

    test(
      'a failed auth-context fetch never blocks a successful staff login (best-effort only)',
      () async {
        auth.onAuthContext = (t) async =>
            throw const ApiException(kind: ApiErrorKind.network, message: 'down');
        await s.restore();
        await s.loginDevice('REG-1', 's');
        final ok = await s.loginStaff('S1', '1');

        expect(ok, isTrue, reason: 'the PIN was correct — login must still succeed');
        expect(s.phase, SessionPhase.shiftOpen);
        expect(s.authContext, isNull);
        expect(s.authContextError, isNotNull);
      },
    );

    test('refreshAuthContext replaces the in-memory context', () async {
      auth.onAuthContext = (t) async => ctx(['sales.view']);
      await s.restore();
      await s.loginDevice('REG-1', 's');
      await s.loginStaff('S1', '1');
      expect(s.permissions.hasPermission('payments.refund'), isFalse);

      auth.onAuthContext = (t) async => ctx(['sales.view', 'payments.refund']);
      await s.refreshAuthContext();
      expect(s.permissions.hasPermission('payments.refund'), isTrue);
    });

    test(
      'refreshAuthContext keeps the previous context if the refresh itself fails (does not silently revoke)',
      () async {
        auth.onAuthContext = (t) async => ctx(['payments.refund']);
        await s.restore();
        await s.loginDevice('REG-1', 's');
        await s.loginStaff('S1', '1');

        auth.onAuthContext = (t) async =>
            throw const ApiException(kind: ApiErrorKind.network, message: 'down');
        await s.refreshAuthContext();

        expect(
          s.permissions.hasPermission('payments.refund'),
          isTrue,
          reason: 'a transient refresh failure must not revoke an already-loaded context',
        );
        expect(s.authContextError, isNotNull);
      },
    );

    test('refreshAuthContext is a no-op with no staff token', () async {
      await s.restore();
      await s.refreshAuthContext();
      expect(s.authContext, isNull);
      expect(auth.log, isEmpty);
    });

    test('logoutStaff clears the auth context', () async {
      auth.onAuthContext = (t) async => ctx(['sales.view']);
      await s.restore();
      await s.loginDevice('REG-1', 's');
      await s.loginStaff('S1', '1');
      expect(s.authContext, isNotNull);

      s.logoutStaff();
      expect(s.authContext, isNull);
      expect(s.permissions.hasPermission('sales.view'), isFalse);
    });

    test('a 401 from an authenticated call clears the auth context along with the staff token', () async {
      auth.onAuthContext = (t) async => ctx(['sales.view']);
      await s.restore();
      await s.loginDevice('REG-1', 's');
      await s.loginStaff('S1', '1');
      final staffToken = s.activeToken;

      s.handleUnauthorized(staffToken);
      expect(s.authContext, isNull);
      expect(s.phase, SessionPhase.staffLogin);
    });
  });
}
