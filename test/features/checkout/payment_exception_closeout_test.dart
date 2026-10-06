// Phase 8 — Pine Labs manual refund close-out on the device, and the
// "capture status unknown" refusal. A manager records the manual refund slip
// reference for a captured Pine Labs payment flagged MANUAL_REFUND_REQUIRED
// ("Mark Refund Completed" — the POS never calls Pine Labs); a refund the
// server refuses because it has not seen the capture sends the manager to
// "Check Payment". Only the server is faked; it alone decides state,
// permission and four-eyes.
import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import 'payment_exception_test.dart' as p7;
import 'payment_recovery_test.dart'
    show FakeRecoveryService, recoverableJson, attemptJson;

/// A captured Pine Labs payment flagged for a manual refund (Phase 7).
Map<String, dynamic> flaggedJson({
  bool canAct = true,
  String? block,
  int saleId = 7,
}) {
  final j = p7.exceptionJson(
    provider: 'PINE_LABS',
    state: 'MANUAL_REFUND_REQUIRED',
    canAct: canAct,
    block: block,
    resolvedBy: 'Manager Two',
  );
  (j['exception'] as Map<String, dynamic>).addAll({
    'provider': 'PINE_LABS',
    'original_cashier': 'TEST-SALES-A1',
    'captured_at': '2026-10-06T09:05:00.000Z',
  });
  return j;
}

PaymentExceptionView manualRefunded({String ref = 'PL-SLIP-0001'}) =>
    PaymentExceptionView.fromJson({
      'payment_attempt_id': 31,
      'state': 'REFUNDED',
      'provider': 'PINE_LABS',
      'amount': 238,
      'currency': 'INR',
      'resolution': 'MANUAL_REFUND',
      'refund_method': 'MANUAL',
      'refund': null,
      'manual_refund': {
        'reference': ref,
        'completed_by': 'PX8-MGR2',
        'completed_at': '2026-10-06T11:30:00.000Z',
        'confirmed_by': 'MANAGER',
      },
      'resolved_by': 'Manager Two',
      'resolved_at': '2026-10-06T10:00:00.000Z',
    })!;

/// The Razorpay QR attempt of exceptionJson() in another [status].
Map<String, dynamic> rzAttempt(String status) => attemptJson(
  status: status,
  provider: 'RAZORPAY',
  method: 'QR',
  reference: 'pay_RZP0001',
);

const captureUnknown = ApiException(
  kind: ApiErrorKind.conflict,
  statusCode: 409,
  errorCode: captureStatusUnknownCode,
  message: 'The payment capture status has not been confirmed by the server. Check the payment status before requesting a refund.',
);

Finder get closeoutButton =>
    find.byKey(const Key('recovery-complete-manual-refund'));
Finder get reference => find.byKey(const Key('exception-refund-reference'));
Finder get note => find.byKey(const Key('exception-note'));
bool submitEnabled(WidgetTester t) =>
    t.widget<FilledButton>(p7.submit).onPressed != null;

Future<void> openCloseout(WidgetTester tester) async {
  await p7.openWith(tester, [flaggedJson()]);
  expect(closeoutButton, findsOneWidget);
  await tester.tap(closeoutButton);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    p7.recovery = FakeRecoveryService();
    p7.exceptions = p7.FakeExceptionService();
    p7.cart = CartController(FakeCartService());
  });

  test('reference rules match the server (trimmed, 1–64, safe characters, never a card number)', () {
    expect(validManualRefundReference('  PL-SLIP-0001 '), 'PL-SLIP-0001');
    expect(validManualRefundReference('SLIP/2026-10/#7'), 'SLIP/2026-10/#7');
    expect(validManualRefundReference('123456789012'), '123456789012');
    expect(validManualRefundReference('x' * 64), 'x' * 64);
    for (final bad in [
      '',
      '    ',
      'x' * 65,
      '<script>',
      'PL\n1',
      '4111 1111 1111 1111',
      '4111111111111111',
    ]) {
      expect(validManualRefundReference(bad), isNull, reason: bad);
    }
    final v = manualRefunded();
    expect(v.isManualRefund, isTrue);
    expect(v.manualRefundReference, 'PL-SLIP-0001');
    expect(v.providerRefundId, isNull);
  });

  testWidgets(
    '25. Manual Pine Labs Refund screen: amount, original payment reference, sale, original cashier, captured time, reason, instructions — "Mark Refund Completed", never "Refund Payment"',
    (tester) async {
      await openCloseout(tester);
      expect(find.text('Manual Pine Labs Refund'), findsWidgets);
      expect(find.text('Original payment reference'), findsOneWidget);
      expect(find.text('RRN700001'), findsWidgets);
      expect(find.text('Draft #7'), findsWidgets);
      expect(find.text('TEST-SALES-A1'), findsOneWidget);
      expect(find.text('Captured'), findsOneWidget);
      expect(find.text('Stock is no longer available.'), findsOneWidget);
      expect(
        find.text(
          'Refund this payment through the Pine Labs/manual process first.',
        ),
        findsOneWidget,
      );
      expect(reference, findsOneWidget);
      expect(note, findsOneWidget);
      expect(
        find.text(
          'I confirm that the customer payment has been manually refunded.',
        ),
        findsOneWidget,
      );
      expect(find.text('Mark Refund Completed'), findsOneWidget);
      expect(find.textContaining('Refund Payment'), findsNothing);
      expect(find.text('Refund Captured Payment'), findsNothing);
      expect(find.byKey(const Key('exception-refund-amount')), findsNothing);
      expect(submitEnabled(tester), isFalse);
    },
  );

  testWidgets(
    '26. confirmation: a valid reference alone is not enough — the button stays disabled until the box is ticked',
    (tester) async {
      await openCloseout(tester);
      await tester.enterText(reference, 'PL-SLIP-0001');
      await tester.pump();
      expect(submitEnabled(tester), isFalse);
      await tester.tap(p7.confirm);
      await tester.pump();
      expect(submitEnabled(tester), isTrue);
      await tester.tap(p7.confirm);
      await tester.pump();
      expect(submitEnabled(tester), isFalse);
    },
  );

  testWidgets(
    '27. reference validation: empty, whitespace, odd characters and card numbers keep the button disabled; a valid one is sent trimmed',
    (tester) async {
      p7.exceptions.responses.add(manualRefunded());
      await openCloseout(tester);
      await tester.tap(p7.confirm);
      await tester.pump();
      expect(submitEnabled(tester), isFalse, reason: 'empty');
      for (final bad in ['    ', '<slip>', '4111 1111 1111 1111']) {
        await tester.enterText(reference, bad);
        await tester.pump();
        expect(submitEnabled(tester), isFalse, reason: bad);
      }
      expect(find.textContaining('never a card number'), findsOneWidget);
      await tester.enterText(reference, '  PL-SLIP-0001  ');
      await tester.enterText(note, '  slip in drawer  ');
      await tester.pump();
      expect(submitEnabled(tester), isTrue);
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(p7.exceptions.calls, ['closeout:31']);
      expect(p7.exceptions.closeouts.single.reference, 'PL-SLIP-0001');
      expect(p7.exceptions.closeouts.single.note, 'slip in drawer');
    },
  );

  testWidgets(
    '28. success: "Manual refund recorded successfully." with reference, amount, Pine Labs, Manual, manager and time; then no longer actionable or recoverable',
    (tester) async {
      p7.exceptions.responses.add(manualRefunded());
      await openCloseout(tester);
      await tester.enterText(reference, 'PL-SLIP-0001');
      await tester.tap(p7.confirm);
      await tester.pump();
      p7.recovery.current = const PaymentRecoveryResult(); // draft cancelled
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(find.text('Manual refund recorded successfully.'), findsOneWidget);
      expect(find.text('PL-SLIP-0001'), findsOneWidget);
      expect(find.text('Pine Labs'), findsOneWidget);
      expect(find.text('Manual (manager-confirmed)'), findsOneWidget);
      expect(find.text('PX8-MGR2'), findsOneWidget);
      expect(find.text('Date / time'), findsOneWidget);
      expect(find.text('Payment refunded successfully.'), findsNothing);
      expect(p7.submit, findsNothing, reason: 'nothing more to do');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Manual refund recorded successfully.'), findsOneWidget);
      expect(closeoutButton, findsNothing);
      expect(find.byKey(const Key('recovery-detail-7')), findsNothing);
    },
  );

  testWidgets(
    '29. original cashier: told another manager must resolve it, no close-out action; a server SELF_RESOLUTION refusal is shown, never a success',
    (tester) async {
      await p7.openWith(tester, [
        flaggedJson(canAct: false, block: 'SELF_RESOLUTION'),
        recoverableJson(
          saleId: 8,
          state: 'PAYMENT_FAILED',
          canComplete: false,
          nextAction: 'RETRY_PAYMENT',
          attempts: [],
        ),
      ]);
      await tester.tap(find.byKey(const Key('recovery-sale-7')));
      await tester.pumpAndSettle();
      expect(
        find.text('Another authorized manager must resolve this payment.'),
        findsOneWidget,
      );
      expect(closeoutButton, findsNothing);

      await tester.tap(find.byKey(const Key('recovery-later')));
      await tester.pumpAndSettle();
      p7.exceptions.responses.add(
        const ApiException(
          kind: ApiErrorKind.forbidden,
          statusCode: 403,
          errorCode: 'POS_PAYMENT_EXCEPTION_SELF_RESOLUTION',
          message: 'Another authorized manager must resolve this payment.',
        ),
      );
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      p7.recovery.current = FakeRecoveryService.result([flaggedJson()]);
      await tester.tap(find.byKey(const Key('recovery-later')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('start'));
      await tester.pumpAndSettle();
      await tester.tap(closeoutButton);
      await tester.pumpAndSettle();
      await tester.enterText(reference, 'PL-1');
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exception-error')), findsOneWidget);
      expect(find.text('Manual refund recorded successfully.'), findsNothing);
    },
  );

  testWidgets(
    '30. duplicate tap: ONE close-out request while the first is in flight',
    (tester) async {
      p7.exceptions.responses.add(manualRefunded());
      p7.exceptions.gate = Completer<void>();
      await openCloseout(tester);
      await tester.enterText(reference, 'PL-SLIP-0001');
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pump();
      await tester.tap(p7.submit, warnIfMissed: false);
      await tester.pump();
      p7.exceptions.gate!.complete();
      p7.exceptions.gate = null;
      await tester.pumpAndSettle();
      expect(p7.exceptions.calls, ['closeout:31']);
      expect(find.text('Manual refund recorded successfully.'), findsOneWidget);
    },
  );

  testWidgets(
    '31/32. capture unknown: "Payment status needs to be checked first." with Check Payment (not a generic failure); Check Payment refreshes this sale — still pending stays, captured returns to the refund flow',
    (tester) async {
      p7.exceptions.responses.add(captureUnknown);
      await p7.openWith(tester, [p7.exceptionJson()]);
      await tester.tap(p7.resolveButton);
      await tester.pumpAndSettle();
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(
        find.text('Payment status needs to be checked first.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('exception-check-payment')), findsOneWidget);
      expect(p7.submit, findsNothing, reason: 'no immediate refund retry');
      expect(find.text('Refund could not be completed.'), findsNothing);
      expect(find.byKey(const Key('exception-error')), findsNothing);

      // Still pending on the provider.
      p7.recovery.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_PENDING',
          canComplete: false,
          nextAction: 'CHECK_PAYMENT',
          attempts: [rzAttempt('PENDING')],
        ),
      ]);
      await tester.tap(find.byKey(const Key('exception-check-payment')));
      await tester.pumpAndSettle();
      expect(p7.recovery.fetchCalls.last, {
        'refresh': true,
        'ids': [7],
      });
      expect(
        find.text('The payment is still pending. Check again shortly.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('exception-check-payment')), findsOneWidget);

      // Now captured: back to the refund flow (confirmed again).
      p7.recovery.current = FakeRecoveryService.result([p7.exceptionJson()]);
      await tester.tap(find.byKey(const Key('exception-check-payment')));
      await tester.pumpAndSettle();
      expect(find.text('Payment captured. You can continue.'), findsOneWidget);
      expect(find.text('Refund Captured Payment'), findsOneWidget);
      expect(submitEnabled(tester), isFalse);
      p7.exceptions.responses.add(p7.viewOf('REFUNDED', refundId: 'rfnd_9'));
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(p7.exceptions.calls, ['refund:31', 'refund:31']);
      expect(find.text('Payment refunded successfully.'), findsOneWidget);
    },
  );

  testWidgets(
    '32b. Check Payment outcomes: failed → nothing to refund; already refunded / sale closed → said so',
    (tester) async {
      p7.exceptions.responses.add(captureUnknown);
      await p7.openWith(tester, [p7.exceptionJson()]);
      await tester.tap(p7.resolveButton);
      await tester.pumpAndSettle();
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      p7.recovery.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_FAILED',
          canComplete: false,
          nextAction: 'RETRY_PAYMENT',
          attempts: [rzAttempt('FAILED')],
        ),
      ]);
      await tester.tap(find.byKey(const Key('exception-check-payment')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('no refund is needed or available'),
        findsOneWidget,
      );

      p7.recovery.current = FakeRecoveryService.result(const [], [
        {'sale_id': 7, 'status': 'canceled'},
      ]);
      await tester.tap(find.byKey(const Key('exception-check-payment')));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'This payment has already been refunded and the sale is closed.',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    '33. Razorpay is unchanged: "Resolve Payment Exception" → fixed full refund, no reference field, no manual close-out',
    (tester) async {
      p7.exceptions.responses.add(p7.viewOf('REFUNDED', refundId: 'rfnd_1'));
      await p7.openWith(tester, [p7.exceptionJson()]);
      expect(closeoutButton, findsNothing);
      await tester.tap(p7.resolveButton);
      await tester.pumpAndSettle();
      expect(find.text('Resolve Payment Exception'), findsWidgets);
      expect(reference, findsNothing);
      expect(find.text('Mark Refund Completed'), findsNothing);
      expect(find.byKey(const Key('exception-refund-amount')), findsOneWidget);
      await tester.tap(p7.confirm);
      await tester.pump();
      await tester.tap(p7.submit);
      await tester.pumpAndSettle();
      expect(p7.exceptions.calls, ['refund:31']);
      expect(p7.exceptions.closeouts, isEmpty);
      expect(find.text('Payment refunded successfully.'), findsOneWidget);
    },
  );
}
