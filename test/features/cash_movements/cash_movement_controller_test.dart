import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cash_movements/models/cash_movement.dart';
import 'package:buskit_pos/features/cash_movements/state/cash_movement_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

CashMovement movement({int id = 1, double amount = 100, String? reason}) =>
    CashMovement(
      id: id,
      amount: amount,
      reason: reason,
      status: 'completed',
      shiftId: 1,
      createdAt: DateTime(2026, 1, 1),
    );

void main() {
  group('load / list', () {
    test('loads the current shift and its movements', () async {
      final svc = FakeCashMovementService()
        ..listResult = CurrentShiftCashMovements(
          shift: const CurrentShiftSummary(
            id: 7,
            status: 'open',
            openingAmount: 50,
          ),
          movements: [movement(id: 1), movement(id: 2)],
        );
      final c = CashMovementController(svc);
      await c.load();
      expect(c.status, CashMovementListStatus.loaded);
      expect(c.shift!.id, 7);
      expect(c.movements, hasLength(2));
    });

    test('a load failure is captured as an error', () async {
      final svc = FakeCashMovementService()..onList = () async => throw netDown;
      final c = CashMovementController(svc);
      await c.load();
      expect(c.status, CashMovementListStatus.error);
      expect(c.error, netDown);
    });

    test('retry re-runs load', () async {
      final svc = FakeCashMovementService()..onList = () async => throw netDown;
      final c = CashMovementController(svc);
      await c.load();
      svc.onList = null;
      svc.listResult = const CurrentShiftCashMovements(shift: null, movements: []);
      await c.retry();
      expect(c.status, CashMovementListStatus.loaded);
    });
  });

  group('withdraw', () {
    test('a successful withdrawal prepends the new movement to the list', () async {
      final svc = FakeCashMovementService()
        ..onWithdraw = (amount, reason, key) async =>
            movement(id: 9, amount: double.parse(amount), reason: reason);
      final c = CashMovementController(svc);
      final ok = await c.withdraw(amount: '50.000', reason: 'Petty cash');
      expect(ok, isTrue);
      expect(c.lastWithdrawal!.id, 9);
      expect(c.movements.first.id, 9);
    });

    test('isWithdrawing is true only while the request is in flight', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      final gate = Completer<CashMovement?>();
      svc.onWithdraw = (a, r, k) => gate.future;
      final future = c.withdraw(amount: '10.000');
      expect(c.isWithdrawing, isTrue);
      gate.complete(movement());
      await future;
      expect(c.isWithdrawing, isFalse);
    });

    test('a concurrent second call while one is in flight is a no-op', () async {
      final svc = FakeCashMovementService();
      final c = CashMovementController(svc);
      final gate = Completer<CashMovement?>();
      svc.onWithdraw = (a, r, k) => gate.future;
      final first = c.withdraw(amount: '10.000');
      final second = await c.withdraw(amount: '10.000');
      expect(second, isFalse);
      gate.complete(movement());
      await first;
      expect(svc.withdrawKeys, hasLength(1));
    });

    test('a failure is captured as withdrawError, not thrown', () async {
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      final ok = await c.withdraw(amount: '10.000');
      expect(ok, isFalse);
      expect(c.withdrawError, netDown);
    });

    test('clearWithdrawError only touches the withdraw error', () async {
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      await c.withdraw(amount: '10.000');
      expect(c.withdrawError, isNotNull);
      c.clearWithdrawError();
      expect(c.withdrawError, isNull);
    });

    test(
      'a retry with the SAME amount+reason after a failure reuses the same idempotency key (safe replay)',
      () async {
        final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
        final c = CashMovementController(svc);
        await c.withdraw(amount: '10.000', reason: 'Till float');
        await c.withdraw(amount: '10.000', reason: 'Till float');
        expect(svc.withdrawKeys, hasLength(2));
        expect(svc.withdrawKeys[0], svc.withdrawKeys[1]);
      },
    );

    test('changing the amount after a failure gets a NEW idempotency key', () async {
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      await c.withdraw(amount: '10.000', reason: 'A');
      await c.withdraw(amount: '20.000', reason: 'A');
      expect(svc.withdrawKeys[0], isNot(svc.withdrawKeys[1]));
    });

    test('changing the reason after a failure gets a NEW idempotency key', () async {
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw netDown;
      final c = CashMovementController(svc);
      await c.withdraw(amount: '10.000', reason: 'A');
      await c.withdraw(amount: '10.000', reason: 'B');
      expect(svc.withdrawKeys[0], isNot(svc.withdrawKeys[1]));
    });

    test(
      'a successful withdrawal followed by another attempt with the SAME amount+reason uses a NEW key',
      () async {
        final svc = FakeCashMovementService();
        final c = CashMovementController(svc);
        svc.onWithdraw = (a, r, k) async => movement(amount: double.parse(a));
        await c.withdraw(amount: '10.000', reason: 'A');
        final firstKey = svc.withdrawKeys.single;

        await c.withdraw(amount: '10.000', reason: 'A');
        expect(svc.withdrawKeys.last, isNot(firstKey), reason: 'a closed attempt must not be replayed for a new one');
      },
    );

    test('409 idempotency conflict is surfaced as withdrawError', () async {
      const conflict = ApiException(kind: ApiErrorKind.conflict, message: 'Idempotency key reused with a different request');
      final svc = FakeCashMovementService()..onWithdraw = (a, r, k) async => throw conflict;
      final c = CashMovementController(svc);
      final ok = await c.withdraw(amount: '10.000');
      expect(ok, isFalse);
      expect(c.withdrawError, conflict);
    });
  });
}
