// Phase 7 — captured payment exception on the device: a captured provider
// payment whose sale cannot be completed (stock / price / product changed).
// What each viewer is offered (authorized manager / other staff / the
// original cashier), the Razorpay full refund (success / pending / failed →
// retry), the Pine Labs manual-refund flag, and the background → foreground
// recovery check that never interrupts a sale being rung up. Only the server
// is faked; it alone decides state, permission and four-eyes.
import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/checkout/ui/payment_recovery_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import 'payment_recovery_test.dart'
    show FakeRecoveryService, recoverableJson, attemptJson;

Map<String, dynamic> exceptionJson({
  String provider = 'RAZORPAY',
  String state = 'OPEN',
  String reason = 'STOCK_CONFLICT',
  bool canAct = true,
  String? block,
  String? resolvedBy,
}) {
  final refundable = provider == 'RAZORPAY';
  return {
    ...recoverableJson(
      canComplete: false,
      nextAction: 'CONTACT_MANAGER',
      blocked: reason,
      attempts: [
        attemptJson(
          provider: provider,
          method: refundable ? 'QR' : 'CARD',
          reference: refundable ? 'pay_RZP0001' : 'RRN700001',
        ),
      ],
    ),
    'exception': {
      'payment_attempt_id': 31,
      'state': state,
      'resolution': null,
      'resolved_by': resolvedBy,
      'recommended_action': refundable ? 'REFUND_PAYMENT' : 'MANUAL_REFUND',
      'viewer_can_act': canAct,
      'viewer_block_reason': block,
    },
  };
}

PaymentExceptionView viewOf(
  String state, {
  String provider = 'RAZORPAY',
  String? refundId,
}) => PaymentExceptionView.fromJson({
  'payment_attempt_id': 31,
  'state': state,
  'provider': provider,
  'amount': 238,
  'currency': 'INR',
  'resolution': provider == 'RAZORPAY' ? 'PROVIDER_REFUND' : 'MANUAL_REFUND',
  'refund': provider == 'RAZORPAY'
      ? {'status': state, 'amount': 238, 'provider_refund_id': refundId}
      : null,
  'resolved_by': 'Manager Two',
  'resolved_at': '2026-10-06T10:00:00.000Z',
})!;

class FakeExceptionService implements PaymentExceptionService {
  final List<String> calls = [];
  final List<Object> responses = [];
  Completer<void>? gate;

  Future<PaymentExceptionView> _next(String call) async {
    calls.add(call);
    final g = gate;
    if (g != null) await g.future;
    final r = responses.removeAt(0);
    if (r is ApiException) throw r;
    return r as PaymentExceptionView;
  }

  @override
  Future<PaymentExceptionView> refund(int attemptId, {String? note}) =>
      _next('refund:$attemptId');

  @override
  Future<PaymentExceptionView> flagManualRefund(
    int attemptId, {
    String? note,
  }) => _next('manual:$attemptId');

  @override
  Future<PaymentExceptionView> checkRefund(int attemptId) =>
      _next('check:$attemptId');

  @override
  Future<PaymentExceptionView> retryRefund(int attemptId) =>
      _next('retry:$attemptId');

  /// Phase 8: the (trimmed) reference and note the app sent.
  final List<({String reference, String? note})> closeouts = [];

  @override
  Future<PaymentExceptionView> completeManualRefund(
    int attemptId, {
    required String reference,
    String? note,
  }) {
    closeouts.add((reference: reference, note: note));
    return _next('closeout:$attemptId');
  }
}

late FakeRecoveryService recovery;
late FakeExceptionService exceptions;
late CartController cart;

Future<void> openWith(
  WidgetTester tester,
  List<Map<String, dynamic>> recoverable, {
  bool wireExceptions = true,
}) async {
  recovery.current = FakeRecoveryService.result(recoverable);
  tester.view.physicalSize = const Size(1200, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: FilledButton(
              onPressed: () => runPaymentRecovery(
                context,
                service: recovery,
                cart: cart,
                exceptions: wireExceptions ? exceptions : null,
              ),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
}

Finder get resolveButton => find.byKey(const Key('recovery-resolve-exception'));
Finder get submit => find.byKey(const Key('exception-submit'));
Finder get confirm => find.byKey(const Key('exception-confirm'));

void main() {
  setUp(() {
    recovery = FakeRecoveryService();
    exceptions = FakeExceptionService();
    cart = CartController(FakeCartService());
  });

  test('model: the exception context is parsed from the recovery payload', () {
    final r = RecoverableSale.fromJson(exceptionJson())!;
    expect(r.canComplete, isFalse);
    expect(r.completionPayments, isEmpty);
    expect(r.exception!.paymentAttemptId, 31);
    expect(r.exception!.state, 'OPEN');
    expect(r.exception!.recommendedAction, 'REFUND_PAYMENT');
    expect(r.exception!.viewerCanAct, isTrue);
    expect(RecoverableSale.fromJson(recoverableJson())!.exception, isNull);
  });

  testWidgets(
    '21. exception screen: captured payment that cannot complete shows the reason and NO Resume Sale',
    (tester) async {
      await openWith(tester, [exceptionJson()]);
      expect(
        find.text('Payment captured but sale could not be completed.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-blocked')), findsOneWidget);
      expect(
        find.textContaining('Stock is no longer available.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      expect(resolveButton, findsOneWidget);
    },
  );

  testWidgets(
    'Phase 6T. captured payment on a draft whose cart already synced offline (server BUSINESS_RULE): manager instruction, NO Resume Sale, no new payment, exception action offered',
    (tester) async {
      await openWith(tester, [exceptionJson(reason: 'BUSINESS_RULE')]);
      expect(find.byKey(const Key('recovery-blocked')), findsOneWidget);
      expect(
        find.textContaining('A sale rule prevents completing it. A manager must handle the payment.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      expect(find.byKey(const Key('recovery-restore')), findsNothing, reason: 'never presented as unpaid');
      expect(find.text('Start Payment Again'), findsNothing);
      expect(resolveButton, findsOneWidget);
      expect(cart.sale, isNull, reason: 'nothing restored into the cart, nothing completed');
    },
  );

  testWidgets(
    '22. action visibility: staff without the permission see "Manager approval required." and no action',
    (tester) async {
      await openWith(tester, [
        exceptionJson(canAct: false, block: 'PERMISSION'),
      ]);
      expect(find.text('Manager approval required.'), findsOneWidget);
      expect(resolveButton, findsNothing);
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
    },
  );

  testWidgets(
    '23. the original cashier is told another manager must resolve it, and gets no action',
    (tester) async {
      await openWith(tester, [
        exceptionJson(canAct: false, block: 'SELF_RESOLUTION'),
      ]);
      expect(
        find.text('Another authorized manager must resolve this payment.'),
        findsOneWidget,
      );
      expect(resolveButton, findsNothing);
    },
  );

  testWidgets(
    '23b. server-side four-eyes still wins: a refused refund is shown, never a fake success',
    (tester) async {
      exceptions.responses.add(
        const ApiException(
          kind: ApiErrorKind.forbidden,
          message: 'Another authorized manager must resolve this payment.',
          errorCode: 'POS_PAYMENT_EXCEPTION_SELF_RESOLUTION',
          statusCode: 403,
        ),
      );
      await openWith(tester, [exceptionJson()]);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('exception-error')), findsOneWidget);
      expect(find.text('Payment refunded successfully.'), findsNothing);
      expect(exceptions.calls, ['refund:31']);
    },
  );

  testWidgets(
    '24. Razorpay refund success: fixed full amount, confirmation required, ONE request even on double-tap, result details shown',
    (tester) async {
      exceptions.responses.add(viewOf('REFUNDED', refundId: 'rfnd_0001'));
      exceptions.gate = Completer<void>();
      await openWith(tester, [exceptionJson()]);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();

      expect(find.text('Resolve Payment Exception'), findsWidgets);
      expect(find.byKey(const Key('exception-refund-amount')), findsOneWidget);
      expect(find.text('pay_RZP0001'), findsOneWidget);
      // No amount field: the refund is always the full captured amount.
      expect(find.byType(TextField), findsNothing);
      // Not confirmed yet: the button does nothing.
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(confirm);
      await tester.pump();
      expect(find.text('Refund Captured Payment'), findsOneWidget);
      await tester.tap(submit);
      await tester.pump();
      await tester.tap(submit, warnIfMissed: false);
      await tester.pump();
      exceptions.gate!.complete();
      exceptions.gate = null;
      recovery.current = const PaymentRecoveryResult(); // draft cancelled
      await tester.pumpAndSettle();

      expect(exceptions.calls, ['refund:31'], reason: 'never refund twice');
      expect(find.text('Payment refunded successfully.'), findsOneWidget);
      expect(find.text('rfnd_0001'), findsOneWidget);
      expect(find.text('RAZORPAY'), findsWidgets);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-notice')), findsOneWidget);
      expect(resolveButton, findsNothing);
    },
  );

  testWidgets(
    '25. refund pending: "Refund is being processed." with Check Refund (same refund, never a new one)',
    (tester) async {
      exceptions.responses
        ..add(viewOf('REFUND_PENDING'))
        ..add(viewOf('REFUNDED', refundId: 'rfnd_0002'));
      await openWith(tester, [exceptionJson()]);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Refund is being processed.'), findsOneWidget);
      expect(find.text('Check Refund'), findsOneWidget);

      // Re-opened later from the recovery list in REFUND_PENDING state.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(exceptions.calls, ['refund:31']);
    },
  );

  testWidgets(
    '25b. an exception already REFUND_PENDING offers Check Refund only',
    (tester) async {
      exceptions.responses.add(viewOf('REFUNDED', refundId: 'rfnd_0003'));
      await openWith(tester, [exceptionJson(state: 'REFUND_PENDING')]);
      expect(find.text('Refund is being processed.'), findsOneWidget);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      expect(confirm, findsNothing);
      expect(find.text('Check Refund'), findsOneWidget);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(exceptions.calls, ['check:31']);
      expect(find.text('Payment refunded successfully.'), findsOneWidget);
    },
  );

  testWidgets(
    '26. refund failed: "Refund could not be completed." then Retry Refund (confirmed again)',
    (tester) async {
      exceptions.responses.add(viewOf('REFUND_FAILED'));
      await openWith(tester, [exceptionJson()]);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      await tester.tap(confirm);
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.text('Refund could not be completed.'), findsOneWidget);
      expect(find.text('Payment refunded successfully.'), findsNothing);
      recovery.current = FakeRecoveryService.result([
        exceptionJson(state: 'REFUND_FAILED'),
      ]);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      exceptions.responses.add(viewOf('REFUNDED', refundId: 'rfnd_0004'));
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      expect(find.text('Retry Refund'), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(confirm);
      await tester.pump();
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(exceptions.calls, ['refund:31', 'retry:31']);
      expect(find.text('Payment refunded successfully.'), findsOneWidget);
    },
  );

  testWidgets(
    '27. Pine Labs: Mark for Manual Refund with instructions + acknowledgement; never shown as refunded',
    (tester) async {
      exceptions.responses.add(
        viewOf('MANUAL_REFUND_REQUIRED', provider: 'PINE_LABS'),
      );
      await openWith(tester, [
        exceptionJson(provider: 'PINE_LABS', reason: 'AMOUNT_MISMATCH'),
      ]);
      expect(find.textContaining('price or tax changed'), findsOneWidget);
      await tester.tap(resolveButton);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('exception-manual-instructions')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('exception-refund-amount')), findsNothing);
      expect(find.text('Mark for Manual Refund'), findsOneWidget);
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.tap(confirm);
      await tester.pump();
      recovery.current = FakeRecoveryService.result([
        exceptionJson(
          provider: 'PINE_LABS',
          state: 'MANUAL_REFUND_REQUIRED',
          resolvedBy: 'Manager Two',
        ),
      ]);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(exceptions.calls, ['manual:31']);
      expect(find.byKey(const Key('exception-manual')), findsOneWidget);
      expect(find.text('Payment refunded successfully.'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Manual Pine Labs refund required'),
        findsWidgets,
      );
      expect(resolveButton, findsNothing, reason: 'already flagged');
    },
  );

  testWidgets(
    '28. no exception service wired: the exception is shown, but no action is offered',
    (tester) async {
      await openWith(tester, [exceptionJson()], wireExceptions: false);
      expect(
        find.text('Payment captured but sale could not be completed.'),
        findsOneWidget,
      );
      expect(resolveButton, findsNothing);
    },
  );

  testWidgets(
    '28b. a payment already flagged for manual refund does not pop up the recovery screen again for staff who cannot act on it (Phase 8: a manager who can close it out is shown it)',
    (tester) async {
      await openWith(tester, [
        exceptionJson(
          provider: 'PINE_LABS',
          state: 'MANUAL_REFUND_REQUIRED',
          canAct: false,
          block: 'PERMISSION',
        ),
      ]);
      expect(find.text('Payment Recovery'), findsNothing);
    },
  );

  group('POS page', () {
    testWidgets(
      '29/30. restart → exception shown; back from the background (empty cart) → checked again; never over an active cart',
      (tester) async {
        final rec = FakeRecoveryService()
          ..current = FakeRecoveryService.result([exceptionJson()]);
        final h = PageHarness()
          ..recovery = rec
          ..exceptions = exceptions;
        await pumpProductsPage(tester, h);
        // Restart: the exception is on screen with the manager action.
        expect(find.text('Payment Recovery'), findsOneWidget);
        expect(resolveButton, findsOneWidget);
        expect(rec.fetchCalls.length, 1);
        await tester.tap(find.byKey(const Key('recovery-later')));
        await tester.pumpAndSettle();

        // Background → foreground with an empty cart: checked again.
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(rec.fetchCalls.length, 2);
        expect(find.text('Payment Recovery'), findsOneWidget);
        await tester.tap(find.byKey(const Key('recovery-later')));
        await tester.pumpAndSettle();

        // A sale is being rung up: resuming never interrupts it.
        CartSale sale() => CartSaleFactory.sale(
          items: [lineJson(id: 1, quantity: 1, name: 'Tea')],
          total: 10,
        );
        h.carts.onAdd = (_) async => sale();
        await tester.tap(find.text('Add').first);
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(rec.fetchCalls.length, 2, reason: 'active cart: not checked');
        expect(find.text('Payment Recovery'), findsNothing);
        expect(h.cart.sale, isNotNull);
      },
    );
  });
}
