// Phase 6 — payment & sale recovery after an app restart, on the device:
// the recovery screen (what it offers per state), the real CartController
// (restore / complete with the captured attempt), real JSON storage for the
// local reminders. Only the server is faked.
import 'dart:async';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/checkout/ui/payment_recovery_view.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

Map<String, dynamic> attemptJson({
  int id = 31,
  String status = 'CAPTURED',
  String method = 'CARD',
  String provider = 'PINE_LABS',
  double amount = 238,
  bool cancellable = false,
  String? reference = 'RRN700001',
}) => {
  'id': id,
  'sale_id': 7,
  'method': method,
  'provider': provider,
  'amount': amount,
  'currency': 'INR',
  'status': status,
  'provider_payment_id': '700001',
  'provider_reference': reference,
  'client_action': null,
  'cancellable': cancellable,
  'refresh_error': null,
};

Map<String, dynamic> recoverableJson({
  int saleId = 7,
  String state = 'PAYMENT_CAPTURED',
  List<Map<String, dynamic>>? attempts,
  bool canComplete = true,
  String nextAction = 'COMPLETE_SALE',
  String? blocked,
  bool currentShift = true,
  String productName = 'Tea',
}) {
  final atts = attempts ?? [attemptJson()];
  final captured = atts.where((a) => a['status'] == 'CAPTURED').toList();
  return {
    'sale_id': saleId,
    'sale_number': null,
    'created_at': '2026-10-06T09:00:00.000Z',
    'shift_id': 79,
    'current_shift': currentShift,
    'recovery_state': state,
    'can_complete': canComplete,
    'blocked_reason': blocked,
    'next_action': nextAction,
    'completion_payments': canComplete
        ? [
            for (final a in captured)
              {
                'method': a['method'] == 'QR' ? 'other' : 'card',
                'amount': a['amount'],
                'payment_attempt_id': a['id'],
              },
          ]
        : [],
    'sale': saleJson(
      id: saleId,
      version: 4,
      items: [
        lineJson(
          id: saleId * 10,
          quantity: 2,
          name: productName,
          unitPrice: 119,
          tax: 0,
          lineTotal: 238,
        ),
      ],
      subtotal: 238,
      total: 238,
    ),
    'payment_attempts': atts,
  };
}

class FakeRecoveryService implements PaymentRecoveryService {
  final List<Map<String, Object?>> fetchCalls = [];
  final List<int> cancelCalls = [];
  final List<PaymentRecoveryResult> queue = [];
  PaymentRecoveryResult current = const PaymentRecoveryResult();
  Object? fetchError;

  static PaymentRecoveryResult result(
    List<Map<String, dynamic>> recoverable, [
    List<Map<String, dynamic>> resolved = const [],
  ]) => PaymentRecoveryResult(
    recoverable: recoverable
        .map(RecoverableSale.fromJson)
        .whereType<RecoverableSale>()
        .toList(),
    resolved: resolved
        .map(ResolvedSale.fromJson)
        .whereType<ResolvedSale>()
        .toList(),
  );

  @override
  Future<PaymentRecoveryResult> fetch({
    bool refresh = false,
    List<int> saleIds = const [],
  }) async {
    fetchCalls.add({'refresh': refresh, 'ids': saleIds});
    final e = fetchError;
    if (e != null) throw e;
    if (queue.isNotEmpty) current = queue.removeAt(0);
    return current;
  }

  @override
  Future<void> cancelAttempt(int attemptId) async => cancelCalls.add(attemptId);
}

late FakeRecoveryService service;
late FakeCartService server;
late CartController cart;

Future<void> pumpHost(
  WidgetTester tester, {
  OfflineStorageService? storage,
}) async {
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
                service: service,
                cart: cart,
                storage: storage,
              ),
              child: const Text('start'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> openRecovery(WidgetTester tester) async {
  await tester.tap(find.text('start'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    service = FakeRecoveryService();
    server = FakeCartService();
    cart = CartController(server);
  });

  test('model: the server decides; completion payments are exactly the captured attempts', () {
    final r = RecoverableSale.fromJson(recoverableJson())!;
    expect(r.state, RecoveryState.captured);
    expect(r.canComplete, isTrue);
    expect(r.completionPayments.single.paymentAttemptId, 31);
    expect(r.completionPayments.single.method, TenderMethod.card);
    expect(r.completionPayments.single.amountMilli, 238000);
    expect(r.sale.id, 7);
    expect(r.reference, 'Draft #7');
  });

  testWidgets(
    '25. startup with nothing to recover: no screen, nothing changes',
    (tester) async {
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment Recovery'), findsNothing);
      expect(service.fetchCalls.single['refresh'], false);
      expect(cart.sale, isNull);
    },
  );

  testWidgets(
    '26/31/35/36. CAPTURED: shown (items, total, provider, status); Resume Sale completes ONCE with the captured attempt — never a new payment — even on double-tap',
    (tester) async {
      service.current = FakeRecoveryService.result([recoverableJson()]);
      final gate = Completer<void>();
      server.onComplete = (c) async {
        await gate.future;
        return CompletedSale.fromJson(
          completedJson(id: c.saleId, payments: c.payments),
        )!;
      };
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment Recovery'), findsOneWidget);
      expect(
        find.text('An unfinished payment was found on this register.'),
        findsOneWidget,
      );
      expect(find.text('Payment captured'), findsOneWidget);
      expect(find.text('2 × Tea'), findsOneWidget);
      expect(find.textContaining('PINE_LABS'), findsOneWidget);
      expect(find.textContaining('RRN700001'), findsOneWidget);
      expect(find.textContaining('Captured'), findsOneWidget);

      await tester.tap(find.byKey(const Key('recovery-resume')));
      await tester.pump();
      await tester.tap(
        find.byKey(const Key('recovery-resume')),
        warnIfMissed: false,
      );
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        server.completeCalls.length,
        1,
        reason: 'double-tap -> one completion',
      );
      final paid = server.completeCalls.single.payments.single;
      expect(paid.paymentAttemptId, 31);
      expect(paid.amountMilli, 238000);
      expect(server.addCalls, isEmpty);
      expect(server.createCalls, 0, reason: 'no new sale');
      expect(find.byKey(const Key('recovery-notice')), findsOneWidget);
      expect(
        find.textContaining('No further payment was needed'),
        findsOneWidget,
      );
      expect(cart.sale, isNull);
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
    },
  );

  testWidgets(
    '27. PENDING: Check Payment asks the server to refresh the SAME attempt (still pending: no completion); Cancel Payment cancels it -> Start Payment Again',
    (tester) async {
      service.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_PENDING',
          canComplete: false,
          nextAction: 'CHECK_PAYMENT',
          attempts: [attemptJson(status: 'PENDING', cancellable: true)],
        ),
      ]);
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment pending'), findsOneWidget);
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      await tester.tap(find.byKey(const Key('recovery-check')));
      await tester.pumpAndSettle();
      expect(service.fetchCalls.last, {
        'refresh': true,
        'ids': [7],
      });
      expect(find.text('Payment pending'), findsOneWidget);
      expect(server.completeCalls, isEmpty);

      service.queue.add(
        FakeRecoveryService.result([
          recoverableJson(
            state: 'PAYMENT_CANCELLED',
            canComplete: false,
            nextAction: 'RETRY_PAYMENT',
            attempts: [attemptJson(status: 'CANCELLED')],
          ),
        ]),
      );
      await tester.tap(find.byKey(const Key('recovery-cancel')));
      await tester.pumpAndSettle();
      expect(service.cancelCalls, [31]);
      expect(find.text('Payment cancelled'), findsOneWidget);
      expect(find.text('Start Payment Again'), findsOneWidget);
    },
  );

  testWidgets(
    '28/32. FAILED: Retry Payment restores the draft to the cart (no payment, no completion); the cashier pays normally (a new attempt)',
    (tester) async {
      service.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_FAILED',
          canComplete: false,
          nextAction: 'RETRY_PAYMENT',
          attempts: [attemptJson(status: 'FAILED')],
        ),
      ]);
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment failed'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recovery-retry')));
      await tester.pumpAndSettle();
      expect(
        find.text('Payment Recovery'),
        findsNothing,
        reason: 'back to the POS',
      );
      expect(cart.sale!.id, 7);
      expect(cart.sale!.items.single.quantity, 2);
      expect(server.completeCalls, isEmpty);
    },
  );

  testWidgets('29. CANCELLED: Start Payment Again restores the draft', (
    tester,
  ) async {
    service.current = FakeRecoveryService.result([
      recoverableJson(
        state: 'PAYMENT_CANCELLED',
        canComplete: false,
        nextAction: 'RETRY_PAYMENT',
        attempts: [attemptJson(status: 'CANCELLED')],
      ),
    ]);
    await pumpHost(tester);
    await openRecovery(tester);
    await tester.tap(find.text('Start Payment Again'));
    await tester.pumpAndSettle();
    expect(cart.sale!.id, 7);
  });

  testWidgets(
    '30. several unfinished sales: listed (reference, amount, provider, status); the cashier picks one; lines never mixed',
    (tester) async {
      service.current = FakeRecoveryService.result([
        recoverableJson(saleId: 7, productName: 'Tea'),
        recoverableJson(
          saleId: 9,
          productName: 'Coffee',
          state: 'PAYMENT_PENDING',
          canComplete: false,
          nextAction: 'CHECK_PAYMENT',
          attempts: [
            attemptJson(
              id: 40,
              status: 'PENDING',
              method: 'QR',
              provider: 'RAZORPAY',
            ),
          ],
        ),
      ]);
      await pumpHost(tester);
      await openRecovery(tester);
      expect(
        find.text('2 unfinished sales were found on this register.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-sale-7')), findsOneWidget);
      expect(find.byKey(const Key('recovery-sale-9')), findsOneWidget);
      expect(find.textContaining('RAZORPAY · Payment pending'), findsOneWidget);
      expect(
        find.byKey(const Key('recovery-resume')),
        findsNothing,
        reason: 'nothing selected yet',
      );
      await tester.tap(find.byKey(const Key('recovery-sale-9')));
      await tester.pumpAndSettle();
      expect(find.text('2 × Coffee'), findsOneWidget);
      expect(find.text('2 × Tea'), findsNothing);
      expect(find.byKey(const Key('recovery-check')), findsOneWidget);
      await tester.tap(find.byKey(const Key('recovery-sale-7')));
      await tester.pumpAndSettle();
      expect(find.text('2 × Tea'), findsOneWidget);
      expect(find.byKey(const Key('recovery-resume')), findsOneWidget);
    },
  );

  testWidgets(
    'blocked (captured payment no longer matching the total / earlier shift): explained, no Resume, no Retry',
    (tester) async {
      service.current = FakeRecoveryService.result([
        recoverableJson(
          canComplete: false,
          nextAction: 'CONTACT_MANAGER',
          blocked: 'CAPTURED_AMOUNT_DIFFERS',
        ),
      ]);
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.byKey(const Key('recovery-blocked')), findsOneWidget);
      expect(
        find.textContaining('A manager must handle the payment'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      expect(find.byKey(const Key('recovery-retry')), findsNothing);
    },
  );

  testWidgets(
    '33. network loss: no screen at start-up; a failed check keeps the state and says why',
    (tester) async {
      service.fetchError = const ApiException(
        kind: ApiErrorKind.network,
        message: 'down',
      );
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment Recovery'), findsNothing);

      service.fetchError = null;
      service.current = FakeRecoveryService.result([
        recoverableJson(
          state: 'PAYMENT_PENDING',
          canComplete: false,
          nextAction: 'CHECK_PAYMENT',
          attempts: [attemptJson(status: 'PENDING')],
        ),
      ]);
      await openRecovery(tester);
      service.fetchError = const ApiException(
        kind: ApiErrorKind.network,
        message: 'Cannot reach the server.',
      );
      await tester.tap(find.byKey(const Key('recovery-check')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-error')), findsOneWidget);
      expect(find.text('Payment pending'), findsOneWidget);
    },
  );

  testWidgets(
    '34. completion interrupted (outcome unknown) -> cart cleared, sale still listed; next start: the server reports it COMPLETED -> told, no new payment',
    (tester) async {
      service.current = FakeRecoveryService.result([recoverableJson()]);
      server.onComplete = (c) async =>
          throw const ApiException(kind: ApiErrorKind.network, message: 'lost');
      await pumpHost(tester);
      await openRecovery(tester);
      service.queue.add(FakeRecoveryService.result([recoverableJson()]));
      await tester.tap(find.byKey(const Key('recovery-resume')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recovery-error')), findsOneWidget);
      expect(cart.sale, isNull, reason: 'not left editable');
      expect(
        find.byKey(const Key('recovery-resume')),
        findsOneWidget,
        reason: 'still recoverable',
      );
      await tester.tap(find.byKey(const Key('recovery-later')));
      await tester.pumpAndSettle();

      // "Restart": the first completion had actually reached the server.
      service.current = FakeRecoveryService.result([], [
        {
          'sale_id': 7,
          'status': 'SALE_COMPLETED',
          'sale_number': 'POS-00000007',
          'grand_total': 238,
        },
      ]);
      await openRecovery(tester);
      expect(find.byKey(const Key('recovery-completed-7')), findsOneWidget);
      expect(
        find.textContaining(
          'POS-00000007 was completed before the app restarted',
        ),
        findsOneWidget,
      );
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      expect(server.completeCalls.length, 1);
    },
  );

  testWidgets('a cart being rung up is never replaced by a recovered sale', (
    tester,
  ) async {
    server.onAdd = (_) async => CartSaleFactory.sale(
      id: 55,
      items: [lineJson(id: 1, quantity: 1, name: 'Other')],
      total: 10,
    );
    await cart.addItem(42, 1);
    service.current = FakeRecoveryService.result([
      recoverableJson(
        state: 'PAYMENT_FAILED',
        canComplete: false,
        nextAction: 'RETRY_PAYMENT',
        attempts: [attemptJson(status: 'FAILED')],
      ),
    ]);
    await pumpHost(tester);
    await openRecovery(tester);
    await tester.tap(find.byKey(const Key('recovery-retry')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('recovery-error')), findsOneWidget);
    expect(cart.sale!.id, 55);
  });

  testWidgets(
    'reminders: the server is asked about remembered sales; completed ones are reported, closed/unknown ones cleared quietly; resuming clears its reminder',
    (tester) async {
      late Directory root;
      late OfflineStorageService storage;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pos_recovery_');
        storage = OfflineStorageService(root);
        await storage.initialize();
        for (final id in [7, 8, 12]) {
          await storage.addPaymentRecoveryMarker(id);
        }
      });
      addTearDown(() => root.delete(recursive: true));
      service.current = FakeRecoveryService.result(
        [recoverableJson()],
        [
          {
            'sale_id': 8,
            'status': 'SALE_CLOSED',
            'sale_number': null,
            'grand_total': null,
          },
        ],
      );
      await pumpHost(tester, storage: storage);
      await tester.runAsync(() async {
        await tester.tap(find.text('start'));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(service.fetchCalls.single['ids'], [7, 8, 12]);
      expect(await tester.runAsync(storage.getPaymentRecoveryMarkers), [
        7,
      ], reason: '8 closed, 12 unknown -> cleared');
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('recovery-resume')));
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(await tester.runAsync(storage.getPaymentRecoveryMarkers), isEmpty);
    },
  );

  test('storage: reminders are only sale ids; an unreadable reminders file is kept aside, never blocks', () async {
    final root = await Directory.systemTemp.createTemp('pos_recovery_store_');
    addTearDown(() => root.delete(recursive: true));
    final s = OfflineStorageService(root);
    await s.initialize();
    await s.addPaymentRecoveryMarker(5);
    await s.addPaymentRecoveryMarker(5);
    await s.addPaymentRecoveryMarker(3);
    expect(await s.getPaymentRecoveryMarkers(), [3, 5]);
    final text = File('${root.path}/payment_recovery.json').readAsStringSync();
    expect(text.contains('sale_ids'), isTrue);
    for (final secret in ['token', 'secret', 'key', 'card']) {
      expect(text.toLowerCase().contains(secret), isFalse);
    }
    File('${root.path}/payment_recovery.json').writeAsStringSync('{broken');
    expect(await s.getPaymentRecoveryMarkers(), isEmpty);
    await s.addPaymentRecoveryMarker(9);
    expect(await s.getPaymentRecoveryMarkers(), [9]);
    expect(
      root.listSync().any(
        (f) => f.path.contains('payment_recovery.json.corrupt-'),
      ),
      isTrue,
    );
    await s.removePaymentRecoveryMarker(9);
    expect(await s.getPaymentRecoveryMarkers(), isEmpty);
  });
}
