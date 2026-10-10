// Phase 6 — payment & sale recovery after an app restart, on the device:
// the recovery screen (what it offers per state), the real CartController
// (restore / complete with the captured attempt), real JSON storage for the
// local reminders. Only the server is faked.
import 'dart:async';
import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
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

  // ---------------------------------------------------------------------
  // Phase 18B.18 — provider_reference_status in payment recovery.
  group('provider reference status', () {
    /// An OPEN attempt WITHOUT a provider reference (the listing never
    /// carries provider_reference_status; [status] simulates the server's
    /// current view merged in by the service).
    Map<String, dynamic> openAttempt({int id = 41, Object? status, String? ptrid, bool cancellable = true}) => {
      ...attemptJson(id: id, status: 'PENDING', cancellable: cancellable, reference: null),
      'provider_payment_id': ptrid,
      'provider_reference_status': ?status,
    };
    PaymentRecoveryResult pendingWith(Map<String, dynamic> attempt) => FakeRecoveryService.result([
      recoverableJson(state: 'PAYMENT_PENDING', canComplete: false, nextAction: 'CHECK_PAYMENT', attempts: [attempt]),
    ]);

    test('lookup: only OPEN attempts with no reference and an unknown status are read; failures keep the listing', () async {
      final listed = pendingWith(openAttempt(id: 41));
      final withRef = FakeRecoveryService.result([recoverableJson(state: 'PAYMENT_PENDING', canComplete: false, attempts: [openAttempt(id: 42, ptrid: '995001')])]);
      final ended = FakeRecoveryService.result([recoverableJson(state: 'PAYMENT_FAILED', canComplete: false, attempts: [{...openAttempt(id: 43), 'status': 'FAILED'}])]);
      final looked = <int>[];
      Future<PaymentAttempt> lookup(int id) async {
        looked.add(id);
        return PaymentAttempt.fromJson({...openAttempt(id: id), 'provider_reference_status': 'RECORDED_UNATTACHED'})!;
      }

      final r = await withReferenceStatus(listed, lookup);
      expect(r.recoverable.single.attempts.single.attempt.referenceStatus, ProviderReferenceStatus.recordedUnattached);
      expect(r.recoverable.single.attempts.single.referenceRecordedUnattached, isTrue);
      await withReferenceStatus(withRef, lookup);
      await withReferenceStatus(ended, lookup);
      expect(looked, [41], reason: 'never for an attempt with a reference or one that has ended');
      final failed = await withReferenceStatus(listed, (id) async => throw const ApiException(kind: ApiErrorKind.network, message: 'x'));
      expect(failed.recoverable.single.attempts.single.attempt.referenceStatus, ProviderReferenceStatus.unknown);
      final other = await withReferenceStatus(listed, (id) async => PaymentAttempt.fromJson({...openAttempt(id: 99), 'provider_reference_status': 'RECORDED_UNATTACHED'})!);
      expect(other.recoverable.single.attempts.single.attempt.referenceStatus, ProviderReferenceStatus.unknown, reason: 'another attempt never replaces this one');
    });

    test('the API service reads GET /payment-attempts/:id WITHOUT refresh (read-only), never posts', () async {
      final requests = <http.Request>[];
      final client = PosApiClient(
        baseUrl: 'http://host:3000',
        tokenProvider: () => 't',
        onUnauthorized: (_) {},
        httpClient: MockClient((req) async {
          requests.add(req);
          http.Response ok(Object data) => http.Response(jsonEncode({'status_code': 200, 'status': true, 'message': 'ok', 'data': data}), 200, headers: {'content-type': 'application/json'});
          if (req.url.path == '/api/v1/pos/payment-recovery') {
            return ok({'recoverable': [recoverableJson(state: 'PAYMENT_PENDING', canComplete: false, nextAction: 'CHECK_PAYMENT', attempts: [openAttempt(id: 41)])], 'resolved': []});
          }
          if (req.url.path == '/api/v1/pos/payment-attempts/41') {
            return ok({...openAttempt(id: 41), 'provider_reference_status': 'RECORDED_UNATTACHED'});
          }
          return http.Response('{}', 404);
        }),
      );
      final r = await ApiPaymentRecoveryService(client).fetch(refresh: true);
      expect(r.recoverable.single.attempts.single.attempt.referenceStatus, ProviderReferenceStatus.recordedUnattached);
      final attemptReq = requests.singleWhere((x) => x.url.path.endsWith('/payment-attempts/41'));
      expect(attemptReq.method, 'GET');
      expect(attemptReq.url.queryParameters.containsKey('refresh'), isFalse, reason: 'no provider call');
      expect(requests.where((x) => x.method != 'GET'), isEmpty);
    });

    testWidgets('RECORDED_UNATTACHED: the manager-attach guidance, no Cancel, Check Payment kept — still "Payment pending" (never failed / cancelled / paid)', (tester) async {
      service.current = pendingWith(openAttempt(status: 'RECORDED_UNATTACHED'));
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Payment pending'), findsOneWidget);
      expect(find.byKey(const Key('recovery-reference-recorded-41')), findsOneWidget);
      expect(find.textContaining('A manager must attach the recorded reference in the admin portal'), findsOneWidget);
      expect(find.textContaining('do not take another payment'), findsOneWidget);
      expect(find.text('Provider reference recorded — waiting for a manager to attach it'), findsOneWidget);
      expect(find.byKey(const Key('recovery-cancel')), findsNothing, reason: 'the server would refuse it until attached');
      expect(find.byKey(const Key('recovery-check')), findsOneWidget);
      expect(find.byKey(const Key('recovery-resume')), findsNothing);
      for (final t in ['Payment failed', 'Payment cancelled', 'Payment captured']) {
        expect(find.text(t), findsNothing, reason: t);
      }
      expect(service.cancelCalls, isEmpty);
    });

    testWidgets('ATTACHED: existing recovery behaviour — Cancel and Check Payment through the server; no guidance banner', (tester) async {
      service.current = pendingWith(openAttempt(status: 'ATTACHED', ptrid: '995001'));
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('Provider reference attached'), findsOneWidget);
      expect(find.byKey(const Key('recovery-reference-recorded-41')), findsNothing);
      expect(find.byKey(const Key('recovery-cancel')), findsOneWidget);
      expect(find.byKey(const Key('recovery-check')), findsOneWidget);
    });

    testWidgets('NOT_RECORDED: shown as such; existing actions unchanged', (tester) async {
      service.current = pendingWith(openAttempt(status: 'NOT_RECORDED'));
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.text('No provider reference'), findsOneWidget);
      expect(find.byKey(const Key('recovery-reference-recorded-41')), findsNothing);
      expect(find.byKey(const Key('recovery-cancel')), findsOneWidget);
      expect(find.text('Payment pending'), findsOneWidget);
    });

    testWidgets('legacy / unknown status: no reference line, no banner, existing actions', (tester) async {
      for (final status in [null, 'SOMETHING_NEW']) {
        service.current = pendingWith(openAttempt(status: status));
        await pumpHost(tester);
        await openRecovery(tester);
        expect(find.byKey(const Key('recovery-reference-41')), findsNothing, reason: '$status');
        expect(find.byKey(const Key('recovery-reference-recorded-41')), findsNothing);
        expect(find.byKey(const Key('recovery-cancel')), findsOneWidget);
        await tester.tap(find.text('Later'));
        await tester.pumpAndSettle();
      }
    });

    testWidgets('after a manager attaches the reference: Check Payment re-reads from the server -> ATTACHED, Cancel back, banner gone', (tester) async {
      service.current = pendingWith(openAttempt(status: 'RECORDED_UNATTACHED'));
      await pumpHost(tester);
      await openRecovery(tester);
      expect(find.byKey(const Key('recovery-reference-recorded-41')), findsOneWidget);
      service.queue.add(pendingWith(openAttempt(status: 'ATTACHED', ptrid: '995010')));
      await tester.tap(find.byKey(const Key('recovery-check')));
      await tester.pumpAndSettle();
      expect(service.fetchCalls.last['refresh'], isTrue);
      expect(find.byKey(const Key('recovery-reference-recorded-41')), findsNothing);
      expect(find.text('Provider reference attached'), findsOneWidget);
      expect(find.byKey(const Key('recovery-cancel')), findsOneWidget);
      expect(find.text('Payment pending'), findsOneWidget);
      await tester.tap(find.byKey(const Key('recovery-cancel')));
      await tester.pumpAndSettle();
      expect(service.cancelCalls, [41], reason: 'the existing cancel API, once attached');
    });
  });
}
