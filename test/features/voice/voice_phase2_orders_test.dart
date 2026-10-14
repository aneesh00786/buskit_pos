// Phase 2 — English "bill order 1048": an existing order is a HELD sale.
// Lookup is the server's (store-scoped, read only); the order is shown for
// verification; "yes" / "Bill this order" is the EXISTING resume (version
// checked) of the SAME sale, then the existing checkout. Tables are not part
// of the Phase 2 model; Phase 2.1 adds them (see voice_phase21_tables_test).
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/voice/data/voice_order_service.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB;
import 'voice_phase1_test.dart' show FakeRecovery, recoverable;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

CartSale heldOrder(int id, {int version = 4}) => CartSaleFactory.sale(
  id: id,
  version: version,
  status: 'held',
  total: 33.6,
  items: [
    lineJson(id: 1, quantity: 2, name: 'Tea', lineTotal: 22.4),
    lineJson(id: 2, name: 'Bun', lineTotal: 11.2),
  ],
);

class FakeOrders implements VoiceOrderService {
  final orders = <int, CartSale>{};
  final lookups = <(int, String, String)>[];
  final links = <(int, String, String)>[];
  ApiException? failWith;
  bool answerForAnotherRequest = false;

  @override
  Future<VoiceOrderLookup> lookup({
    required int orderNumber,
    required String voiceSessionId,
    required String requestId,
  }) async {
    lookups.add((orderNumber, voiceSessionId, requestId));
    if (failWith != null) throw failWith!;
    final o = orders[orderNumber];
    if (o == null) {
      throw apiError(
        404,
        message: 'No order $orderNumber is waiting to be billed in this store.',
        code: 'POS_VOICE_ORDER_NOT_FOUND',
      );
    }
    return VoiceOrderLookup(
      voiceSessionId: voiceSessionId,
      requestId: answerForAnotherRequest ? 'other' : requestId,
      order: o,
    );
  }

  final tables = <String, List<TableOrderSummary>>{};
  final tableLookups = <(String, String, String)>[];

  @override
  Future<VoiceTableLookup> lookupTable({
    required String tableRef,
    required String voiceSessionId,
    required String requestId,
  }) async {
    tableLookups.add((tableRef, voiceSessionId, requestId));
    if (failWith != null) throw failWith!;
    return VoiceTableLookup(
      voiceSessionId: voiceSessionId,
      requestId: requestId,
      tableRef: tableRef,
      orders: tables[tableRef] ?? const [],
    );
  }

  @override
  Future<void> linkQuickBill({
    required int saleId,
    required String voiceSessionId,
    required String requestId,
  }) async {
    links.add((saleId, voiceSessionId, requestId));
  }
}

void main() {
  const parser = RuleBasedIntentParser();
  Future<VoiceIntent> parse(String t) =>
      parser.parse(t, voiceSessionId: 's', requestId: 'r');

  group('2B parser: existing orders (English)', () {
    test(
      '"bill order N" with the "Jacky," prefix, punctuation and spoken numbers',
      () async {
        for (final t in [
          'Jacky, bill order 1048.',
          'bill order number 1048',
          'Show order 1048',
          'JACKY, OPEN ORDER #1048!',
          'bill order one zero four eight',
          'bill order ten forty eight',
          'bill order one thousand and forty eight',
          'Jacky, pull up the order 1048',
        ]) {
          final i = await parse(t);
          expect(
            (i.type, i.orderNumber),
            (VoiceIntentType.billOrder, 1048),
            reason: t,
          );
        }
        expect((await parse('bill order forty two')).orderNumber, 42);
      },
    );

    test(
      'tables: recognised (and answered), never turned into an order guess',
      () async {
        for (final t in [
          'Jacky, bill table 6.',
          'Show the active order for table 6.',
          'bill table six',
        ]) {
          final i = await parse(t);
          expect(
            (i.type, i.tableNumber, i.orderNumber),
            (VoiceIntentType.tableOrder, 6, null),
            reason: t,
          );
        }
      },
    );

    test('"bill that order"; missing or unclear numbers ask', () async {
      expect(
        (await parse('Bill that order.')).type,
        VoiceIntentType.billShownOrder,
      );
      for (final t in [
        'bill order',
        'bill order banana',
        'bill table',
        'show order two and coffee',
      ]) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.needsClarification, reason: t);
        expect(i.need, ClarificationNeed.order, reason: t);
        expect(i.clarification, isNotNull, reason: t);
      }
    });

    test('Quick Bill is unchanged ("order" inside a product request is not an order lookup)', () async {
      expect(
        (await parse('bill two coffees')).type,
        VoiceIntentType.createQuickBill,
      );
      expect(
        (await parse('bill one order of fries')).type,
        VoiceIntentType.createQuickBill,
      );
      expect((await parse('the order is ready')).type, VoiceIntentType.unknown);
    });

    test('spoken numbers are whole or nothing', () {
      expect(RuleBasedIntentParser.spokenInteger(['1048']), 1048);
      expect(RuleBasedIntentParser.spokenInteger(['twenty', 'one']), 21);
      expect(
        RuleBasedIntentParser.spokenInteger(['two', 'hundred', 'and', 'five']),
        205,
      );
      expect(RuleBasedIntentParser.spokenInteger(['seven', 'banana']), isNull);
      expect(
        RuleBasedIntentParser.spokenInteger([
          'one',
          'two',
          'three',
          'four',
          'five',
        ]),
        12345,
      );
    });

    test(
      'Phase 3A: a Malayalam session reads orders with its OWN grammar (code-mixed "bill order 1048" too); a language without a grammar never does',
      () async {
        final ml = await parser.parse(
          'bill order 1048',
          voiceSessionId: 's',
          requestId: 'r',
          language: VoiceLanguage.malayalam,
        );
        expect((ml.type, ml.orderNumber), (VoiceIntentType.billOrder, 1048));
        final ta = await parser.parse(
          'bill order 1048',
          voiceSessionId: 's',
          requestId: 'r',
          language: const VoiceLanguage('ta-IN', 'Tamil'),
        );
        expect(ta.type, VoiceIntentType.unsupportedLanguage);
      },
    );
  });

  group('2B / 2C / 2E controller', () {
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
      orders = FakeOrders()..orders[1048] = heldOrder(1048);
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

    Future<void> answer(String t) async {
      expect(await v.startOrderAnswer(), isTrue, reason: t);
      speech.say(t);
      await pumpEventQueue();
    }

    test('looked up by THIS voice session / request; the server view is shown with its total and the question', () async {
      await say('Jacky, bill order 1048');
      expect(v.orderState, VoiceOrderState.loaded);
      expect(v.order!.id, 1048);
      expect(v.order!.version, 4);
      expect(orders.lookups.single.$1, 1048);
      expect(orders.lookups.single.$2, v.session!.voiceSessionId);
      expect(orders.lookups.single.$3, v.request!.requestId);
      expect(
        tts.spoken.last,
        'Order 1048. The total is 33.60. Would you like to bill this order?',
      );
      expect(
        service.resumeCalls,
        isEmpty,
        reason: 'nothing changes until confirmed',
      );
    });

    test('no matching order: explained; nothing billed', () async {
      await say('bill order 77');
      expect(v.orderState, VoiceOrderState.notFound);
      expect(
        v.orderMessage,
        'No order 77 is waiting to be billed in this store.',
      );
      expect(await v.confirmOrder(), isFalse);
      expect(service.resumeCalls, isEmpty);
    });

    test('"bill table 6" with no held orders there (Phase 2.1): said plainly; nothing billed', () async {
      await say('Jacky, bill table 6');
      expect(orders.tableLookups.single.$1, '6');
      expect(v.orderState, VoiceOrderState.notFound);
      expect(
        v.orderMessage,
        'No held orders are waiting for billing at table 6.',
      );
      expect(service.resumeCalls, isEmpty);
    });

    test('spoken "yes": the EXISTING resume of the shown version, with the voice ids; then checkout (nothing paid)', () async {
      await say('bill order 1048');
      await answer('Yes, bill it');
      final call = service.resumeCalls.single;
      expect((call.saleId, call.expectedVersion), (1048, 4));
      expect(call.voice!['voice_session_id'], v.session!.voiceSessionId);
      expect(
        call.voice!['request_id'],
        isNot(orders.lookups.single.$3),
        reason: 'the bill action has its own request id',
      );
      expect(v.billState, VoiceBillState.added);
      expect(v.confirmedByVoice, isTrue);
      expect(service.completeCalls, isEmpty);
      expect(cart.sale!.id, 1048, reason: 'the SAME sale is now in the cart');
    });

    test('"bill that order" while the order is shown also bills it; a repeated answer bills nothing twice', () async {
      await say('bill order 1048');
      await answer('Bill that order.');
      expect(service.resumeCalls, hasLength(1));
      expect(await v.startOrderAnswer(), isFalse);
      expect(await v.confirmOrder(), isFalse);
      expect(service.resumeCalls, hasLength(1));
    });

    test('"no" / "cancel" leave the order as it is', () async {
      await say('bill order 1048');
      await answer('cancel');
      expect(v.orderState, VoiceOrderState.none);
      expect(service.resumeCalls, isEmpty);
      await say('bill order 1048');
      await answer('No');
      expect(service.resumeCalls, isEmpty);
      expect(
        tts.spoken.last,
        'The order was left as it is. Nothing was billed.',
      );
    });

    test('an unclear answer asks again and bills nothing', () async {
      await say('bill order 1048');
      await answer('maybe later');
      expect(v.correctionQuestion, contains('say yes to bill this order'));
      expect(service.resumeCalls, isEmpty);
      expect(v.orderState, VoiceOrderState.loaded);
    });

    test('changed by someone else after it was shown (409): clear message, Reload shows the fresh order, which can then be billed', () async {
      service.onResume = (c) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
      );
      await say('bill order 1048');
      expect(await v.confirmOrder(), isFalse);
      expect(v.orderState, VoiceOrderState.conflict);
      expect(v.orderMessage, VoiceController.orderChangedMessage);
      orders.orders[1048] = heldOrder(1048, version: 6);
      service.onResume = (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
      await v.retryOrder();
      expect(v.orderState, VoiceOrderState.loaded);
      expect(v.order!.version, 6);
      expect(orders.lookups, hasLength(2));
      expect(
        orders.lookups.last.$3,
        isNot(orders.lookups.first.$3),
        reason: 'reload is a new request',
      );
      expect(await v.confirmOrder(), isTrue);
      expect(service.resumeCalls.last.expectedVersion, 6);
    });

    test(
      'no longer billable here (403 / 404 on resume): marked ineligible',
      () async {
        service.onResume = (c) async => throw apiError(
          403,
          message: 'This sale belongs to a different store',
        );
        await say('bill order 1048');
        expect(await v.confirmOrder(), isFalse);
        expect(v.orderState, VoiceOrderState.ineligible);
      },
    );

    test('network failure on resume: outcome unknown, so reload before trying again (no blind retry)', () async {
      service.onResume = (c) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await say('bill order 1048');
      expect(await v.confirmOrder(), isFalse);
      expect(v.orderMessage, VoiceController.orderUncertainMessage);
      expect(service.resumeCalls, hasLength(1));
      expect(await v.confirmOrder(), isFalse, reason: 'must reload first');
      expect(service.resumeCalls, hasLength(1));
    });

    test('lookup network failure: Retry is offered and re-asks with a new request id', () async {
      orders.failWith = const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await say('bill order 1048');
      expect(v.orderState, VoiceOrderState.failed);
      expect(v.orderRetryable, isTrue);
      orders.failWith = null;
      await v.retryOrder();
      expect(v.orderState, VoiceOrderState.loaded);
    });

    test("an answer for another request is never shown", () async {
      orders.answerForAnotherRequest = true;
      await say('bill order 1048');
      expect(v.order, isNull);
      expect(v.orderState, VoiceOrderState.failed);
    });

    test('an open sale in the cart is never overwritten: the cart refuses, the order stays unbilled', () async {
      await cart.addItem(9900, 1);
      await say('bill order 1048');
      expect(await v.confirmOrder(), isFalse);
      expect(service.resumeCalls, isEmpty);
      expect(cart.error, isNotNull);
    });

    test('2D: a confirmed voice QUICK BILL is linked to its draft (best effort, after the bill is added)', () async {
      await say('bill two coffees');
      expect(await v.confirmBill(), isTrue);
      await pumpEventQueue();
      expect(orders.links.single.$1, cart.sale!.id);
      expect(orders.links.single.$2, v.session!.voiceSessionId);
    });

    test(
      'Quick Bill Phase 1 behaviour is unchanged on the same screen',
      () async {
        await say('bill two coffees');
        expect(v.previewState, VoicePreviewState.loaded);
        expect(v.orderState, VoiceOrderState.none);
        expect(await v.startCorrection(), isTrue);
        speech.say('yes');
        await pumpEventQueue();
        expect(v.billState, VoiceBillState.added);
      },
    );

    test(
      'two staff members: each sees and bills only their own order lookup',
      () async {
        orders.orders[2001] = heldOrder(2001, version: 2);
        final speechB = FakeRecognizer();
        final cartB = CartController(growingCart());
        final b = make(speechB, cartB, staffB);
        addTearDown(() {
          b.dispose();
          cartB.dispose();
        });
        await say('bill order 1048');
        await b.start();
        speechB.say('bill order 2001');
        await pumpEventQueue();
        expect(v.order!.id, 1048);
        expect(b.order!.id, 2001);
        expect(v.session!.voiceSessionId, isNot(b.session!.voiceSessionId));
        expect(await v.confirmOrder(), isTrue);
        expect(b.billState, VoiceBillState.none);
        expect(cartB.sale, isNull);
      },
    );
  });

  testWidgets(
    'screen: "bill order" -> verify -> Bill this order -> the dialog closes, the existing checkout opens, then the authoritative payment status shows',
    (tester) async {
      final orders = FakeOrders()..orders[1048] = heldOrder(1048);
      final speech = FakeRecognizer();
      final service = growingCart();
      final cart = CartController(service);
      addTearDown(cart.dispose);
      final recovery = FakeRecovery(
        (ids) => PaymentRecoveryResult(
          recoverable: [recoverable(ids.single, RecoveryState.noPayment)],
        ),
      );
      var checkout = 0;
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<CartController>.value(
          value: cart,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  key: const Key('open-voice'),
                  onPressed: () => startVoiceBill(
                    ctx,
                    openCheckout: (_) async => checkout++,
                    permission: FakeMicrophone()
                      ..current = VoicePermission.granted,
                    recognizer: speech,
                    previewService: ApiVoicePreviewService(
                      FakeBackend(fakeServer).client,
                    ),
                    scope: () => staffA,
                    recovery: recovery,
                    orderService: orders,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('open-voice')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-start')));
      await tester.pump();
      speech.say('Jacky, bill order 1048');
      await tester.pumpAndSettle();
      expect(find.text('Verify order #1048'), findsOneWidget);
      expect(find.byKey(const Key('voice-order-awaiting')), findsOneWidget);
      expect(find.textContaining('Jacky'), findsNothing);
      await tester.tap(find.byKey(const Key('voice-bill-order')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(checkout, 1);
      expect(service.resumeCalls.single.saleId, 1048);
      expect(
        find.text(
          'Voice bill: Unpaid — no payment has been taken for this bill.',
        ),
        findsOneWidget,
      );
      expect(recovery.asked, [
        [1048],
      ]);
    },
  );
}
