// Phase 9 — the manager's store-wide Payment Exceptions screen: the current
// store's captured-payment exceptions from every register (list, filters,
// detail with sale / payment / exception / audit, load more, refresh),
// resolution through the SAME exception dialog and server actions, viewing
// without resolving, and online only. Only the server is faked.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/payment_exceptions/data/store_exception_service.dart';
import 'package:buskit_pos/features/payment_exceptions/ui/store_exceptions_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import '../checkout/payment_exception_closeout_test.dart' show manualRefunded;
import '../checkout/payment_exception_test.dart' show FakeExceptionService;
import '../checkout/payment_recovery_test.dart' show attemptJson;

Map<String, dynamic> itemJson({
  int id = 31,
  int saleId = 7,
  String state = 'OPEN',
  String provider = 'PINE_LABS',
  String register = 'R-A',
  String cashier = 'TEST-SALES-A1',
  bool canAct = true,
  String? block,
}) => {
  'payment_attempt_id': id,
  'sale_id': saleId,
  'sale_number': null,
  'state': state,
  'provider': provider,
  'amount': 238,
  'currency': 'INR',
  'reason_code': 'STOCK_CONFLICT',
  'original_cashier': cashier,
  'register_id': register == 'R-A' ? 1 : 3,
  'register_code': register,
  'payment_created_at': '2026-10-06T09:00:00.000Z',
  'captured_at': '2026-10-06T09:01:00.000Z',
  'viewer_can_act': canAct,
  'viewer_block_reason': block,
  'refund_method': state == 'OPEN' ? null : 'MANUAL',
};

Map<String, dynamic> detailJson({
  int id = 31,
  String state = 'MANUAL_REFUND_REQUIRED',
  bool canAct = true,
  String? block,
  String register = 'R-C',
  String saleStatus = 'draft',
  String paymentStatus = 'CAPTURED',
  bool isException = true,
}) => {
  'payment_attempt_id': id,
  'sale_id': 7,
  'sale_status': saleStatus,
  'payment_status': paymentStatus,
  'is_exception': isException,
  'register_code': register,
  'exception': isException
      ? {
          ...itemJson(
            id: id,
            state: state,
            register: register,
            canAct: canAct,
            block: block,
          ),
          'recommended_action': 'MANUAL_REFUND',
          'provider_reference': 'RRN700001',
          'original_shift_id': 79,
          'device_id': 5,
          'resolved_at': '2026-10-06T10:00:00.000Z',
          'manual_refund': state == 'REFUNDED'
              ? {'reference': 'PL-SLIP-0001', 'completed_by': 'PX9-MGR'}
              : null,
        }
      : null,
  'sale': saleJson(
    id: 7,
    version: 4,
    items: [
      lineJson(
        id: 70,
        quantity: 2,
        name: 'Tea',
        unitPrice: 119,
        tax: 0,
        lineTotal: 238,
      ),
    ],
    subtotal: 238,
    total: 238,
  ),
  'payment_attempts': [
    attemptJson(id: id, status: paymentStatus, reference: 'RRN700001'),
  ],
  'events': [
    {
      'action': 'MANUAL_REFUND_FLAGGED',
      'actor_salesman_id': 'PX9-MGR2',
      'from_status': 'OPEN',
      'to_status': 'MANUAL_REFUND_REQUIRED',
      'created_at': '2026-10-06T10:00:00.000Z',
    },
    if (state == 'REFUNDED')
      {
        'action': 'MANUAL_REFUND_COMPLETED',
        'actor_salesman_id': 'PX9-MGR',
        'from_status': 'MANUAL_REFUND_REQUIRED',
        'to_status': 'REFUNDED',
        'refund_method': 'MANUAL',
        'refund_reference': 'PL-SLIP-0001',
        'created_at': '2026-10-06T11:00:00.000Z',
      },
  ],
};

class FakeStoreExceptions implements StoreExceptionService {
  final List<Map<String, Object?>> listCalls = [];
  final List<Map<String, Object?>> detailCalls = [];
  StoreExceptionPage Function(String state, int? beforeId) onList = (s, b) =>
      const StoreExceptionPage();
  Map<String, dynamic> Function(int id, bool refresh) onDetail = (id, r) =>
      detailJson(id: id);

  static StoreExceptionPage page(
    List<Map<String, dynamic>> items, {
    int? next,
  }) => StoreExceptionPage(
    items: items
        .map(StoreExceptionItem.fromJson)
        .whereType<StoreExceptionItem>()
        .toList(),
    nextBeforeId: next,
  );

  @override
  Future<StoreExceptionPage> list({
    String state = 'UNRESOLVED',
    int? beforeId,
    int limit = 25,
  }) async {
    listCalls.add({'state': state, 'before': beforeId});
    return onList(state, beforeId);
  }

  @override
  Future<StoreExceptionDetail> detail(
    int attemptId, {
    bool refresh = false,
  }) async {
    detailCalls.add({'id': attemptId, 'refresh': refresh});
    return StoreExceptionDetail.fromJson(onDetail(attemptId, refresh))!;
  }
}

late FakeStoreExceptions store;
late FakeExceptionService actions;
late PosApiClient client;

Future<void> openScreen(WidgetTester tester, {bool wireActions = true}) async {
  tester.view.physicalSize = const Size(1400, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        Provider<PosApiClient>.value(value: client),
        Provider<StoreExceptionService?>.value(value: store),
        if (wireActions)
          Provider<PaymentExceptionService?>.value(value: actions),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showStoreExceptions(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

Finder tile(int id) => find.byKey(Key('store-exception-$id'));

void main() {
  setUp(() {
    store = FakeStoreExceptions();
    actions = FakeExceptionService();
    client = defaultTestApiClient();
  });

  testWidgets(
    '29. the manager list: exceptions from several registers, unresolved first (default filter), with state, reason, cashier and register',
    (tester) async {
      store.onList = (s, b) => FakeStoreExceptions.page([
        itemJson(
          id: 32,
          saleId: 8,
          register: 'R-C',
          cashier: 'TEST-SALES-A2',
          provider: 'RAZORPAY',
        ),
        itemJson(id: 31, state: 'MANUAL_REFUND_REQUIRED'),
      ]);
      await openScreen(tester);
      expect(find.text('Payment Exceptions'), findsOneWidget);
      expect(store.listCalls.single['state'], 'UNRESOLVED');
      final chip = tester.widget<ChoiceChip>(
        find.byKey(const Key('store-exceptions-filter-UNRESOLVED')),
      );
      expect(chip.selected, isTrue);
      expect(tile(31), findsOneWidget);
      expect(tile(32), findsOneWidget);
      expect(
        find.textContaining('ACTION NEEDED: Manual refund required'),
        findsOneWidget,
      );
      expect(find.textContaining('Register R-C'), findsOneWidget);
      expect(find.textContaining('Cashier TEST-SALES-A2'), findsOneWidget);
      expect(
        find.textContaining('Stock is no longer available.'),
        findsNWidgets(2),
      );
      expect(find.textContaining('Razorpay'), findsOneWidget);
    },
  );

  testWidgets(
    '30. filters: each chip asks the server for that state (Manual Refund Required, Refunded, All)',
    (tester) async {
      store.onList = (s, b) => FakeStoreExceptions.page([
        if (s == 'MANUAL_REFUND_REQUIRED') itemJson(id: 31, state: s),
        if (s == 'REFUNDED') itemJson(id: 40, state: s),
      ]);
      await openScreen(tester);
      expect(find.byKey(const Key('store-exceptions-empty')), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('store-exceptions-filter-MANUAL_REFUND_REQUIRED')),
      );
      await tester.pumpAndSettle();
      expect(tile(31), findsOneWidget);
      await tester.tap(
        find.byKey(const Key('store-exceptions-filter-REFUNDED')),
      );
      await tester.pumpAndSettle();
      expect(tile(40), findsOneWidget);
      expect(tile(31), findsNothing);
      expect(
        find.textContaining('ACTION NEEDED'),
        findsNothing,
        reason: 'resolved items are not emphasized',
      );
      await tester.tap(find.byKey(const Key('store-exceptions-filter-ALL')));
      await tester.pumpAndSettle();
      expect(store.listCalls.map((c) => c['state']).toList(), [
        'UNRESOLVED',
        'MANUAL_REFUND_REQUIRED',
        'REFUNDED',
        'ALL',
      ]);
    },
  );

  testWidgets(
    '31. detail: SALE (items, tax, cashier, shift, register, device), PAYMENT (provider, reference, amount, state, captured), EXCEPTION (reason, state) and AUDIT',
    (tester) async {
      store.onList = (s, b) => FakeStoreExceptions.page([
        itemJson(id: 31, state: 'MANUAL_REFUND_REQUIRED', register: 'R-C'),
      ]);
      await openScreen(tester);
      await tester.tap(tile(31));
      await tester.pumpAndSettle();
      expect(store.detailCalls.single, {'id': 31, 'refresh': false});
      for (final s in ['SALE', 'PAYMENT', 'EXCEPTION', 'AUDIT']) {
        expect(find.text(s), findsOneWidget, reason: s);
      }
      expect(find.text('2 × Tea'), findsOneWidget);
      expect(find.text('Tax'), findsOneWidget);
      expect(find.text('#79'), findsOneWidget);
      expect(find.text('R-C'), findsOneWidget);
      expect(find.text('#5'), findsOneWidget);
      expect(find.text('RRN700001'), findsOneWidget);
      expect(find.text('Pine Labs'), findsOneWidget);
      expect(find.text('CAPTURED'), findsOneWidget);
      expect(find.text('Stock is no longer available.'), findsWidgets);
      expect(
        find.byKey(const Key('store-exception-event-MANUAL_REFUND_FLAGGED')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('store-exception-resolve')), findsOneWidget);
      expect(find.text('Manual Pine Labs Refund'), findsOneWidget);
    },
  );

  testWidgets(
    '32/37. cross-register resolution: register C\'s Pine Labs exception is closed out from here with the SAME dialog and server action; the list and detail are re-read and show it resolved',
    (tester) async {
      var closed = false;
      store.onList = (s, b) => FakeStoreExceptions.page([
        if (!closed)
          itemJson(id: 31, state: 'MANUAL_REFUND_REQUIRED', register: 'R-C'),
      ]);
      store.onDetail = (id, r) => detailJson(
        id: id,
        state: closed ? 'REFUNDED' : 'MANUAL_REFUND_REQUIRED',
        saleStatus: closed ? 'canceled' : 'draft',
        paymentStatus: closed ? 'REFUNDED' : 'CAPTURED',
      );
      actions.responses.add(manualRefunded());
      await openScreen(tester);
      await tester.tap(tile(31));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('store-exception-resolve')));
      await tester.pumpAndSettle();
      expect(find.text('Manual Pine Labs Refund'), findsWidgets);
      await tester.enterText(
        find.byKey(const Key('exception-refund-reference')),
        'PL-SLIP-0001',
      );
      await tester.tap(find.byKey(const Key('exception-confirm')));
      await tester.pump();
      closed = true;
      await tester.tap(find.byKey(const Key('exception-submit')));
      await tester.pumpAndSettle();
      expect(actions.calls, ['closeout:31']);
      expect(find.text('Manual refund recorded successfully.'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(
        store.listCalls.length,
        2,
        reason: 'list re-read after the action',
      );
      expect(tile(31), findsNothing, reason: 'no longer unresolved');
      expect(find.text('Refunded'), findsWidgets);
      expect(find.byKey(const Key('store-exception-resolve')), findsNothing);
      expect(
        find.byKey(const Key('store-exception-event-MANUAL_REFUND_COMPLETED')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    '33. viewing is not resolving: without the resolve permission, or as the original cashier, no action is offered',
    (tester) async {
      store.onList = (s, b) => FakeStoreExceptions.page([
        itemJson(id: 31, canAct: false, block: 'PERMISSION'),
      ]);
      store.onDetail = (id, r) => detailJson(
        id: id,
        canAct: false,
        block: id == 31 ? 'PERMISSION' : 'SELF_RESOLUTION',
      );
      await openScreen(tester);
      await tester.tap(tile(31));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-exception-resolve')), findsNothing);
      expect(find.text('Manager approval required.'), findsOneWidget);
      store.onDetail = (id, r) =>
          detailJson(id: id, canAct: false, block: 'SELF_RESOLUTION');
      await tester.tap(tile(31));
      await tester.pumpAndSettle();
      expect(
        find.text('Another authorized manager must resolve this payment.'),
        findsOneWidget,
      );
      // No action service wired: shown, never actionable.
      store.onDetail = (id, r) => detailJson(id: id);
      await openScreen(tester, wireActions: false);
      await tester.tap(tile(31));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-exception-resolve')), findsNothing);
    },
  );

  testWidgets(
    '34. offline: nothing is shown as current and nothing can be resolved; a network failure also clears the list',
    (tester) async {
      client.reachable.value = false;
      store.onList = (s, b) => FakeStoreExceptions.page([itemJson()]);
      await openScreen(tester);
      expect(find.byKey(const Key('store-exceptions-offline')), findsOneWidget);
      expect(store.listCalls, isEmpty, reason: 'not even asked');
      expect(tile(31), findsNothing);
      // Back online + refresh.
      client.reachable.value = true;
      await tester.tap(find.byKey(const Key('store-exceptions-refresh')));
      await tester.pumpAndSettle();
      expect(tile(31), findsOneWidget);
      // The connection drops while refreshing: the stale list is not kept.
      store.onList = (s, b) => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await tester.tap(find.byKey(const Key('store-exceptions-refresh')));
      await tester.pumpAndSettle();
      expect(tile(31), findsNothing);
      expect(find.byKey(const Key('store-exceptions-offline')), findsOneWidget);
    },
  );

  testWidgets(
    '35/36. load more (keyset before_id, appended, no duplicates) and refresh (re-reads the first page)',
    (tester) async {
      var round = 0;
      store.onList = (s, b) => b == null
          ? FakeStoreExceptions.page([
              itemJson(id: 50 + round),
              itemJson(id: 31),
            ], next: 31)
          : FakeStoreExceptions.page([itemJson(id: 31), itemJson(id: 20)]);
      await openScreen(tester);
      expect(find.byKey(const Key('store-exceptions-more')), findsOneWidget);
      await tester.tap(find.byKey(const Key('store-exceptions-more')));
      await tester.pumpAndSettle();
      expect(store.listCalls.last, {'state': 'UNRESOLVED', 'before': 31});
      expect(tile(20), findsOneWidget);
      expect(tile(31), findsOneWidget, reason: 'no duplicate');
      expect(find.byKey(const Key('store-exceptions-more')), findsNothing);
      round = 1;
      await tester.tap(find.byKey(const Key('store-exceptions-refresh')));
      await tester.pumpAndSettle();
      expect(store.listCalls.last, {'state': 'UNRESOLVED', 'before': null});
      expect(tile(51), findsOneWidget);
      expect(tile(20), findsNothing, reason: 'fresh first page');
    },
  );

  test('Check Payment adapter: a refreshed detail becomes the recovery answer the shared dialog understands', () {
    final captured = StoreExceptionDetail.fromJson(detailJson(state: 'OPEN'))!;
    expect(captured.toRecoveryResult().recoverable.single.exception, isNotNull);
    final pending = StoreExceptionDetail.fromJson(
      detailJson(isException: false, paymentStatus: 'PENDING'),
    )!;
    final p = pending.toRecoveryResult().recoverable.single;
    expect(p.exception, isNull);
    expect(p.attempts.single.attempt.status.name, 'pending');
    final done = StoreExceptionDetail.fromJson(
      detailJson(
        state: 'REFUNDED',
        saleStatus: 'canceled',
        paymentStatus: 'REFUNDED',
      ),
    )!;
    expect(done.toRecoveryResult().recoverable, isEmpty);
    expect(done.toRecoveryResult().resolved.single.completed, isFalse);
    expect(
      done.sale!.exception,
      isNull,
      reason: 'a refunded exception is not actionable',
    );
    final completed = StoreExceptionDetail.fromJson(
      detailJson(isException: false, saleStatus: 'completed'),
    )!;
    expect(completed.toRecoveryResult().resolved.single.completed, isTrue);
  });

  group('POS sidebar', () {
    testWidgets(
      'the Payment exceptions item is shown only when the store view is wired and not denied',
      (tester) async {
        final h = PageHarness()..storeExceptions = FakeStoreExceptions();
        await pumpProductsPage(tester, h);
        expect(find.text('Payment exceptions'), findsOneWidget);
      },
    );

    testWidgets(
      'hidden for staff whose permissions positively lack payments.view_store_exceptions',
      (tester) async {
        final h = PageHarness()..storeExceptions = FakeStoreExceptions();
        h.fakeAuth.onAuthContext = (t) async => PosAuthContext(
          staff: const StaffInfo(
            salesmanId: 'S1',
            role: StaffRole(id: 1, name: 'Cashier'),
          ),
          permissions: const ['sales.view', 'sales.create'],
        );
        await h.session.loginDevice('REG-1', 'secret');
        await h.session.loginStaff('S1', '1234');
        await pumpProductsPage(tester, h);
        expect(find.text('Payment exceptions'), findsNothing);
      },
    );

    testWidgets('not wired (earlier setups): hidden', (tester) async {
      await pumpProductsPage(tester, PageHarness());
      expect(find.text('Payment exceptions'), findsNothing);
    });
  });
}
