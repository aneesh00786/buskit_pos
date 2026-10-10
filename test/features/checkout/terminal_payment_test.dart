// Card-terminal (Pine Labs) payments in the till: provider list parsing, the
// polling state machine, and the pay-modal flow. The service is a fake —
// nothing here talks to a server or a terminal.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/checkout/state/terminal_payment_controller.dart';
import 'package:buskit_pos/features/checkout/ui/terminal_payment_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

Map<String, dynamic> attemptJson(int id, String status, {String? instruction, String? failure}) => {
  'id': id,
  'sale_id': 10,
  'method': 'CARD',
  'provider': 'PINE_LABS',
  'amount': 112,
  'currency': 'INR',
  'status': status,
  'provider_reference': status == 'CAPTURED' ? 'RRN1' : null,
  'client_action': instruction == null ? null : {'type': 'TERMINAL', 'terminal_id': 'Counter 1', 'instruction': instruction},
  'failure_code': failure,
  'failure_message': failure == null ? null : 'The payment was declined or could not be completed',
};

PaymentAttempt attempt(int id, String status, {String? instruction, String? failure}) =>
    PaymentAttempt.fromJson(attemptJson(id, status, instruction: instruction, failure: failure))!;

final pineLabsJson = {
  'name': 'PINE_LABS',
  'methods': ['CARD'],
  'currencies': ['INR'],
  'capabilities': {'external': true, 'statusPolling': true, 'cancel': true, 'capture': false, 'refund': false, 'qr': false, 'cardTerminal': true},
  'terminal': {'configured': true, 'display_name': 'Counter 1 terminal'},
};

class FakeTerminalService implements PaymentTerminalService {
  // Phase 18B.17: GET /payment-attempts/:id without refresh (read-only).
  Future<PaymentAttempt> Function(int id)? onCurrent;
  int currents = 0;
  @override
  Future<PaymentAttempt> current(int attemptId) async {
    currents++;
    if (onCurrent == null) throw const ApiException(kind: ApiErrorKind.notFound, message: 'not stubbed');
    return onCurrent!(attemptId);
  }

  // Phase 18B.1 (abandoning an unconfirmed terminal attempt).
  Future<AbandonResult> Function(int id, String reason) onAbandon = (id, reason) async => throw UnimplementedError();
  final List<(int, String)> abandonCalls = [];
  @override
  Future<AbandonResult> abandonUnconfirmed(int attemptId, String reason) {
    abandonCalls.add((attemptId, reason));
    return onAbandon(attemptId, reason);
  }

  List<PaymentProviderInfo> providers = [PaymentProviderInfo.fromJson(pineLabsJson)!];
  Future<PaymentAttempt> Function(String key) onStart = (_) async => attempt(1, 'PENDING', instruction: 'Complete the card payment on the Pine Labs terminal');
  Future<PaymentAttempt> Function(int id) onRefresh = (id) async => attempt(id, 'PENDING');
  Future<PaymentAttempt> Function(int id) onCancel = (id) async => attempt(id, 'CANCELLED');
  final List<String> startKeys = [];
  final List<Map<String, Object>> startCalls = [];
  int refreshes = 0;
  int cancels = 0;

  @override
  Future<List<PaymentProviderInfo>> listProviders() async => providers;

  @override
  Future<PaymentAttempt> start({required int saleId, required String provider, required int amountMilli, required String idempotencyKey, String method = 'CARD'}) {
    startKeys.add(idempotencyKey);
    startCalls.add({'saleId': saleId, 'provider': provider, 'amountMilli': amountMilli, 'method': method});
    return onStart(idempotencyKey);
  }

  @override
  Future<PaymentAttempt> refresh(int attemptId) {
    refreshes++;
    return onRefresh(attemptId);
  }

  @override
  Future<PaymentAttempt> cancel(int attemptId) {
    cancels++;
    return onCancel(attemptId);
  }
}

TerminalPaymentController controller(FakeTerminalService s, {Duration maxWait = const Duration(seconds: 2)}) =>
    TerminalPaymentController(s, saleId: 10, provider: 'PINE_LABS', amountMilli: 112000, pollInterval: const Duration(milliseconds: 5), maxWait: maxWait);

Future<void> settle([int ms = 60]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  group('provider list', () {
    test('Pine Labs with a configured terminal is a usable card terminal; without one it is not; nothing else is read', () {
      final p = PaymentProviderInfo.fromJson(pineLabsJson)!;
      expect(p.label, 'Pine Labs');
      expect(p.isUsableCardTerminal, isTrue);
      expect(p.terminalName, 'Counter 1 terminal');
      expect(p.statusPolling && p.cancel, isTrue);
      final unconfigured = PaymentProviderInfo.fromJson({...pineLabsJson, 'terminal': {'configured': false, 'display_name': null}})!;
      expect(unconfigured.isUsableCardTerminal, isFalse);
      final none = PaymentProviderInfo.fromJson({'name': 'NONE', 'methods': ['CASH', 'CARD'], 'capabilities': {'external': false}})!;
      expect(none.isUsableCardTerminal, isFalse);
    });

    test('a completion line carries the captured attempt id, and it is part of the idempotency fingerprint', () {
      const line = PaymentLine(method: TenderMethod.card, amountMilli: 112000, paymentAttemptId: 7);
      expect(line.toJson(), {'method': 'card', 'amount': 112.0, 'payment_attempt_id': 7});
      const manual = PaymentLine(method: TenderMethod.card, amountMilli: 112000);
      expect(manual.toJson().containsKey('payment_attempt_id'), isFalse);
      expect(line.canonical == manual.canonical, isFalse);
    });
  });

  group('terminal payment controller', () {
    test('pending -> polls the server -> captured = approved (server decides)', () async {
      final s = FakeTerminalService();
      var n = 0;
      s.onRefresh = (id) async => attempt(id, ++n >= 3 ? 'CAPTURED' : 'PENDING');
      final c = controller(s);
      final phases = <TerminalPhase>[];
      c.addListener(() => phases.add(c.phase));
      await c.start();
      expect(c.phase, TerminalPhase.waitingForCard);
      expect(c.attempt!.instruction, 'Complete the card payment on the Pine Labs terminal');
      await settle();
      expect(c.phase, TerminalPhase.approved);
      expect(c.attempt!.status, AttemptStatus.captured);
      expect(phases, containsAllInOrder([TerminalPhase.connecting, TerminalPhase.waitingForCard, TerminalPhase.processing, TerminalPhase.approved]));
      expect(s.startCalls.single, {'saleId': 10, 'provider': 'PINE_LABS', 'amountMilli': 112000, 'method': 'CARD'});
      c.dispose();
    });

    test('declined (server says FAILED) is final and not approved', () async {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.unknown,
        statusCode: 402,
        message: 'The payment was declined or could not be completed',
        errorCode: 'POS_PAYMENT_FAILED',
        data: {'payment_attempt': attemptJson(2, 'FAILED', failure: 'PINE_LABS_1')},
      );
      final c = controller(s);
      await c.start();
      expect(c.phase, TerminalPhase.declined);
      expect(c.isFinal, isTrue);
      expect(c.canCancel, isFalse);
      c.dispose();
    });

    test('still pending when the wait ends -> payment status unknown (never treated as failed); Check again resumes', () async {
      final s = FakeTerminalService();
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(c.phase, TerminalPhase.unknown);
      expect(c.canCheckAgain, isTrue);
      expect(c.canCancel, isTrue, reason: 'the open payment can still be cancelled through the provider');
      s.onRefresh = (id) async => attempt(id, 'CAPTURED');
      await c.checkAgain();
      expect(c.phase, TerminalPhase.approved);
      c.dispose();
    });

    test('no answer to the start request -> unknown; Check again re-sends the SAME idempotency key (one terminal transaction)', () async {
      final s = FakeTerminalService();
      var first = true;
      s.onStart = (key) async {
        if (first) {
          first = false;
          throw const ApiException(kind: ApiErrorKind.timeout, message: 'timeout');
        }
        return attempt(3, 'PENDING');
      };
      final c = controller(s);
      await c.start();
      expect(c.phase, TerminalPhase.unknown);
      await c.checkAgain();
      expect(c.phase, TerminalPhase.waitingForCard);
      expect(s.startKeys.length, 2);
      expect(s.startKeys[0], s.startKeys[1]);
      c.dispose();
    });

    test('server timeout with an open attempt keeps watching it', () async {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.timeout,
        statusCode: 504,
        message: 'x',
        errorCode: 'POS_PAYMENT_TIMEOUT',
        data: {'payment_attempt': attemptJson(4, 'PENDING')},
      );
      s.onRefresh = (id) async => attempt(id, 'CAPTURED');
      final c = controller(s);
      await c.start();
      await settle();
      expect(c.phase, TerminalPhase.approved);
      expect(c.attempt!.id, 4);
      c.dispose();
    });

    test('no terminal for this register -> terminal unavailable', () async {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw const ApiException(kind: ApiErrorKind.conflict, statusCode: 409, message: 'x', errorCode: 'POS_PAYMENT_TERMINAL_NOT_CONFIGURED');
      final c = controller(s);
      await c.start();
      expect(c.phase, TerminalPhase.unavailable);
      expect(c.message, 'The card terminal is not available for this register.');
      c.dispose();
    });

    test('cancel: confirmed -> cancelled; not confirmed -> keeps waiting with a warning (never marked cancelled locally)', () async {
      final s = FakeTerminalService();
      final c = controller(s);
      await c.start();
      s.onCancel = (id) async => throw ApiException(
        kind: ApiErrorKind.conflict,
        statusCode: 409,
        message: 'x',
        errorCode: 'POS_PAYMENT_CANCEL_NOT_CONFIRMED',
        data: {'payment_attempt': attemptJson(id, 'PENDING')},
      );
      await c.cancel();
      expect(c.phase, isNot(TerminalPhase.cancelled));
      expect(c.message, contains('did not confirm the cancellation'));
      s.onCancel = (id) async => attempt(id, 'CANCELLED');
      await c.cancel();
      expect(c.phase, TerminalPhase.cancelled);
      c.dispose();
    });
  });

  group('pay modal', () {
    Future<PageHarness> pumpCart(WidgetTester tester, FakeTerminalService terminal) async {
      final h = PageHarness()..terminal = terminal;
      CartSale sale() => CartSaleFactory.sale(items: [lineJson(id: 1, quantity: 2, name: 'Tea')], total: 112);
      h.carts.onAdd = (_) async => sale();
      h.carts.onGet = (_) async => sale();
      await pumpProductsPage(tester, h);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Card').last);
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets('card mode offers "Pay on terminal"; approval completes the sale with the captured attempt id', (tester) async {
      final terminal = FakeTerminalService();
      terminal.onStart = (_) async => attempt(9, 'PENDING', instruction: 'Complete the card payment on the Pine Labs terminal');
      final h = await pumpCart(tester, terminal);
      expect(find.byKey(const Key('pay-on-terminal')), findsOneWidget);
      expect(find.text('Pay on terminal (Counter 1 terminal)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('pay-on-terminal')));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const Key('terminal-phase-waitingForCard')), findsOneWidget);
      expect(find.text('Waiting for card'), findsOneWidget);

      terminal.onRefresh = (id) async => attempt(id, 'CAPTURED');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('Approved'), findsOneWidget);
      await tester.tap(find.text('Complete sale'));
      await tester.pumpAndSettle();

      final call = h.carts.completeCalls.single;
      expect(call.payments.single.toJson(), {'method': 'card', 'amount': 112.0, 'payment_attempt_id': 9});
    });

    testWidgets('Phase 15G: tapping "Pay on terminal" repeatedly starts ONE terminal payment; the button is disabled while it runs', (tester) async {
      final terminal = FakeTerminalService();
      terminal.onStart = (_) async => attempt(9, 'PENDING', instruction: 'Complete the card payment on the Pine Labs terminal');
      await pumpCart(tester, terminal);
      // Two presses in the same instant (before the dialog can open — the
      // window while the recovery marker is being saved), then a normal tap.
      final onPressed = tester.widget<FilledButton>(find.byKey(const Key('pay-on-terminal'))).onPressed!;
      onPressed();
      onPressed();
      await tester.pump();
      await tester.tap(find.byKey(const Key('pay-on-terminal')), warnIfMissed: false);
      await tester.pump();
      await tester.pump();
      expect(terminal.startCalls, hasLength(1));
      expect(find.byKey(const Key('terminal-phase-waitingForCard')), findsOneWidget, reason: 'one dialog');
      expect(find.byKey(const Key('terminal-phase-waitingForCard')), findsOneWidget);
    });

    testWidgets('Phase 15G: offline, the terminal button is disabled and no terminal payment starts', (tester) async {
      final terminal = FakeTerminalService();
      final h = await pumpCart(tester, terminal);
      h.client.reachable.value = false;
      await tester.pumpAndSettle();
      final button = tester.widget<FilledButton>(find.byKey(const Key('pay-on-terminal')));
      expect(button.onPressed, isNull);
      await tester.tap(find.byKey(const Key('pay-on-terminal')), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(terminal.startCalls, isEmpty);
    });

    testWidgets('a decline shows Declined and completes nothing; manual card stays available', (tester) async {
      final terminal = FakeTerminalService();
      terminal.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.unknown,
        statusCode: 402,
        message: 'x',
        errorCode: 'POS_PAYMENT_FAILED',
        data: {'payment_attempt': attemptJson(5, 'FAILED', failure: 'PINE_LABS_1')},
      );
      final h = await pumpCart(tester, terminal);
      await tester.tap(find.byKey(const Key('pay-on-terminal')));
      await tester.pumpAndSettle();
      expect(find.text('Declined'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls, isEmpty);
      expect(find.widgetWithText(FilledButton, 'Complete Sale'), findsOneWidget, reason: 'manual card recording still works');
    });

    testWidgets('without a configured terminal (or without the service) the card screen is unchanged', (tester) async {
      final terminal = FakeTerminalService()..providers = [PaymentProviderInfo.fromJson({...pineLabsJson, 'terminal': {'configured': false}})!];
      await pumpCart(tester, terminal);
      expect(find.byKey(const Key('pay-on-terminal')), findsNothing);
      expect(terminal.startKeys, isEmpty);
    });
  });

  // ---------------------------------------------------------------------
  // Phase 18B.1 — abandoning an unconfirmed attempt (no provider reference).
  group('abandon unconfirmed attempt', () {
    Map<String, dynamic> unconfirmedJson(int id) => {...attemptJson(id, 'PENDING'), 'failure_code': 'TIMEOUT', 'unconfirmed': true};
    Map<String, dynamic> abandonedJson(int id) => {
      ...attemptJson(id, 'CANCELLED'),
      'failure_code': 'ABANDONED_UNCONFIRMED',
      'failure_message': 'Abandoned by a manager without confirmation from the provider. Reconcile the terminal.',
    };
    const serverWarning = 'Abandoning does not prove that no money was taken. Check the terminal and the Pine Labs settlement for this payment, and refund the customer if a charge appears.';

    /// Start timed out with an open, unconfirmed attempt; status checks fail.
    FakeTerminalService stuck() {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.timeout,
        statusCode: 504,
        message: 'x',
        errorCode: 'POS_PAYMENT_TIMEOUT',
        data: {'payment_attempt': unconfirmedJson(5)},
      );
      s.onRefresh = (id) async => throw const ApiException(kind: ApiErrorKind.server, statusCode: 502, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_ERROR');
      return s;
    }

    test('the model reads the server flags; an attempt with a provider reference is not unconfirmed', () {
      expect(PaymentAttempt.fromJson(unconfirmedJson(1))!.unconfirmed, isTrue);
      expect(attempt(1, 'PENDING').unconfirmed, isFalse);
      final a = PaymentAttempt.fromJson(abandonedJson(1))!;
      expect(a.isAbandoned, isTrue);
      expect(a.status.isOpen, isFalse);
      expect(attempt(1, 'CANCELLED').isAbandoned, isFalse);
    });

    test('a timed-out start never becomes failed / cancelled / approved by itself; only then is Abandon offered', () async {
      final s = stuck();
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(c.phase, TerminalPhase.unknown);
      expect(c.attempt!.status, AttemptStatus.pending);
      expect(c.canAbandon, isTrue);
      expect(c.canRetry, isFalse, reason: 'no new payment while it might still collect money');
      // A normal open attempt (with a provider reference) is never abandonable.
      final normal = controller(FakeTerminalService(), maxWait: const Duration(milliseconds: 30));
      await normal.start();
      await settle(120);
      expect(normal.canAbandon, isFalse);
      normal.dispose();
      c.dispose();
    });

    test('abandoned: cancelled phase marked as abandoned, the warning shown, a new payment allowed', () async {
      final s = stuck();
      s.onAbandon = (id, reason) async => AbandonResult(attempt: PaymentAttempt.fromJson(abandonedJson(id))!, warning: serverWarning);
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(await c.abandon('Terminal timed out twice'), isTrue);
      expect(s.abandonCalls, [(5, 'Terminal timed out twice')]);
      expect(c.phase, TerminalPhase.cancelled);
      expect(c.isAbandoned, isTrue);
      expect(c.message, contains('does not prove that no money was taken'));
      expect(c.canAbandon, isFalse);
      expect(c.canRetry, isTrue);
      c.dispose();
    });

    test('refusals keep the attempt open and explain: no permission, too early (local time), other', () async {
      final s = stuck();
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      s.onAbandon = (id, r) async => throw const ApiException(kind: ApiErrorKind.forbidden, statusCode: 403, message: 'Missing required permission: payments.abandon_unconfirmed');
      expect(await c.abandon('reason here'), isFalse);
      expect(c.message, contains('Only a manager can abandon'));
      expect(c.attempt!.status, AttemptStatus.pending);
      expect(c.canAbandon, isTrue);
      final at = DateTime.now().toUtc().add(const Duration(minutes: 4));
      s.onAbandon = (id, r) async => throw ApiException(
        kind: ApiErrorKind.conflict,
        statusCode: 409,
        message: 'x',
        errorCode: 'POS_PAYMENT_ABANDON_TOO_EARLY',
        data: {'available_at': at.toIso8601String()},
      );
      expect(await c.abandon('reason here'), isFalse);
      final local = at.toLocal();
      expect(c.message, contains('${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'));
      expect(c.message, contains('may still accept this payment'));
      s.onAbandon = (id, r) async => throw const ApiException(kind: ApiErrorKind.conflict, statusCode: 409, message: 'This payment has a terminal reference: check its status or cancel it instead', errorCode: 'POS_PAYMENT_ABANDON_NOT_ALLOWED');
      expect(await c.abandon('reason here'), isFalse);
      expect(c.message, contains('terminal reference'));
      expect(c.phase, TerminalPhase.unknown);
      c.dispose();
    });

    testWidgets('dialog: Abandon asks for a reason after explaining it is not proof; Keep waiting sends nothing', (tester) async {
      final s = stuck();
      s.onAbandon = (id, reason) async => AbandonResult(attempt: PaymentAttempt.fromJson(abandonedJson(id))!, warning: serverWarning);
      final c = TerminalPaymentController(s, saleId: 10, provider: 'PINE_LABS', amountMilli: 112000, pollInterval: const Duration(milliseconds: 5), maxWait: const Duration(milliseconds: 20));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TerminalPaymentDialog(controller: c, provider: PaymentProviderInfo.fromJson(pineLabsJson)!))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(c.phase, TerminalPhase.unknown);
      expect(find.byKey(const Key('terminal-abandon')), findsOneWidget);

      await tester.tap(find.byKey(const Key('terminal-abandon')));
      await tester.pumpAndSettle();
      expect(find.textContaining('does NOT prove that no money was taken'), findsOneWidget);
      expect(tester.widget<FilledButton>(find.byKey(const Key('abandon-confirm'))).onPressed, isNull, reason: 'reason required');
      await tester.tap(find.text('Keep waiting'));
      await tester.pumpAndSettle();
      expect(s.abandonCalls, isEmpty);

      await tester.tap(find.byKey(const Key('terminal-abandon')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('abandon-reason')), 'abc');
      await tester.pump();
      expect(tester.widget<FilledButton>(find.byKey(const Key('abandon-confirm'))).onPressed, isNull);
      await tester.enterText(find.byKey(const Key('abandon-reason')), '  Terminal timed out  ');
      await tester.pump();
      await tester.tap(find.byKey(const Key('abandon-confirm')));
      await tester.pumpAndSettle();
      expect(s.abandonCalls, [(5, 'Terminal timed out')]);
      expect(find.text('Payment abandoned'), findsOneWidget);
      expect(find.textContaining('does not prove that no money was taken'), findsOneWidget);
      expect(find.text('Cancelled'), findsNothing, reason: 'never presented as a confirmed cancellation');
      expect(find.byKey(const Key('terminal-abandon')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------------------
  // Phase 18B.3 — the wait follows the terminal's configured auto-cancel.
  group('wait follows the terminal auto-cancel window', () {
    PaymentProviderInfo withMinutes(Object? m) =>
        PaymentProviderInfo.fromJson({...pineLabsJson, 'terminal': {'configured': true, 'display_name': 'Counter 1 terminal', 'auto_cancel_minutes': m}})!;

    /// A controller whose deadline runs on [clock] (advanced by the test).
    TerminalPaymentController timed(FakeTerminalService s, PaymentProviderInfo p, DateTime Function() clock) => TerminalPaymentController(
      s,
      saleId: 10,
      provider: 'PINE_LABS',
      amountMilli: 112000,
      pollInterval: const Duration(milliseconds: 5),
      maxWait: p.terminalWaitWindow,
      clock: clock,
    );

    test('window: the server value (default 5 min), plus 30 s for the terminal\'s answer; invalid values -> server default', () {
      expect(PaymentProviderInfo.fromJson(pineLabsJson)!.autoCancelMinutes, isNull);
      expect(PaymentProviderInfo.fromJson(pineLabsJson)!.terminalWaitWindow, const Duration(minutes: 5, seconds: 30));
      expect(withMinutes(5).terminalWaitWindow, const Duration(minutes: 5, seconds: 30));
      expect(withMinutes(9).autoCancelMinutes, 9);
      expect(withMinutes(9).terminalWaitWindow, const Duration(minutes: 9, seconds: 30));
      for (final bad in [0, -1, 121, 'x', 2.5]) {
        expect(withMinutes(bad).autoCancelMinutes, isNull, reason: '$bad');
      }
    });

    test('default 5 min: still waiting (and polling) at 4 min; overdue — never failed / cancelled — after 5 min 30 s', () async {
      var now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      final c = timed(s, withMinutes(5), () => now);
      await c.start();
      now = now.add(const Duration(minutes: 4));
      await settle();
      expect(c.phase, isNot(TerminalPhase.unknown));
      expect(c.isOverdue, isFalse);
      final polled = s.refreshes;
      expect(polled, greaterThan(1), reason: 'keeps asking the server while the terminal can still take the card');
      now = now.add(const Duration(minutes: 1, seconds: 31));
      await settle();
      expect(c.phase, TerminalPhase.unknown);
      expect(c.isOverdue, isTrue);
      expect(c.attempt!.status, AttemptStatus.pending, reason: 'a local timeout changes nothing on the payment');
      expect(c.message, contains('Do not take another payment'));
      expect(c.canCheckAgain, isTrue);
      expect(c.canRetry, isFalse);
      final stopped = s.refreshes;
      await settle();
      expect(s.refreshes, stopped, reason: 'no endless polling once overdue');
      c.dispose();
    });

    test('a configured 9-minute window: not overdue at 6 or 9 minutes; overdue only after 9 min 30 s', () async {
      var now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      final c = timed(s, withMinutes(9), () => now);
      await c.start();
      for (final m in [6, 9]) {
        now = DateTime(2026, 10, 10, 12, m);
        await settle();
        expect(c.isOverdue, isFalse, reason: '$m min');
        expect(c.phase, isNot(TerminalPhase.unknown), reason: '$m min');
      }
      now = DateTime(2026, 10, 10, 12, 9, 31);
      await settle();
      expect(c.isOverdue, isTrue);
      c.dispose();
    });

    test('delayed approval inside the window -> approved (server decides), never overdue', () async {
      var now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      final c = timed(s, withMinutes(5), () => now);
      await c.start();
      now = now.add(const Duration(minutes: 4, seconds: 50));
      s.onRefresh = (id) async => attempt(id, 'CAPTURED');
      await settle();
      expect(c.phase, TerminalPhase.approved);
      expect(c.isOverdue, isFalse);
      c.dispose();
    });

    test('the terminal\'s own cancellation (reported in the grace period) -> confirmed cancelled', () async {
      var now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      final c = timed(s, withMinutes(5), () => now);
      await c.start();
      now = now.add(const Duration(minutes: 5, seconds: 10));
      s.onRefresh = (id) async => attempt(id, 'CANCELLED');
      await settle();
      expect(c.phase, TerminalPhase.cancelled);
      expect(c.isOverdue, isFalse);
      expect(c.canRetry, isTrue);
      c.dispose();
    });

    test('no answer to the start: unknown (not overdue); Check again re-sends the SAME key — one terminal transaction', () async {
      final now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      var first = true;
      s.onStart = (key) async {
        if (first) {
          first = false;
          throw const ApiException(kind: ApiErrorKind.timeout, message: 'timeout');
        }
        return attempt(3, 'PENDING');
      };
      final c = timed(s, withMinutes(5), () => now);
      await c.start();
      expect(c.phase, TerminalPhase.unknown);
      expect(c.isOverdue, isFalse);
      await c.checkAgain();
      expect(s.startKeys, hasLength(2));
      expect(s.startKeys.toSet(), hasLength(1));
      c.dispose();
    });

    test('repeated Check again after the window: one status check each, the wait is not restarted, still never failed; a late approval still wins', () async {
      var now = DateTime(2026, 10, 10, 12);
      final s = FakeTerminalService();
      final c = timed(s, withMinutes(5), () => now);
      await c.start();
      now = now.add(const Duration(minutes: 6));
      await settle();
      expect(c.isOverdue, isTrue);
      for (var i = 0; i < 3; i++) {
        final before = s.refreshes;
        await c.checkAgain();
        await settle();
        expect(s.refreshes, before + 1, reason: 'one status check per tap');
        expect(c.phase, TerminalPhase.unknown);
        expect(c.isOverdue, isTrue);
        expect(c.attempt!.status, AttemptStatus.pending);
      }
      expect(s.startKeys, hasLength(1), reason: 'never a second terminal payment');
      s.onRefresh = (id) async => attempt(id, 'CAPTURED');
      await c.checkAgain();
      expect(c.phase, TerminalPhase.approved);
      expect(c.isOverdue, isFalse);
      c.dispose();
    });

    testWidgets('the dialog waits for the provider\'s window and says when the terminal cancels; overdue has its own title', (tester) async {
      final s = FakeTerminalService();
      final p = withMinutes(7);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () => showTerminalPayment(context, service: s, saleId: 10, provider: p, amountMilli: 112000),
              child: const Text('pay'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('pay'));
      await tester.pump();
      await tester.pump();
      final dialog = tester.widget<TerminalPaymentDialog>(find.byType(TerminalPaymentDialog));
      expect(dialog.controller.maxWait, const Duration(minutes: 7, seconds: 30));
      expect(find.textContaining('automatically after 7 minutes'), findsOneWidget);
      expect(find.text('Waiting longer than expected'), findsNothing);
      await tester.pumpWidget(const SizedBox()); // the dialog disposes its controller
    });
  });

  // ---------------------------------------------------------------------
  // Phase 18B.15 — a recorded provider reference is checked / cancelled
  // through the provider, never abandoned.
  group('recorded provider reference', () {
    const recordedCode = 'POS_PAYMENT_PROVIDER_REFERENCE_UNRECORDED';
    Map<String, dynamic> unconfirmed(int id) => {...attemptJson(id, 'PENDING'), 'failure_code': 'TIMEOUT', 'unconfirmed': true, 'provider_payment_id': null};
    Map<String, dynamic> withPtrid(int id, String status, String ptrid) => {...attemptJson(id, status), 'unconfirmed': false, 'provider_payment_id': ptrid};
    ApiException recorded(int id) => ApiException(
      kind: ApiErrorKind.conflict,
      statusCode: 409,
      message: "This payment's terminal reference is recorded: attach it, then check or cancel the payment instead of abandoning it",
      errorCode: recordedCode,
      data: {'payment_attempt': unconfirmed(id)},
    );

    /// Start timed out before the till got a PTRID; status checks fail.
    FakeTerminalService stuck() {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.timeout,
        statusCode: 504,
        message: 'x',
        errorCode: 'POS_PAYMENT_TIMEOUT',
        data: {'payment_attempt': unconfirmed(7)},
      );
      s.onRefresh = (id) async => throw const ApiException(kind: ApiErrorKind.server, statusCode: 502, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_ERROR');
      return s;
    }

    Future<TerminalPaymentController> overdue(FakeTerminalService s) async {
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      return c;
    }

    test('the model reads provider_payment_id; an attempt with a PTRID is never abandonable (even if flagged unconfirmed), cancel stays', () async {
      expect(PaymentAttempt.fromJson(withPtrid(1, 'PENDING', '995001'))!.hasProviderReference, isTrue);
      expect(PaymentAttempt.fromJson(unconfirmed(1))!.hasProviderReference, isFalse);
      final s = FakeTerminalService();
      final hostile = PaymentAttempt.fromJson({...withPtrid(5, 'PENDING', '995001'), 'unconfirmed': true})!;
      s.onStart = (_) async => hostile;
      s.onRefresh = (_) async => hostile; // every status check keeps the same view
      final c = await overdue(s);
      expect(c.attempt!.unconfirmed, isTrue);
      expect(c.attempt!.hasProviderReference, isTrue);
      expect(c.phase, TerminalPhase.unknown);
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isTrue, reason: 'checked / cancelled through the provider');
      expect(c.isReferenceRecordedUnattached, isFalse);
      c.dispose();
    });

    test('genuinely unrecorded: Abandon is still offered; a refusal for another reason (too early) keeps it offered', () async {
      final s = stuck();
      s.onAbandon = (id, r) async => throw ApiException(
        kind: ApiErrorKind.conflict,
        statusCode: 409,
        message: 'x',
        errorCode: 'POS_PAYMENT_ABANDON_TOO_EARLY',
        data: {'available_at': DateTime.now().toUtc().add(const Duration(minutes: 3)).toIso8601String()},
      );
      final c = await overdue(s);
      expect(c.canAbandon, isTrue);
      expect(await c.abandon('terminal timed out'), isFalse);
      expect(c.canAbandon, isTrue, reason: 'still the authorized abandonment flow');
      expect(c.isReferenceRecordedUnattached, isFalse);
      c.dispose();
    });

    test('abandon refused because the reference is recorded: no abandon, no cancel, still open (never cancelled / failed); after a manager attaches it, Check again resumes the provider flow', () async {
      final s = stuck();
      s.onAbandon = (id, r) async => throw recorded(id);
      final c = await overdue(s);
      expect(await c.abandon('terminal timed out'), isFalse);
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isFalse, reason: 'the server would refuse it until the reference is attached');
      expect(c.canRetry, isFalse, reason: 'no other payment while it may still be paid');
      expect(c.canCheckAgain, isTrue);
      expect(c.phase, TerminalPhase.unknown);
      expect(c.attempt!.status, AttemptStatus.pending);
      expect(c.message, contains('do not take another payment'));
      // A failing status check keeps the state (never misleading).
      await c.checkAgain();
      await settle(60);
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.attempt!.status, AttemptStatus.pending);
      // A manager attached the PTRID: the next check brings it.
      s.onRefresh = (id) async => PaymentAttempt.fromJson(withPtrid(id, 'PENDING', '995002'))!;
      await c.checkAgain();
      expect(c.isReferenceRecordedUnattached, isFalse);
      expect(c.attempt!.providerPaymentId, '995002');
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isTrue);
      s.onCancel = (id) async => PaymentAttempt.fromJson(withPtrid(id, 'CANCELLED', '995002'))!;
      await c.cancel();
      expect(c.phase, TerminalPhase.cancelled, reason: 'confirmed by the provider');
      expect(c.isAbandoned, isFalse);
      expect(s.startKeys, hasLength(1), reason: 'never a new payment attempt');
      expect(s.abandonCalls, hasLength(1));
      c.dispose();
    });

    test('cancel refused because the reference is recorded leads to the same state (nothing marked cancelled)', () async {
      final s = stuck();
      s.onCancel = (id) async => throw recorded(id);
      final c = await overdue(s);
      expect(c.canCancel, isTrue);
      await c.cancel();
      expect(s.cancels, 1);
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.phase, isNot(TerminalPhase.cancelled));
      expect(c.canCancel, isFalse);
      expect(c.canAbandon, isFalse);
      c.dispose();
    });

    test('API errors never pretend an outcome: a network error on abandon / cancel keeps the attempt open and the normal options', () async {
      final s = stuck();
      s.onAbandon = (id, r) async => throw const ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server.');
      s.onCancel = (id) async => throw const ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server.');
      final c = await overdue(s);
      expect(await c.abandon('terminal timed out'), isFalse);
      expect(c.attempt!.status, AttemptStatus.pending);
      expect(c.isReferenceRecordedUnattached, isFalse);
      expect(c.canAbandon, isTrue);
      await c.cancel();
      expect(c.phase, TerminalPhase.unknown);
      expect(c.message, contains('could not be confirmed'));
      expect(c.attempt!.status, AttemptStatus.pending);
      c.dispose();
    });

    testWidgets('dialog: the recorded state explains itself; no Abandon, no Cancel, Check again kept; never shown as cancelled or declined', (tester) async {
      final s = stuck();
      s.onCancel = (id) async => throw recorded(id);
      final c = TerminalPaymentController(s, saleId: 10, provider: 'PINE_LABS', amountMilli: 112000, pollInterval: const Duration(milliseconds: 5), maxWait: const Duration(milliseconds: 20));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TerminalPaymentDialog(controller: c, provider: PaymentProviderInfo.fromJson(pineLabsJson)!))));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byKey(const Key('terminal-abandon')), findsOneWidget, reason: 'genuinely unrecorded so far');
      await tester.tap(find.text('Cancel payment'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Terminal reference recorded'), findsOneWidget);
      expect(find.textContaining('recorded but not attached yet'), findsOneWidget);
      expect(find.textContaining('do not take another payment'), findsOneWidget);
      expect(find.byKey(const Key('terminal-abandon')), findsNothing);
      expect(find.text('Cancel payment'), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Cancelled'), findsNothing);
      expect(find.text('Declined'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------------------------------------------------------------
  // Phase 18B.17 — provider_reference_status from the server.
  group('provider_reference_status', () {
    Map<String, dynamic> open(int id, {Object? status = _absent, String? ptrid, bool unconfirmed = true}) => {
      ...attemptJson(id, 'PENDING'),
      'unconfirmed': unconfirmed,
      'provider_payment_id': ptrid,
      if (!identical(status, _absent)) 'provider_reference_status': status,
    };
    PaymentAttempt at(Map<String, dynamic> j) => PaymentAttempt.fromJson(j)!;

    /// Start timed out (the error carries a legacy view without the field);
    /// refreshing status checks fail (Pine Labs cannot be asked without a PTRID).
    FakeTerminalService timedOut({Map<String, dynamic>? current}) {
      final s = FakeTerminalService();
      s.onStart = (_) async => throw ApiException(kind: ApiErrorKind.timeout, statusCode: 504, message: 'x', errorCode: 'POS_PAYMENT_TIMEOUT', data: {'payment_attempt': open(9)});
      s.onRefresh = (id) async => throw const ApiException(kind: ApiErrorKind.server, statusCode: 502, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_ERROR');
      if (current != null) s.onCurrent = (id) async => at(current);
      return s;
    }

    test('parsing: the three values; missing, unknown or non-string values are "unknown" (older backends)', () {
      expect(at(open(1, status: 'ATTACHED')).referenceStatus, ProviderReferenceStatus.attached);
      expect(at(open(1, status: 'RECORDED_UNATTACHED')).referenceStatus, ProviderReferenceStatus.recordedUnattached);
      expect(at(open(1, status: 'NOT_RECORDED')).referenceStatus, ProviderReferenceStatus.notRecorded);
      expect(at(open(1)).referenceStatus, ProviderReferenceStatus.unknown, reason: 'legacy response without the field');
      for (final v in [null, 'attached', 'SOMETHING_NEW', 7, true]) {
        expect(at(open(1, status: v)).referenceStatus, ProviderReferenceStatus.unknown, reason: '$v');
      }
      expect(at(open(1, status: 'ATTACHED')).hasProviderReference, isTrue);
      expect(at(open(1, status: 'RECORDED_UNATTACHED')).hasProviderReference, isFalse);
    });

    test('RECORDED_UNATTACHED right after a timed-out start: guidance at once; Abandon and Cancel hidden before either is tried; Check again kept', () async {
      final s = timedOut(current: open(9, status: 'RECORDED_UNATTACHED'));
      final c = controller(s, maxWait: const Duration(seconds: 5));
      await c.start();
      expect(s.currents, greaterThanOrEqualTo(1), reason: 'the read-only view was fetched');
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isFalse);
      expect(c.canCheckAgain, isTrue);
      expect(c.attempt!.status, AttemptStatus.pending, reason: 'never failed / cancelled');
      expect([s.abandonCalls.length, s.cancels, s.startKeys.length], [0, 0, 1]);
      c.dispose();
    });

    test('RECORDED_UNATTACHED learned from a failed status check (start answered PENDING without a reference)', () async {
      final s = FakeTerminalService();
      s.onStart = (_) async => at(open(9));
      s.onRefresh = (id) async => throw const ApiException(kind: ApiErrorKind.server, statusCode: 502, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_ERROR');
      s.onCurrent = (id) async => at(open(id, status: 'RECORDED_UNATTACHED'));
      final c = controller(s, maxWait: const Duration(milliseconds: 40));
      await c.start();
      await settle(80);
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isFalse);
      c.dispose();
    });

    test('ATTACHED: never Abandon just because the attempt is flagged unconfirmed; cancel goes to the provider', () async {
      final s = FakeTerminalService();
      final attached = at(open(9, status: 'ATTACHED', unconfirmed: true));
      s.onStart = (_) async => attached;
      s.onRefresh = (_) async => attached;
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(c.phase, TerminalPhase.unknown);
      expect(c.canAbandon, isFalse);
      expect(c.canCancel, isTrue);
      expect(c.isReferenceRecordedUnattached, isFalse);
      s.onCancel = (id) async => PaymentAttempt.fromJson({...attemptJson(id, 'CANCELLED'), 'provider_reference_status': 'ATTACHED'})!;
      await c.cancel();
      expect(c.phase, TerminalPhase.cancelled);
      c.dispose();
    });

    test('NOT_RECORDED: the authorized abandonment flow is unchanged (server decides permission and timing)', () async {
      final s = timedOut(current: open(9, status: 'NOT_RECORDED'));
      s.onAbandon = (id, r) async => AbandonResult(attempt: PaymentAttempt.fromJson({...attemptJson(id, 'CANCELLED'), 'failure_code': 'ABANDONED_UNCONFIRMED'})!, warning: abandonWarning);
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(c.attempt!.referenceStatus, ProviderReferenceStatus.notRecorded);
      expect(c.canAbandon, isTrue);
      expect(await c.abandon('terminal timed out'), isTrue);
      expect(c.isAbandoned, isTrue);
      c.dispose();
    });

    test('legacy backend (no field, no current view): unchanged — Abandon offered until the server refuses it as recorded', () async {
      final s = timedOut(); // current() not available -> ignored
      s.onAbandon = (id, r) async => throw ApiException(kind: ApiErrorKind.conflict, statusCode: 409, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_REFERENCE_UNRECORDED', data: {'payment_attempt': open(id)});
      final c = controller(s, maxWait: const Duration(milliseconds: 30));
      await c.start();
      await settle(120);
      expect(c.attempt!.referenceStatus, ProviderReferenceStatus.unknown);
      expect(c.canAbandon, isTrue);
      expect(await c.abandon('x'), isFalse);
      expect(c.isReferenceRecordedUnattached, isTrue);
      expect(c.canAbandon, isFalse);
      c.dispose();
    });

    test('RECORDED_UNATTACHED -> ATTACHED after a manager attaches it: Check again refreshes from the server and the provider flow resumes', () async {
      final s = timedOut(current: open(9, status: 'RECORDED_UNATTACHED'));
      final c = controller(s, maxWait: const Duration(seconds: 5));
      await c.start();
      expect(c.isReferenceRecordedUnattached, isTrue);
      s.onRefresh = (id) async => at(open(id, status: 'ATTACHED', ptrid: '995010', unconfirmed: false));
      await c.checkAgain();
      expect(c.attempt!.referenceStatus, ProviderReferenceStatus.attached);
      expect(c.attempt!.providerPaymentId, '995010');
      expect(c.isReferenceRecordedUnattached, isFalse);
      expect(c.canCancel, isTrue);
      expect(c.canAbandon, isFalse);
      s.onCancel = (id) async => at({...open(id, status: 'ATTACHED', ptrid: '995010', unconfirmed: false), 'status': 'CANCELLED'});
      await c.cancel();
      expect(c.phase, TerminalPhase.cancelled);
      expect([s.startKeys.length, s.abandonCalls.length], [1, 0], reason: 'no new attempt, never abandoned');
      c.dispose();
    });

    test('a failing read of the current view changes nothing and claims nothing', () async {
      final s = timedOut();
      s.onCurrent = (id) async => throw const ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server.');
      final c = controller(s, maxWait: const Duration(seconds: 5));
      await c.start();
      expect(c.attempt!.status, AttemptStatus.pending);
      expect(c.isReferenceRecordedUnattached, isFalse);
      expect(c.isAbandoned, isFalse);
      c.dispose();
    });

    testWidgets('dialog: RECORDED_UNATTACHED shows the recorded guidance immediately — no Abandon, no Cancel, Check again present', (tester) async {
      final s = timedOut(current: open(9, status: 'RECORDED_UNATTACHED'));
      final c = TerminalPaymentController(s, saleId: 10, provider: 'PINE_LABS', amountMilli: 112000, pollInterval: const Duration(seconds: 30), maxWait: const Duration(minutes: 5));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: TerminalPaymentDialog(controller: c, provider: PaymentProviderInfo.fromJson(pineLabsJson)!))));
      await tester.pump();
      await tester.pump();
      expect(find.text('Terminal reference recorded'), findsOneWidget);
      expect(find.textContaining('recorded but not attached yet'), findsOneWidget);
      expect(find.byKey(const Key('terminal-abandon')), findsNothing);
      expect(find.text('Cancel payment'), findsNothing);
      expect(find.text('Check again'), findsOneWidget);
      expect([s.abandonCalls.length, s.cancels], [0, 0]);
      await tester.pumpWidget(const SizedBox());
    });
  });
}

const Object _absent = Object();
