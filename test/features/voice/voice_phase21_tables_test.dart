// Phase 2.1 — table-based billing. A table is an optional, store-scoped label
// on a held sale: set when holding ("Hold for table"), shown / changed /
// cleared on the Orders screen, and found by voice ("bill table 6"). None at
// the table: said plainly. One: shown for verification like "bill order N".
// Several: listed — the cashier must choose (never picked automatically).
// Billing stays the existing version-checked resume and checkout.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:buskit_pos/features/held_sales/state/held_sales_controller.dart';
import 'package:buskit_pos/features/held_sales/ui/held_sales_view.dart';
import 'package:buskit_pos/features/held_sales/ui/table_ref_dialog.dart';
import 'package:buskit_pos/features/voice/data/voice_order_service.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB;
import 'voice_phase2_orders_test.dart' show FakeOrders;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

CartSale heldAt(int id, String table, {int version = 3}) => CartSale.fromJson({
  ...saleJson(
    id: id,
    version: version,
    status: 'held',
    items: [lineJson(id: 1, name: 'Tea', quantity: 2, lineTotal: 22.4)],
    total: 22.4,
  ),
  'table_ref': table,
})!;

TableOrderSummary summary(int id, {int version = 3, double total = 22.4}) =>
    TableOrderSummary(
      id: id,
      version: version,
      heldAt: DateTime.utc(2026, 10, 12, 9, id % 60),
      itemCount: 1,
      grandTotal: total,
    );

void main() {
  const parser = RuleBasedIntentParser();
  Future<VoiceIntent> parse(String t) =>
      parser.parse(t, voiceSessionId: 's', requestId: 'r');

  group('parser (English)', () {
    test('table commands, any number words; never confused with Quick Bill quantities', () async {
      for (final (t, n) in [
        ('Jacky, bill table 6.', 6),
        ('Jacky, show table 6.', 6),
        ('Jacky, find orders for table 6.', 6),
        ('Jacky, open table 6.', 6),
        ('show the active order for table 6', 6),
        ('bill table twelve', 12),
        ('BILL TABLE 21!', 21),
      ]) {
        final i = await parse(t);
        expect(
          (i.type, i.tableNumber),
          (VoiceIntentType.tableOrder, n),
          reason: t,
        );
      }
      expect(
        (await parse('Jacky, bill that order.')).type,
        VoiceIntentType.billShownOrder,
      );
      expect(
        (await parse('bill one order of fries')).type,
        VoiceIntentType.createQuickBill,
      );
      expect(
        (await parse('bill six coffees')).type,
        VoiceIntentType.createQuickBill,
      );
      expect((await parse('bill order 1048')).orderNumber, 1048);
      final unclear = await parse('bill table');
      expect(
        (unclear.type, unclear.need),
        (VoiceIntentType.needsClarification, ClarificationNeed.order),
      );
      expect((await parse('bill table 6')).type, VoiceIntentType.tableOrder);
      final ml = await parser.parse(
        'bill table 6',
        voiceSessionId: 's',
        requestId: 'r',
        language: VoiceLanguage.malayalam,
      );
      expect(
        (ml.type, ml.tableNumber),
        (VoiceIntentType.tableOrder, 6),
        reason: 'Phase 3A: the Malayalam grammar reads table requests too',
      );
    });
  });

  group('voice controller', () {
    late FakeOrders orders;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late MockVoiceTtsService tts;
    late VoiceController v;

    VoiceController make(FakeRecognizer s, CartController c, scope) =>
        VoiceController(
          permission: FakeMicrophone()..current = VoicePermission.granted,
          recognizer: s,
          scope: () => scope,
          previewService: ApiVoicePreviewService(
            FakeBackend(fakeServer).client,
          ),
          orderService: orders,
          cart: c,
          tts: tts,
        );

    setUp(() {
      weightEnabled = true;
      orders = FakeOrders()
        ..orders[51] = heldAt(51, '6')
        ..orders[52] = heldAt(52, '6', version: 7)
        ..orders[60] = heldAt(60, '9');
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      tts = MockVoiceTtsService();
      v = make(speech, cart, staffA);
    });
    tearDown(() {
      v.dispose();
      cart.dispose();
    });

    Future<void> say(String t) async {
      await v.start();
      speech.say(t);
      await pumpEventQueue();
    }

    test('no held orders at the table: said plainly; nothing looked up by id or billed', () async {
      await say('Jacky, bill table 6');
      expect(orders.tableLookups.single, (
        '6',
        v.session!.voiceSessionId,
        v.request!.requestId,
      ));
      expect(v.orderState, VoiceOrderState.notFound);
      expect(
        v.orderMessage,
        'No held orders are waiting for billing at table 6.',
      );
      expect(
        tts.spoken.last,
        'No held orders are waiting for billing at table 6.',
      );
      expect(orders.lookups, isEmpty);
      expect(service.resumeCalls, isEmpty);
    });

    test('one held order: shown for verification (server view, table label), NOT billed until confirmed', () async {
      orders.tables['9'] = [summary(60)];
      await say('show table nine');
      expect(v.orderState, VoiceOrderState.loaded);
      expect(v.order!.id, 60);
      expect(v.order!.tableRef, '9');
      expect(v.tableRef, '9');
      expect(orders.lookups.single.$1, 60);
      expect(service.resumeCalls, isEmpty);
      expect(await v.confirmOrder(), isTrue);
      expect(
        (
          service.resumeCalls.single.saleId,
          service.resumeCalls.single.expectedVersion,
        ),
        (60, 3),
      );
    });

    test('several held orders: listed and NEVER chosen automatically; "bill that order" / yes cannot skip the choice', () async {
      orders.tables['6'] = [summary(52, version: 7, total: 40), summary(51)];
      await say('Jacky, find orders for table 6');
      expect(v.orderState, VoiceOrderState.choosing);
      expect(v.tableOrders.map((o) => o.id), [52, 51]);
      expect(v.order, isNull);
      expect(orders.lookups, isEmpty);
      expect(
        tts.spoken.last,
        'There are 2 orders at table 6. Choose one on the screen.',
      );
      expect(await v.confirmOrder(), isFalse);
      expect(await v.startOrderAnswer(), isFalse);
      expect(service.resumeCalls, isEmpty);
    });

    test('explicit choice: looked up again as a NEW request, verified, then billed with ITS version', () async {
      orders.tables['6'] = [summary(52, version: 7), summary(51)];
      await say('bill table 6');
      final tableRequest = v.request!.requestId;
      await v.chooseTableOrder(52);
      expect(v.orderState, VoiceOrderState.loaded);
      expect(v.order!.id, 52);
      expect(orders.lookups.single.$1, 52);
      expect(orders.lookups.single.$3, isNot(tableRequest));
      expect(v.tableRef, '6');
      expect(await v.startOrderAnswer(), isTrue);
      speech.say('yes');
      await pumpEventQueue();
      expect(
        (
          service.resumeCalls.single.saleId,
          service.resumeCalls.single.expectedVersion,
        ),
        (52, 7),
      );
      expect(v.confirmedByVoice, isTrue);
      expect(service.completeCalls, isEmpty);
    });

    test('a choice that is not in the list is ignored', () async {
      orders.tables['6'] = [summary(52), summary(51)];
      await say('bill table 6');
      await v.chooseTableOrder(999);
      expect(v.orderState, VoiceOrderState.choosing);
      expect(orders.lookups, isEmpty);
    });

    test('cancel from the list bills nothing', () async {
      orders.tables['6'] = [summary(52), summary(51)];
      await say('bill table 6');
      v.cancelBill();
      expect(v.orderState, VoiceOrderState.none);
      expect(service.resumeCalls, isEmpty);
    });

    test('moved / changed after it was shown: 409 -> Reload shows the fresh version', () async {
      orders.tables['9'] = [summary(60)];
      await say('bill table 9');
      service.onResume = (c) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
      );
      expect(await v.confirmOrder(), isFalse);
      expect(v.orderState, VoiceOrderState.conflict);
      orders.orders[60] = heldAt(60, '10', version: 5);
      service.onResume = (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
      await v.retryOrder();
      expect(v.order!.version, 5);
      expect(
        v.order!.tableRef,
        '10',
        reason: 'the reload shows where it is now',
      );
      expect(await v.confirmOrder(), isTrue);
      expect(service.resumeCalls.last.expectedVersion, 5);
    });

    test('table lookup network error: Retry repeats the TABLE lookup (new request id)', () async {
      orders.failWith = const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await say('bill table 6');
      expect(v.orderState, VoiceOrderState.failed);
      expect(v.orderRetryable, isTrue);
      orders.failWith = null;
      orders.tables['6'] = [summary(52), summary(51)];
      await v.retryOrder();
      expect(v.orderState, VoiceOrderState.choosing);
      expect(orders.tableLookups, hasLength(2));
      expect(orders.tableLookups.last.$3, isNot(orders.tableLookups.first.$3));
    });

    test(
      'two devices: each table lookup and choice stays with its own session',
      () async {
        orders.tables['6'] = [summary(52), summary(51)];
        final speechB = FakeRecognizer();
        final cartB = CartController(growingCart());
        final b = make(speechB, cartB, staffB);
        addTearDown(() {
          b.dispose();
          cartB.dispose();
        });
        await say('bill table 6');
        await b.start();
        speechB.say('bill table 6');
        await pumpEventQueue();
        await v.chooseTableOrder(51);
        expect(v.order!.id, 51);
        expect(b.orderState, VoiceOrderState.choosing);
        expect(b.order, isNull);
        expect(orders.tableLookups.map((x) => x.$2).toSet(), {
          v.session!.voiceSessionId,
          b.session!.voiceSessionId,
        });
      },
    );
  });

  group('hold for table', () {
    test('table labels: normalised like the server; invalid ones refused before sending', () {
      expect(TableRef.normalize('  patio   2 '), 'PATIO 2');
      expect(TableRef.normalize(''), isNull);
      expect(TableRef.problem('6'), isNull);
      for (final bad in ['6!', '-6', 'x' * 17, '<b>']) {
        expect(TableRef.problem(bad), isNotNull, reason: bad);
      }
    });

    test('holding with a table sends it with the hold (same version-checked call); plain hold sends none', () async {
      final service = growingCart();
      final cart = CartController(service);
      addTearDown(cart.dispose);
      await cart.addItem(9900, 1);
      expect(await cart.holdCurrent(tableRef: '6'), isTrue);
      expect(service.holdCalls.single.tableRef, '6');
      await cart.addItem(9900, 1);
      expect(await cart.holdCurrent(), isTrue);
      expect(service.holdCalls.last.tableRef, isNull);
    });

    testWidgets(
      'the table dialog: validates, normalises, offers Clear for an existing table',
      (tester) async {
        TableChoice? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async =>
                    result = await showTableRefDialog(ctx, initial: '6'),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('table-ref-field')), 'a1!');
        await tester.tap(find.byKey(const Key('table-ref-save')));
        await tester.pump();
        expect(find.textContaining('Use up to 16 letters'), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('table-ref-field')),
          ' a1 ',
        );
        await tester.tap(find.byKey(const Key('table-ref-save')));
        await tester.pumpAndSettle();
        expect((result as SetTable).tableRef, 'A1');
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('table-ref-clear')));
        await tester.pumpAndSettle();
        expect(result, isA<ClearTable>());
      },
    );
  });

  group('Orders screen', () {
    late FakeHeldSalesService list;
    late FakeCartService service;
    late HeldSalesController held;
    late CartController cart;
    late SessionController session;

    setUp(() {
      list = FakeHeldSalesService();
      service = FakeCartService();
      held = HeldSalesController(list, service);
      cart = CartController(service, onHeldSalesChanged: () => held.refresh());
      session = SessionController(FakeAuthService(), MemoryTokenStore());
    });

    Future<void> pump(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<HeldSalesController>.value(value: held),
            ChangeNotifierProvider<CartController>.value(value: cart),
            ChangeNotifierProvider<SessionController>.value(value: session),
          ],
          child: const MaterialApp(home: Scaffold(body: HeldSalesView())),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'held orders show their table; sales without one look as before; the table can be changed and cleared',
      (tester) async {
        list.onList = () async => [
          HeldSaleSummary.fromJson({
            ...heldRowJson(id: 51, version: 3),
            'table_ref': '6',
          })!,
          HeldSaleSummary.fromJson(heldRowJson(id: 52, version: 2))!,
        ];
        service.onGet = (id) async => heldAt(id, '6');
        await pump(tester);
        expect(find.byKey(const Key('held-table-51')), findsOneWidget);
        expect(find.text('Table 6'), findsWidgets);
        expect(find.byKey(const Key('held-table-52')), findsNothing);
        await held.openDetail(51);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('held-detail-table')), findsOneWidget);
        await tester.tap(find.byKey(const Key('held-change-table')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const Key('table-ref-field')), '7');
        await tester.tap(find.byKey(const Key('table-ref-save')));
        await tester.pumpAndSettle();
        expect(list.tableCalls.single, (51, 3, '7'));
        expect(find.text('Sale #51 is now at table 7.'), findsOneWidget);
        expect(held.detail!.tableRef, '7');
        await tester.tap(find.byKey(const Key('held-change-table')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('table-ref-clear')));
        await tester.pumpAndSettle();
        expect(list.tableCalls.last.$3, isNull);
      },
    );

    testWidgets('a conflicting table change reports it and reloads the sale', (
      tester,
    ) async {
      list.onList = () async => [
        HeldSaleSummary.fromJson({
          ...heldRowJson(id: 51, version: 3),
          'table_ref': '6',
        })!,
      ];
      service.onGet = (id) async => heldAt(id, '6');
      list.onSetTable = (id, v, t) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
      );
      await pump(tester);
      await held.openDetail(51);
      await tester.pumpAndSettle();
      final reads = service.getCalls;
      await tester.tap(find.byKey(const Key('held-change-table')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('table-ref-field')), '7');
      await tester.tap(find.byKey(const Key('table-ref-save')));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This sale changed meanwhile'),
        findsOneWidget,
      );
      expect(service.getCalls, greaterThan(reads), reason: 'reloaded');
    });
  });
}
