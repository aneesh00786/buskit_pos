import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cash_movements/models/cash_movement.dart';
import 'package:buskit_pos/features/cash_movements/state/cash_movement_controller.dart';
import 'package:buskit_pos/features/cash_movements/ui/cash_withdrawal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

Future<SessionController> defaultSession() async {
  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return session;
}

CashMovement movement({int id = 1, double amount = 50, String? reason}) =>
    CashMovement(
      id: id,
      amount: amount,
      reason: reason,
      status: 'completed',
      shiftId: 7,
      createdAt: DateTime(2026, 1, 1, 10, 30),
    );

Future<CashMovementController> pumpCashManagement(
  WidgetTester tester, {
  FakeCashMovementService? service,
  SessionController? session,
  double width = 480,
  double height = 1200,
}) async {
  final svc = service ?? FakeCashMovementService();
  final controller = CashMovementController(svc);
  final sess = session ?? await defaultSession();
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  if (session == null) addTearDown(sess.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<CashMovementController>.value(value: controller),
        ChangeNotifierProvider<SessionController>.value(value: sess),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: const SingleChildScrollView(child: CashManagementGate()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('permission gating', () {
    testWidgets('visible when no auth context has loaded yet', (
      tester,
    ) async {
      await pumpCashManagement(tester);
      expect(find.text('Cash Management'), findsOneWidget);
      expect(find.text('Cash Withdrawal'), findsOneWidget);
    });

    testWidgets(
      'hidden when the loaded context does NOT grant payments.cash_withdrawal',
      (tester) async {
        final auth = FakeAuthService()
          ..onAuthContext = (t) async => const PosAuthContext(
            staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
            permissions: ['sales.view'],
          );
        final session = SessionController(auth, MemoryTokenStore());
        await session.loginDevice('REG-1', 'secret');
        await session.loginStaff('S1', '1234');
        addTearDown(session.dispose);

        await pumpCashManagement(tester, session: session);
        expect(
          find.text('Cash Management'),
          findsNothing,
          reason: 'a positively-known missing permission must hide the whole section',
        );
      },
    );

    testWidgets(
      'visible when the context grants payments.cash_withdrawal',
      (tester) async {
        final auth = FakeAuthService()
          ..onAuthContext = (t) async => const PosAuthContext(
            staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
            permissions: ['payments.cash_withdrawal'],
          );
        final session = SessionController(auth, MemoryTokenStore());
        await session.loginDevice('REG-1', 'secret');
        await session.loginStaff('S1', '1234');
        addTearDown(session.dispose);

        await pumpCashManagement(tester, session: session);
        expect(find.text('Cash Management'), findsOneWidget);
      },
    );

    testWidgets(
      'visible when the auth-context fetch itself failed (never incorrectly denies on missing data)',
      (tester) async {
        final auth = FakeAuthService()
          ..onAuthContext = (t) async =>
              throw const ApiException(kind: ApiErrorKind.network, message: 'down');
        final session = SessionController(auth, MemoryTokenStore());
        await session.loginDevice('REG-1', 'secret');
        await session.loginStaff('S1', '1234');
        addTearDown(session.dispose);

        await pumpCashManagement(tester, session: session);
        expect(find.text('Cash Management'), findsOneWidget);
      },
    );

    testWidgets(
      'a staff switch never leaks the previous staff member\'s permission',
      (tester) async {
        final auth = FakeAuthService()
          ..onAuthContext = (t) async => const PosAuthContext(
            staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
            permissions: ['payments.cash_withdrawal'],
          );
        final session = SessionController(auth, MemoryTokenStore());
        await session.loginDevice('REG-1', 'secret');
        await session.loginStaff('S1', '1234');
        addTearDown(session.dispose);

        await pumpCashManagement(tester, session: session);
        expect(find.text('Cash Management'), findsOneWidget);

        session.logoutStaff();
        auth.onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S2', role: StaffRole(id: 2, name: 'Cashier')),
          permissions: ['sales.view'],
        );
        await session.loginStaff('S2', '5678');
        await tester.pumpAndSettle();

        expect(
          find.text('Cash Management'),
          findsNothing,
          reason: "S2's own (lacking) permissions must apply, not S1's",
        );
      },
    );
  });

  group('withdrawal list', () {
    testWidgets('renders current-shift movements, amount and reason', (
      tester,
    ) async {
      final svc = FakeCashMovementService()
        ..listResult = CurrentShiftCashMovements(
          shift: const CurrentShiftSummary(
            id: 7,
            status: 'open',
            openingAmount: 100,
          ),
          movements: [
            movement(id: 1, amount: 25, reason: 'Petty cash'),
            movement(id: 2, amount: 10, reason: 'Supplier'),
          ],
        );
      await pumpCashManagement(tester, service: svc);
      expect(find.textContaining('Shift #7'), findsOneWidget);
      expect(find.text('− 25.00'), findsOneWidget);
      expect(find.text('− 10.00'), findsOneWidget);
      expect(find.textContaining('Petty cash'), findsOneWidget);
      expect(find.textContaining('Supplier'), findsOneWidget);
    });

    testWidgets('shows an explicit empty state with no movements yet', (
      tester,
    ) async {
      await pumpCashManagement(tester);
      expect(find.text('No cash movements on this shift yet.'), findsOneWidget);
    });
  });

  group('amount and reason validation (the withdrawal form)', () {
    testWidgets('a zero or empty amount is rejected before any request is sent', (
      tester,
    ) async {
      final svc = FakeCashMovementService();
      await pumpCashManagement(tester, service: svc);
      await tester.tap(find.text('Cash Withdrawal'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an amount greater than 0'), findsOneWidget);
      expect(svc.withdrawKeys, isEmpty);

      await tester.enterText(find.byType(TextField).first, '0');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an amount greater than 0'), findsOneWidget);
      expect(svc.withdrawKeys, isEmpty);
    });

    testWidgets('a valid amount with no reason proceeds to confirmation', (
      tester,
    ) async {
      await pumpCashManagement(tester);
      await tester.tap(find.text('Cash Withdrawal'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '50');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm cash withdrawal'), findsOneWidget);
      expect(find.text('—'), findsOneWidget, reason: 'no reason entered');
    });
  });

  group('confirmation dialog', () {
    testWidgets('shows the amount and reason, and Cancel sends nothing', (
      tester,
    ) async {
      final svc = FakeCashMovementService();
      await pumpCashManagement(tester, service: svc);
      await tester.tap(find.text('Cash Withdrawal'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '75');
      await tester.enterText(find.byType(TextField).last, 'Till float');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.text('Confirm cash withdrawal'), findsOneWidget);
      expect(find.textContaining('75'), findsWidgets);
      expect(find.text('Till float'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(svc.withdrawKeys, isEmpty);
    });
  });

  group('submitting a withdrawal', () {
    Future<void> fillAndConfirm(
      WidgetTester tester, {
      String amount = '50',
      String reason = 'Petty cash',
    }) async {
      await tester.tap(find.text('Cash Withdrawal'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, amount);
      await tester.enterText(find.byType(TextField).last, reason);
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Withdraw'));
      await tester.pumpAndSettle();
    }

    testWidgets('a successful withdrawal shows the result dialog', (
      tester,
    ) async {
      final svc = FakeCashMovementService()
        ..onWithdraw = (amount, reason, key) async => movement(
          id: 42,
          amount: double.parse(amount),
          reason: reason,
        );
      await pumpCashManagement(tester, service: svc);
      await fillAndConfirm(tester);

      expect(find.text('Withdrawal successful'), findsOneWidget);
      expect(find.textContaining('50'), findsWidgets);
      expect(find.text('Petty cash'), findsOneWidget);
      expect(find.text('#42'), findsOneWidget);

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      // The new movement is reflected in the list immediately.
      expect(find.textContaining('Petty cash'), findsOneWidget);
    });

    testWidgets('the button shows progress and is disabled while in flight', (
      tester,
    ) async {
      final gate = Completer<CashMovement?>();
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) => gate.future;
      await pumpCashManagement(tester, service: svc);
      await tester.tap(find.text('Cash Withdrawal'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '20');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Withdraw'));
      await tester.pump();

      expect(find.text('Processing withdrawal…'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Processing withdrawal…'),
            )
            .onPressed,
        isNull,
      );
      gate.complete(movement());
      await tester.pumpAndSettle();
    });

    testWidgets('a 403 permission error shows the existing permission-denied message', (
      tester,
    ) async {
      final svc = FakeCashMovementService()
        ..onWithdraw = (a, r, k) async => throw ApiException(
          kind: ApiErrorKind.forbidden,
          message: 'Forbidden',
          errorCode: PosErrorCodes.permissionDenied,
          data: const {'permission': 'payments.cash_withdrawal'},
        );
      await pumpCashManagement(tester, service: svc);
      await fillAndConfirm(tester);
      expect(
        find.textContaining('do not have permission to withdraw cash'),
        findsOneWidget,
      );
    });

    testWidgets('a 409 idempotency conflict is shown clearly', (tester) async {
      const conflict = ApiException(
        kind: ApiErrorKind.conflict,
        message: 'Idempotency key reused with a different request',
      );
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw conflict;
      await pumpCashManagement(tester, service: svc);
      await fillAndConfirm(tester);
      expect(
        find.text('Idempotency key reused with a different request'),
        findsOneWidget,
      );
    });

    testWidgets('a 401 is shown using the existing generic session message', (
      tester,
    ) async {
      const unauthorized = ApiException(
        kind: ApiErrorKind.unauthorized,
        message: 'Your session has expired. Please sign in again.',
      );
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw unauthorized;
      await pumpCashManagement(tester, service: svc);
      await fillAndConfirm(tester);
      expect(
        find.text('Your session has expired. Please sign in again.'),
        findsOneWidget,
      );
    });

    testWidgets(
      'a network failure is shown, and retrying with the SAME amount/reason reuses the same idempotency key',
      (tester) async {
        final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
        await pumpCashManagement(tester, service: svc);
        await fillAndConfirm(tester, amount: '30', reason: 'Retry test');
        expect(find.textContaining('Cannot reach the server'), findsOneWidget);
        expect(svc.withdrawKeys, hasLength(1));

        // Retry with the exact same amount/reason, as if the client never
        // saw the first response.
        await fillAndConfirm(tester, amount: '30', reason: 'Retry test');
        expect(svc.withdrawKeys, hasLength(2));
        expect(svc.withdrawKeys[0], svc.withdrawKeys[1]);
      },
    );
  });
}
