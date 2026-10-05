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

CashMovement deposit({int id = 1, double amount = 50, String? reason}) => CashMovement(
  id: id,
  amount: amount,
  reason: reason,
  status: 'completed',
  shiftId: 7,
  movementType: CashMovementType.deposit,
  createdAt: DateTime(2026, 1, 1, 10, 30),
);

CashMovement withdrawal({int id = 1, double amount = 50, String? reason}) => CashMovement(
  id: id,
  amount: amount,
  reason: reason,
  status: 'completed',
  shiftId: 7,
  createdAt: DateTime(2026, 1, 1, 10, 30),
);

Future<SessionController> sessionWith(List<String>? permissions) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
      permissions: permissions,
    );
  }
  final session = SessionController(auth, MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return session;
}

Future<CashMovementController> pump(
  WidgetTester tester, {
  FakeCashMovementService? service,
  List<String>? permissions,
}) async {
  final svc = service ?? FakeCashMovementService();
  final controller = CashMovementController(svc);
  final session = await sessionWith(permissions);
  tester.view.physicalSize = const Size(480, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  addTearDown(session.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<CashMovementController>.value(value: controller),
        ChangeNotifierProvider<SessionController>.value(value: session),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: CashManagementGate())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Finder inAlert(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

Future<void> fillDeposit(WidgetTester tester, {String amount = '50', String? reason = 'Float top-up'}) async {
  await tester.tap(find.text('Cash Deposit'));
  await tester.pumpAndSettle();
  await tester.enterText(inAlert(find.byType(TextField)).first, amount);
  if (reason != null) await tester.enterText(inAlert(find.byType(TextField)).last, reason);
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

Future<void> fillAndConfirmDeposit(WidgetTester tester, {String amount = '50', String? reason = 'Float top-up'}) async {
  await fillDeposit(tester, amount: amount, reason: reason);
  await tester.tap(inAlert(find.widgetWithText(FilledButton, 'Deposit')));
  await tester.pumpAndSettle();
}

void main() {
  group('model', () {
    test('parses movement_type; missing type defaults to WITHDRAWAL', () {
      final d = CashMovement.fromJson({
        'id': 1, 'amount': 5, 'status': 'completed', 'shift_id': 1, 'movement_type': 'DEPOSIT',
      })!;
      expect(d.isDeposit, isTrue);
      final legacy = CashMovement.fromJson({'id': 2, 'amount': 5, 'status': 'completed', 'shift_id': 1})!;
      expect(legacy.movementType, CashMovementType.withdrawal);
      expect(legacy.isDeposit, isFalse);
    });
  });

  group('controller deposit', () {
    test('success prepends the deposit, then reloads history from the backend', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      await c.load();
      final listCallsBefore = svc.listCalls;
      final ok = await c.deposit(amount: '75.000', reason: 'Float');
      expect(ok, isTrue);
      expect(c.lastDeposit!.isDeposit, isTrue);
      expect(c.movements.first.id, c.lastDeposit!.id);
      expect(svc.listCalls, listCallsBefore + 1, reason: 'history is re-read after success');
    });

    test('a failed post-success reload keeps the new deposit visible', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      await c.load();
      svc.onList = () async => throw netDown;
      expect(await c.deposit(amount: '5.000'), isTrue);
      expect(c.movements.single.isDeposit, isTrue);
      expect(c.status, CashMovementListStatus.loaded);
    });

    test('isDepositing only while in flight; a concurrent second movement is a no-op', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      final gate = Completer<CashMovement?>();
      svc.onDeposit = (a, r, k) => gate.future;
      final first = c.deposit(amount: '10.000');
      expect(c.isDepositing, isTrue);
      expect(c.isBusy, isTrue);
      expect(await c.deposit(amount: '10.000'), isFalse);
      expect(await c.withdraw(amount: '10.000'), isFalse, reason: 'one movement in flight at a time');
      gate.complete(deposit());
      await first;
      expect(c.isDepositing, isFalse);
      expect(svc.depositKeys, hasLength(1));
      expect(svc.withdrawKeys, isEmpty);
    });

    test('a failure is captured as depositError, not withdrawError', () async {
      final svc = FakeCashMovementService()..onDeposit = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      expect(await c.deposit(amount: '10.000'), isFalse);
      expect(c.depositError, netDown);
      expect(c.withdrawError, isNull);
      c.clearDepositError();
      expect(c.depositError, isNull);
    });

    test('retry with the SAME amount+reason reuses the key; a changed amount or reason gets a new one', () async {
      final svc = FakeCashMovementService()..onDeposit = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      await c.deposit(amount: '10.000', reason: 'A');
      await c.deposit(amount: '10.000', reason: 'A');
      await c.deposit(amount: '20.000', reason: 'A');
      await c.deposit(amount: '20.000', reason: 'B');
      final k = svc.depositKeys;
      expect(k[0], k[1]);
      expect(k[2], isNot(k[1]));
      expect(k[3], isNot(k[2]));
    });

    test('after success, the same amount+reason is a NEW deposit with a NEW key', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      await c.deposit(amount: '10.000', reason: 'A');
      await c.deposit(amount: '10.000', reason: 'A');
      expect(svc.depositKeys[0], isNot(svc.depositKeys[1]));
    });

    test('deposit and withdrawal never share a key, and a deposit in between keeps the pending withdrawal retry key', () async {
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      await c.withdraw(amount: '10.000', reason: 'Same');
      await c.deposit(amount: '10.000', reason: 'Same');
      await c.withdraw(amount: '10.000', reason: 'Same');
      expect(svc.depositKeys.single, isNot(svc.withdrawKeys.first));
      expect(svc.withdrawKeys[0], svc.withdrawKeys[1]);
    });
  });

  group('permission gating', () {
    testWidgets('no context loaded -> section and both buttons visible', (tester) async {
      await pump(tester);
      expect(find.text('Cash Management'), findsOneWidget);
      expect(find.text('Cash Withdrawal'), findsOneWidget);
      expect(find.text('Cash Deposit'), findsOneWidget);
    });

    testWidgets('deposit only -> section visible, withdrawal button hidden', (tester) async {
      await pump(tester, permissions: ['payments.cash_deposit']);
      expect(find.text('Cash Management'), findsOneWidget);
      expect(find.text('Cash Deposit'), findsOneWidget);
      expect(find.text('Cash Withdrawal'), findsNothing);
    });

    testWidgets('withdrawal only -> deposit button hidden', (tester) async {
      await pump(tester, permissions: ['payments.cash_withdrawal']);
      expect(find.text('Cash Withdrawal'), findsOneWidget);
      expect(find.text('Cash Deposit'), findsNothing);
    });

    testWidgets('both -> both buttons', (tester) async {
      await pump(tester, permissions: ['payments.cash_withdrawal', 'payments.cash_deposit']);
      expect(find.text('Cash Withdrawal'), findsOneWidget);
      expect(find.text('Cash Deposit'), findsOneWidget);
    });

    testWidgets('neither -> whole section hidden', (tester) async {
      await pump(tester, permissions: ['sales.view']);
      expect(find.text('Cash Management'), findsNothing);
    });
  });

  group('history', () {
    testWidgets('deposits show + and withdrawals show −, each labelled', (tester) async {
      final svc = FakeCashMovementService()
        ..listResult = CurrentShiftCashMovements(
          shift: const CurrentShiftSummary(id: 7, status: 'open', openingAmount: 100),
          movements: [deposit(id: 2, amount: 40, reason: 'Change'), withdrawal(id: 1, amount: 15, reason: 'Petty')],
        );
      await pump(tester, service: svc);
      expect(find.text('+ 40.00'), findsOneWidget);
      expect(find.text('− 15.00'), findsOneWidget);
      expect(find.textContaining('Deposit · Change'), findsOneWidget);
      expect(find.textContaining('Withdrawal · Petty'), findsOneWidget);
    });
  });

  group('deposit flow', () {
    testWidgets('invalid amount is rejected before any request', (tester) async {
      final svc = FakeCashMovementService();
      await pump(tester, service: svc);
      await tester.tap(find.text('Cash Deposit'));
      await tester.pumpAndSettle();
      expect(inAlert(find.text('Cash Deposit')), findsOneWidget, reason: 'dialog title');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an amount greater than 0'), findsOneWidget);
      await tester.enterText(inAlert(find.byType(TextField)).first, '1.2345');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(find.text('Enter an amount greater than 0'), findsOneWidget);
      expect(svc.depositKeys, isEmpty);
    });

    testWidgets('confirmation shows amount and reason; Cancel sends nothing', (tester) async {
      final svc = FakeCashMovementService();
      await pump(tester, service: svc);
      await fillDeposit(tester, amount: '75', reason: 'Bank run');
      expect(find.text('Confirm cash deposit'), findsOneWidget);
      expect(find.text('75.00'), findsOneWidget);
      expect(find.text('Bank run'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(svc.depositKeys, isEmpty);
    });

    testWidgets('no reason is allowed and shown as —', (tester) async {
      await pump(tester);
      await fillDeposit(tester, reason: null);
      expect(find.text('Confirm cash deposit'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('success shows amount/reason/reference/time and the list updates', (tester) async {
      final svc = FakeCashMovementService()
        ..onDeposit = (a, r, k) async => deposit(id: 42, amount: double.parse(a), reason: r);
      await pump(tester, service: svc);
      await fillAndConfirmDeposit(tester);
      expect(find.text('Deposit successful'), findsOneWidget);
      expect(inAlert(find.text('50.00')), findsOneWidget);
      expect(inAlert(find.text('Float top-up')), findsOneWidget);
      expect(find.text('#42'), findsOneWidget);
      expect(find.text('Date/time'), findsOneWidget);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('+ 50.00'), findsOneWidget);
      expect(svc.withdrawKeys, isEmpty, reason: 'a deposit never calls the withdrawal endpoint');
    });

    testWidgets('both buttons are disabled and progress shown while a deposit is in flight', (tester) async {
      final gate = Completer<CashMovement?>();
      final svc = FakeCashMovementService()..onDeposit = (a, r, k) => gate.future;
      await pump(tester, service: svc);
      await fillDeposit(tester, amount: '20');
      await tester.tap(inAlert(find.widgetWithText(FilledButton, 'Deposit')));
      await tester.pump();
      expect(find.text('Processing deposit…'), findsOneWidget);
      ButtonStyleButton buttonFor(String label) => tester.widget<ButtonStyleButton>(
        find.ancestor(of: find.text(label), matching: find.byWidgetPredicate((w) => w is ButtonStyleButton)),
      );
      expect(buttonFor('Processing deposit…').onPressed, isNull);
      expect(buttonFor('Cash Withdrawal').onPressed, isNull);
      gate.complete(deposit());
      await tester.pumpAndSettle();
    });

    testWidgets('403 shows the deposit permission message', (tester) async {
      final svc = FakeCashMovementService()
        ..onDeposit = (a, r, k) async => throw const ApiException(
          kind: ApiErrorKind.forbidden,
          message: 'Forbidden',
          errorCode: PosErrorCodes.permissionDenied,
          data: {'permission': 'payments.cash_deposit'},
        );
      await pump(tester, service: svc);
      await fillAndConfirmDeposit(tester);
      expect(find.textContaining('do not have permission to deposit cash'), findsOneWidget);
    });

    testWidgets('409 conflict is shown clearly', (tester) async {
      final svc = FakeCashMovementService()
        ..onDeposit = (a, r, k) async => throw const ApiException(
          kind: ApiErrorKind.conflict,
          message: 'Shift is not open',
        );
      await pump(tester, service: svc);
      await fillAndConfirmDeposit(tester);
      expect(find.text('Shift is not open'), findsOneWidget);
    });

    testWidgets('network failure, then a retry with the same input reuses the key', (tester) async {
      final svc = FakeCashMovementService()..onDeposit = (a, r, k) async => throw netDown;
      await pump(tester, service: svc);
      await fillAndConfirmDeposit(tester, amount: '30', reason: 'Retry');
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      await fillAndConfirmDeposit(tester, amount: '30', reason: 'Retry');
      expect(svc.depositKeys, hasLength(2));
      expect(svc.depositKeys[0], svc.depositKeys[1]);
    });
  });

  group('error messages', () {
    test('history 403 with any_of describes viewing, not withdrawing', () {
      const e = ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'Forbidden',
        errorCode: PosErrorCodes.permissionDenied,
        data: {
          'permission': 'payments.cash_withdrawal',
          'any_of': ['payments.cash_withdrawal', 'payments.cash_deposit'],
        },
      );
      expect(describeApiError(e), 'You do not have permission to view cash movements.');
    });
  });
}
