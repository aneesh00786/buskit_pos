// Phase 13C-C — Confirm Bill on a READY voice preview puts the server-resolved
// lines into the NORMAL POS cart (existing draft creation + add-item API,
// through CartController) and hands over to the EXISTING checkout. The
// preview is never authoritative: no price, tax or total is sent, and
// nothing here pays or completes a sale.
import 'dart:async';
import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/models/quick_bill_preview.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB;
import 'voice_preview_test.dart' show FakeBackend, line, ok, readyCoffeeWater;

/// Two coffees (PIECE) and 1.255 kg of rice (WEIGHT), resolved by the server.
(int, Map<String, dynamic>) readyCoffeeRice(Map<String, dynamic> b) => (
  200,
  ok({
    'status': 'READY',
    'voice_session_id': b['voice_session_id'],
    'request_id': b['request_id'],
    'recognized_text': b['recognized_text'],
    'items': [
      line(0, 'Coffee', 'Regular', 2, price: 4.5, tax: 0.45, total: 9.45),
      line(
        1,
        'Loose Rice',
        'Per kg',
        1.255,
        unit: 'kg',
        mode: 'WEIGHT',
        price: 89.99,
        tax: 0,
        total: 112.937,
      ),
    ],
    'issues': [],
    'subtotal': 121.937,
    'tax': 0.45,
    'total': 122.387,
  }),
);

/// A FakeCartService whose sale really grows as lines are added.
FakeCartService growingCart() {
  final cart = FakeCartService();
  final lines = <Map<String, dynamic>>[];
  cart.onAdd = (c) async {
    lines.add(
      lineJson(
        id: 100 + lines.length,
        variationId: c.variationId,
        quantity: c.quantity,
      ),
    );
    return CartSale.fromJson(
      saleJson(id: c.saleId, version: c.expectedVersion + 1, items: [...lines]),
    )!;
  };
  return cart;
}

VoiceController voiceFor(
  FakeBackend backend,
  FakeRecognizer speech,
  CartController cart, {
  PosTokenScope? Function()? scope,
}) => VoiceController(
  permission: FakeMicrophone()..current = VoicePermission.granted,
  recognizer: speech,
  scope: scope ?? () => staffA,
  previewService: ApiVoicePreviewService(backend.client),
  cart: cart,
);

Future<void> speak(
  VoiceController v,
  FakeRecognizer speech,
  String text,
) async {
  await v.start();
  speech.say(text);
  await pumpEventQueue();
}

/// A cart with its own duplicate protection switched OFF: never "busy", and
/// every add is recorded and held on [gate]. Only the voice controller's own
/// double-confirm guard can then stop a second Confirm Bill.
class UnguardedCart extends CartController {
  UnguardedCart() : super(FakeCartService());
  final adds = <int>[];
  final gate = Completer<void>();

  @override
  bool get isMutating => false;

  @override
  Future<bool> addItem(
    int productVariationId,
    num quantity, {
    String? label,
    String? imageUrl,
    String sellingMode = 'PIECE',
  }) async {
    adds.add(productVariationId);
    await gate.future;
    return true;
  }
}

void main() {
  test('1-5/7/8. on the wire: ONE draft (POST /sales), the server-resolved variation ids with exact quantities (PIECE whole, WEIGHT 3 dp), no price/tax/total, no complete, no payment', () async {
    final calls = <http.Request>[];
    var version = 1;
    final lines = <Map<String, dynamic>>[];
    late final PosApiClient client;
    Future<http.Response> respond(http.Request r) async {
      calls.add(r);
      Map<String, dynamic> body() => jsonDecode(r.body) as Map<String, dynamic>;
      Object data;
      if (r.url.path.endsWith('/voice/quick-bill/preview')) {
        data = readyCoffeeRice(body()).$2['data'] as Object;
      } else if (r.url.path.endsWith('/sales')) {
        data = saleJson(id: 501, version: version);
      } else if (r.url.path.endsWith('/sales/501/items')) {
        final b = body();
        lines.add(
          lineJson(
            id: 900 + lines.length,
            variationId: b['product_variation_id'] as int,
            quantity: b['quantity'] as num,
          ),
        );
        data = saleJson(id: 501, version: ++version, items: [...lines]);
      } else {
        return http.Response('{}', 404);
      }
      return http.Response(jsonEncode(ok(data)), 200);
    }

    client = PosApiClient(
      baseUrl: 'http://pos.test',
      httpClient: MockClient(respond),
      tokenProvider: () => 'staff-token',
    );
    final cart = CartController(ApiCartService(client));
    final speech = FakeRecognizer();
    final voice = VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: speech,
      scope: () => staffA,
      previewService: ApiVoicePreviewService(client),
      cart: cart,
    );
    addTearDown(voice.dispose);
    addTearDown(cart.dispose);
    await speak(voice, speech, 'Bill two coffees and 1.255 kg rice');
    expect(voice.preview!.isReady, isTrue);

    expect(await voice.confirmBill(), isTrue);
    expect(voice.billState, VoiceBillState.added);

    final paths = calls.map((r) => '${r.method} ${r.url.path}').toList();
    expect(paths.where((p) => p.endsWith('/sales')), hasLength(1));
    final adds = calls.where((r) => r.url.path.endsWith('/sales/501/items'));
    expect(adds.map((r) => jsonDecode(r.body)), [
      {'product_variation_id': 9900, 'quantity': 2, 'expected_version': 1},
      {'product_variation_id': 9901, 'quantity': 1.255, 'expected_version': 2},
    ]);
    // Exact on the wire: an int for pieces, 3 decimals for weight.
    expect(adds.first.body, contains('"quantity":2,'));
    expect(adds.last.body, contains('"quantity":1.255,'));
    // Only the existing draft + add-item APIs; the sale-create body is empty.
    expect(
      jsonDecode(calls.firstWhere((r) => r.url.path.endsWith('/sales')).body),
      isEmpty,
    );
    for (final r in calls) {
      expect(r.url.path, isNot(contains('/complete')), reason: r.url.path);
      expect(r.url.path, isNot(contains('payment')), reason: r.url.path);
      if (!r.url.path.endsWith('/preview')) {
        final b = jsonDecode(r.body) as Map<String, dynamic>;
        for (final k in [
          'price',
          'unit_price',
          'tax',
          'total',
          'line_total',
          'company_id',
          'store_id',
        ]) {
          expect(b.containsKey(k), isFalse, reason: '$k in ${r.url.path}');
        }
      }
    }
    expect(cart.sale!.items.map((i) => i.quantity), [2, 1.255]);
  });

  group('controller', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late VoiceController voice;
    var unauthorized = 0;

    setUp(() {
      backend = FakeBackend(readyCoffeeWater);
      speech = FakeRecognizer();
      service = growingCart();
      unauthorized = 0;
      cart = CartController(service, onUnauthorized: () => unauthorized++);
      voice = voiceFor(backend, speech, cart);
    });
    tearDown(() {
      voice.dispose();
      cart.dispose();
    });

    Future<void> ready() async {
      await speak(voice, speech, 'Bill two coffees and one water');
      expect(voice.preview!.isReady, isTrue);
    }

    test('9. double Confirm: one draft, each line added once', () async {
      await ready();
      final gate = Completer<void>();
      service.onCreate = () async {
        await gate.future;
        return CartSale.fromJson(saleJson())!;
      };
      final first = voice.confirmBill();
      final second = voice.confirmBill();
      expect(voice.billState, VoiceBillState.adding);
      gate.complete();
      expect(await second, isFalse);
      expect(await first, isTrue);
      expect(await voice.confirmBill(), isFalse, reason: 'already added');
      expect(service.createCalls, 1);
      expect(service.addCalls.map((c) => c.variationId), [9900, 9901]);
    });

    test('9b. the VOICE guard alone stops a second Confirm while the first is still adding (cart-level protection bypassed)', () async {
      final cart = UnguardedCart();
      final v = voiceFor(backend, speech, cart);
      addTearDown(v.dispose);
      addTearDown(cart.dispose);
      await speak(v, speech, 'Bill two coffees and one water');
      expect(v.preview!.isReady, isTrue);

      final first = v.confirmBill(); // starts, then waits on the first add
      expect(v.billState, VoiceBillState.adding);
      expect(cart.adds, [9900]);

      // Second Confirm while the first is still awaiting.
      expect(await v.confirmBill(), isFalse);
      expect(cart.adds, [9900], reason: 'no second checkout operation started');

      cart.gate.complete();
      expect(await first, isTrue);
      expect(cart.adds, [9900, 9901], reason: 'each line exactly once');
      expect(v.billState, VoiceBillState.added);
      expect(await v.confirmBill(), isFalse, reason: 'already added');
      expect(cart.adds, [9900, 9901]);
    });

    QuickBillPreview withIds(String session, String request) =>
        QuickBillPreview.fromJson(
          readyCoffeeWater({
            'voice_session_id': session,
            'request_id': request,
            'recognized_text': 'x',
          }).$2['data'],
        )!;

    void expectStale() {
      expect(voice.preview, isNull);
      expect(voice.previewError, VoiceController.staleBillMessage);
      expect(service.createCalls, 0);
      expect(service.addCalls, isEmpty);
    }

    test('10. a preview for another request id is refused: no draft, "no longer current"', () async {
      await ready();
      voice.debugSetPreview(
        withIds(voice.session!.voiceSessionId, 'old-request'),
      );
      expect(await voice.confirmBill(), isFalse);
      expectStale();
    });

    test('11. a preview for another voice session is refused (and so is a session another staff member now owns)', () async {
      await ready();
      voice.debugSetPreview(withIds('old-session', voice.request!.requestId));
      expect(await voice.confirmBill(), isFalse);
      expectStale();

      var who = staffA;
      final v2 = voiceFor(backend, speech, cart, scope: () => who);
      addTearDown(v2.dispose);
      await speak(v2, speech, 'Bill two coffees and one water');
      who = staffB; // signed out and someone else signed in
      expect(await v2.confirmBill(), isFalse);
      expect(v2.previewError, VoiceController.staleBillMessage);
      expect(service.createCalls, 0);
    });

    test('a cancelled preview cannot be confirmed', () async {
      await ready();
      voice.cancelBill();
      expect(await voice.confirmBill(), isFalse);
      expect(service.createCalls, 0);
    });

    test('a cart that already has a sale in progress is not mixed with the voice bill', () async {
      await cart.addItem(5, 1);
      final before = service.addCalls.length;
      await ready();
      expect(await voice.confirmBill(), isFalse);
      expect(voice.billError, VoiceController.busyCartMessage);
      expect(service.addCalls.length, before);
    });

    test('12/14. an add-item failure stops (no line skipped), shows the cart error safely, and takes back what was added', () async {
      await ready();
      service.onAdd = (c) async {
        if (c.variationId == 9901) {
          throw ApiException.fromStatus(
            409,
            message: 'Insufficient stock',
            errorCode: 'POS_INSUFFICIENT_STOCK',
            data: {
              'shortages': [
                {'requested': 1, 'available': 0},
              ],
            },
          );
        }
        return CartSale.fromJson(
          saleJson(
            id: c.saleId,
            version: c.expectedVersion + 1,
            items: [
              lineJson(
                id: 100,
                variationId: c.variationId,
                quantity: c.quantity,
              ),
            ],
          ),
        )!;
      };
      expect(await voice.confirmBill(), isFalse);
      expect(voice.billState, VoiceBillState.none);
      expect(voice.billError, 'Not enough stock: 1 requested, 0 available.');
      expect(service.removeCalls.map((c) => c.itemId), [
        100,
      ], reason: 'cleared');
      expect(service.completeCalls, isEmpty);
    });

    test('14. a server error never shows internal details; draft-creation failure adds nothing', () async {
      await ready();
      service.onCreate = () async => throw ApiException.fromStatus(
        500,
        message:
            "ER_NO_SUCH_TABLE: Table 'busskit_new.pos_sales' doesn't exist",
      );
      expect(await voice.confirmBill(), isFalse);
      expect(voice.billError, isNot(contains('ER_')));
      expect(voice.billError, isNot(contains('pos_sales')));
      expect(service.addCalls, isEmpty);
    });

    test('13. a 401 uses the existing session-expiry handling (no clean-up attempt)', () async {
      await ready();
      service.onAdd = (_) async => throw ApiException.fromStatus(401);
      expect(await voice.confirmBill(), isFalse);
      expect(unauthorized, 1);
      expect(
        voice.billError,
        'Your session has expired. Please sign in again.',
      );
      expect(service.removeCalls, isEmpty);
    });
  });

  group('checkout hand-off (startVoiceBill)', () {
    late FakeBackend backend;
    late FakeCartService service;
    late CartController cart;
    late FakeRecognizer speech;
    var checkoutOpened = 0;
    int? itemsAtCheckout;

    Future<void> openVoice(WidgetTester tester) async {
      backend = FakeBackend(readyCoffeeWater);
      speech = FakeRecognizer();
      cart = CartController(service);
      addTearDown(cart.dispose);
      checkoutOpened = 0;
      itemsAtCheckout = null;
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
                    openCheckout: (_) async {
                      checkoutOpened++;
                      itemsAtCheckout = cart.sale?.items.length;
                    },
                    permission: FakeMicrophone()
                      ..current = VoicePermission.granted,
                    recognizer: speech,
                    previewService: ApiVoicePreviewService(backend.client),
                    scope: () => staffA,
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
      speech.say('Bill two coffees and one water');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-confirm-bill')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      '6/7/8. success: the voice dialog closes and the EXISTING checkout opens with the bill in the cart — nothing paid or completed',
      (tester) async {
        service = growingCart();
        await openVoice(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(checkoutOpened, 1);
        expect(itemsAtCheckout, 2);
        expect(service.createCalls, 1);
        expect(service.completeCalls, isEmpty);
        expect(service.callLog.where((c) => c.startsWith('complete')), isEmpty);
      },
    );

    testWidgets(
      '12. failure: stays on the voice screen with the error; checkout is NOT opened',
      (tester) async {
        service = growingCart()
          ..onAdd = (_) async => throw ApiException.fromStatus(
            403,
            errorCode: 'POS_PERMISSION_DENIED',
            data: {'permission': 'sales.edit_current'},
          );
        await openVoice(tester);
        expect(find.byType(AlertDialog), findsOneWidget);
        expect(checkoutOpened, 0);
        expect(
          find.text(
            'You do not have permission to change this sale. Ask a manager or administrator.',
          ),
          findsOneWidget,
        );
        expect(find.byKey(const Key('voice-confirm-bill')), findsOneWidget);
      },
    );
  });
}
