// Card-terminal (Pine Labs) payments in the till: provider list parsing, the
// polling state machine, and the pay-modal flow. The service is a fake —
// nothing here talks to a server or a terminal.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/checkout/state/terminal_payment_controller.dart';
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
}
