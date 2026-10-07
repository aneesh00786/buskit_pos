// Phase 13D — Quick Bill correction and re-verification. "Jacky, …" prefix;
// change a line's quantity, remove a line, explicitly choose a server
// candidate — every correction is a NEW server preview (same voice session,
// new request id) that must be READY again before Confirm Bill. The fake
// server below prices lines itself (standing in for the backend); Flutter
// never computes money.
import 'dart:async';
import 'dart:convert';

import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/models/quick_bill_preview.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;
import 'voice_preview_test.dart' show FakeBackend, ok;

/// The fake server's catalogue: query -> sellable variations
/// (id, name, variant, mode, price, tax %).
const catalogue = {
  'coffee': [(9900, 'Coffee', 'Regular', 'PIECE', 4.5, 5)],
  'water': [(9901, 'Water', '1 L', 'PIECE', 18.0, 0)],
  'sugar': [
    (9907, 'Sugar', '1 kg pack', 'PIECE', 45.0, 5),
    (9908, 'Sugar', '500 g pack', 'PIECE', 25.0, 5),
  ],
  'rice': [(9909, 'Loose Rice', 'Per kg', 'WEIGHT', 89.99, 0)],
};
var weightEnabled = true;

double r3(num v) => double.parse(v.toStringAsFixed(3));

/// Resolves like the backend: one match -> priced line; several -> asks
/// (never picks) unless an offered product_variation_id was chosen.
(int, Map<String, dynamic>) fakeServer(Map<String, dynamic> b) {
  final items = <Map<String, dynamic>>[];
  final issues = <Map<String, dynamic>>[];
  var sub = 0.0, tax = 0.0;
  for (final (i, raw) in (b['items'] as List).indexed) {
    final it = raw as Map<String, dynamic>;
    final query = it['product_query'] as String;
    var rows = catalogue[query] ?? const [];
    final chosen = it['product_variation_id'];
    if (chosen != null) {
      rows = rows.where((r) => r.$1 == chosen).toList();
      if (rows.isEmpty) {
        issues.add({
          'item_index': i,
          'code': 'SELECTION_NOT_AVAILABLE',
          'message': "That product cannot be chosen for '$query'.",
          'product_query': query,
        });
        continue;
      }
    }
    if (rows.length != 1) {
      issues.add({
        'item_index': i,
        'code': rows.isEmpty ? 'PRODUCT_NOT_FOUND' : 'MULTIPLE_PRODUCT_MATCHES',
        'message': rows.isEmpty
            ? "Could not find a matching product for '$query'."
            : "More than one product matches '$query'. Which one?",
        'product_query': query,
        'candidates': [
          for (final r in rows)
            {
              'product_variation_id': r.$1,
              'product_name': r.$2,
              'variant_name': r.$3,
              'selling_mode': r.$4,
            },
        ],
      });
      continue;
    }
    final r = rows.single;
    if (r.$4 == 'WEIGHT' && !weightEnabled) {
      issues.add({
        'item_index': i,
        'code': 'WEIGHT_NOT_SUPPORTED',
        'message': 'This product is sold by weight, which is not enabled.',
        'product_query': query,
      });
      continue;
    }
    final q = it['quantity'] as num;
    final lineSub = r3(r.$5 * q);
    final lineTax = r3(lineSub * r.$6 / 100);
    sub += lineSub;
    tax += lineTax;
    items.add({
      'item_index': i,
      'status': 'RESOLVED',
      'product_variation_id': r.$1,
      'product_name': r.$2,
      'variant_name': r.$3,
      'selling_mode': r.$4,
      'quantity': q,
      'unit': it['unit'],
      'unit_price': r.$5,
      'tax_percent': r.$6,
      'tax_included': false,
      'line_subtotal': lineSub,
      'tax': lineTax,
      'line_total': r3(lineSub + lineTax),
    });
  }
  final ready = issues.isEmpty;
  return (
    200,
    ok({
      'status': ready ? 'READY' : 'NEEDS_CLARIFICATION',
      'voice_session_id': b['voice_session_id'],
      'request_id': b['request_id'],
      'recognized_text': b['recognized_text'],
      'items': items,
      'issues': issues,
      'subtotal': ready ? r3(sub) : null,
      'tax': ready ? r3(tax) : null,
      'total': ready ? r3(sub + tax) : null,
    }),
  );
}

/// Answers each preview only when the test releases it (out of order).
class GatedPreviews implements VoicePreviewService {
  final calls = <(QuickBillRequest, Completer<QuickBillPreview>)>[];

  @override
  Future<QuickBillPreview> previewQuickBill(QuickBillRequest request) {
    final c = Completer<QuickBillPreview>();
    calls.add((request, c));
    return c.future;
  }

  void answer(int n) {
    final (req, c) = calls[n];
    c.complete(QuickBillPreview.fromJson(fakeServer(req.toJson()).$2['data'])!);
  }
}

void main() {
  const parser = RuleBasedIntentParser();
  Future<VoiceIntent> parse(String t) =>
      parser.parse(t, voiceSessionId: 's', requestId: 'r');
  List<Map<String, dynamic>> items(VoiceIntent i) => [
    for (final x in i.items) x.toJson(),
  ];

  group('"Jacky" prefix', () {
    test('1. "Jacky, bill two coffees" (any case, with or without the comma) = "bill two coffees"', () async {
      final plain = await parse('bill two coffees');
      for (final t in [
        'Jacky, bill two coffees',
        'jacky bill two coffees',
        'JACKY, BILL TWO COFFEES',
      ]) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.createQuickBill, reason: t);
        expect(items(i), items(plain), reason: t);
        expect(i.recognizedText, t, reason: 'what was said is kept');
      }
      final water = await parse('JACKY, quick bill one water');
      expect(water.type, VoiceIntentType.createQuickBill);
      expect(items(water), [
        {'spokenText': 'one water', 'quantity': 1, 'productQuery': 'water'},
      ]);
      // Exactly as without the name: an untriggered list still needs numbers.
      expect(
        (await parse('Jacky, two coffees')).type,
        VoiceIntentType.createQuickBill,
      );
      expect((await parse('Jacky, bill two')).need, ClarificationNeed.product);
    });

    test('2. "Jacky" alone never creates a bill; the parser is not fuzzy about the name', () async {
      for (final t in ['Jacky', 'jacky.', 'JACKY!', ' Jacky , ']) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.unknown, reason: t);
        expect(i.items, isEmpty);
      }
      for (final t in ['Jackie, bill two coffees', 'Jack bill two coffees']) {
        expect((await parse(t)).type, VoiceIntentType.unknown, reason: t);
      }
    });
  });

  group('corrections (controller)', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late VoiceController v;

    setUp(() {
      weightEnabled = true;
      backend = FakeBackend(fakeServer);
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      v = VoiceController(
        permission: FakeMicrophone()..current = VoicePermission.granted,
        recognizer: speech,
        scope: () => staffA,
        previewService: ApiVoicePreviewService(backend.client),
        cart: cart,
      );
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

    List<Object?> sentItems() => backend.lastBody['items'] as List;

    test('3/4/5/6. quantity change: same session, NEW request id, the old preview is gone and never confirmable, the new server total is shown', () async {
      await say('Jacky, bill two coffees and one water');
      final session = v.session!.voiceSessionId;
      final firstRequest = v.request!.requestId;
      final old = v.preview!;
      expect((old.total, old.isReady), (27.45, true));

      expect(await v.changeQuantity(0, 3), isNull);
      expect(backend.requests, hasLength(2));
      expect(backend.lastBody['voice_session_id'], session);
      expect(backend.lastBody['request_id'], isNot(firstRequest));
      expect(backend.lastBody['request_id'], v.request!.requestId);
      expect(sentItems(), [
        {'product_query': 'coffee', 'quantity': 3},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(v.session!.voiceSessionId, session);
      expect(v.preview!.requestId, v.request!.requestId);
      expect(v.preview!.items.first.quantity, 3);
      expect(v.preview!.total, 32.175, reason: "the server's new total");

      // The old preview, put back, is refused: nothing reaches the cart.
      v.debugSetPreview(old);
      expect(await v.confirmBill(), isFalse);
      expect(v.previewError, VoiceController.staleBillMessage);
      expect(service.createCalls, 0);
    });

    test(
      '5b. while a correction is being checked there is nothing to confirm',
      () async {
        final gated = GatedPreviews();
        final g = VoiceController(
          permission: FakeMicrophone()..current = VoicePermission.granted,
          recognizer: speech,
          scope: () => staffA,
          previewService: gated,
          cart: cart,
        );
        addTearDown(g.dispose);
        await g.start();
        speech.say('bill two coffees');
        await pumpEventQueue();
        gated.answer(0);
        await pumpEventQueue();
        expect(g.preview!.isReady, isTrue);
        unawaited(g.changeQuantity(0, 5));
        await pumpEventQueue();
        expect(g.previewState, VoicePreviewState.loading);
        expect(g.preview, isNull);
        expect(await g.confirmBill(), isFalse);
        expect(service.createCalls, 0);
      },
    );

    test('7/8. removing a line sends a new preview without it; removing the last line leaves nothing confirmable and sends nothing', () async {
      await say('bill two coffees and one water');
      await v.removeLine(1);
      expect(sentItems(), [
        {'product_query': 'coffee', 'quantity': 2},
      ]);
      expect(v.preview!.isReady, isTrue);
      expect(v.preview!.items.map((l) => l.productName), ['Coffee']);
      expect(v.preview!.total, 9.45);

      final sent = backend.requests.length;
      await v.removeLine(0);
      expect(
        backend.requests.length,
        sent,
        reason: 'an empty bill is not previewed',
      );
      expect(v.preview, isNull);
      expect(v.previewError, VoiceController.allRemovedMessage);
      expect(v.canCorrect, isFalse);
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
      expect(service.addCalls, isEmpty);
    });

    test('9/10. candidates are never auto-selected; an explicit choice sends that product_variation_id and gets a fresh server preview', () async {
      await say('bill one sugar and one water');
      expect(v.preview!.isReady, isFalse);
      expect(v.preview!.items.map((l) => l.productName), ['Water']);
      final issue = v.preview!.issues.single;
      expect(issue.candidates.map((c) => c.productVariationId), [9907, 9908]);
      expect(
        sentItems().every(
          (i) => !(i as Map).containsKey('product_variation_id'),
        ),
        isTrue,
      );
      expect(await v.confirmBill(), isFalse, reason: 'not READY');
      expect(service.createCalls, 0);

      final firstRequest = v.request!.requestId;
      await v.chooseCandidate(0, issue.candidates[1]);
      expect(sentItems(), [
        {'product_query': 'sugar', 'quantity': 1, 'product_variation_id': 9908},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(backend.lastBody['request_id'], isNot(firstRequest));
      expect(v.preview!.isReady, isTrue);
      expect(v.preview!.items.first.variantName, '500 g pack');
      // The choice is kept when that line is corrected again.
      await v.changeQuantity(0, 2);
      expect((sentItems().first as Map)['product_variation_id'], 9908);
    });

    test('a candidate that the current preview did not offer is ignored (nothing sent)', () async {
      await say('bill one sugar');
      final sent = backend.requests.length;
      await v.chooseCandidate(
        0,
        const QuickBillCandidate(
          productVariationId: 9900,
          productName: 'Coffee',
        ),
      );
      expect(backend.requests.length, sent);
      expect(v.preview!.isReady, isFalse);
    });

    test(
      '16. PIECE correction stays whole: 1.5 is refused locally (nothing sent)',
      () async {
        await say('bill two coffees');
        final sent = backend.requests.length;
        final problem = await v.changeQuantity(0, 1.5);
        expect(problem, isNotNull);
        expect(v.billError, problem);
        expect(backend.requests.length, sent);
        expect(v.preview!.items.first.quantity, 2);
      },
    );

    test('17. WEIGHT correction keeps the exact 3-decimal quantity (and its unit); 4 decimals are refused', () async {
      await say('bill 1.25 kg rice');
      expect(v.preview!.items.single.sellingMode, 'WEIGHT');
      expect(await v.changeQuantity(0, 1.255), isNull);
      expect(sentItems(), [
        {'product_query': 'rice', 'quantity': 1.255, 'unit': 'kg'},
      ]);
      expect(backend.requests.last.body, contains('"quantity":1.255,'));
      expect(v.preview!.items.single.quantity, 1.255);
      final sent = backend.requests.length;
      expect(await v.changeQuantity(0, 1.2555), isNotNull);
      expect(backend.requests.length, sent);
    });

    test('18. WEIGHT still obeys the backend flag: refused when the server says so — nothing to confirm', () async {
      weightEnabled = false;
      await say('bill 1.25 kg rice');
      expect(v.preview!.issues.single.code, 'WEIGHT_NOT_SUPPORTED');
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
    });

    test('19. a late answer to an older correction is discarded — only the newest request updates the screen', () async {
      final gated = GatedPreviews();
      final g = VoiceController(
        permission: FakeMicrophone()..current = VoicePermission.granted,
        recognizer: speech,
        scope: () => staffA,
        previewService: gated,
        cart: cart,
      );
      addTearDown(g.dispose);
      await g.start();
      speech.say('bill two coffees and one water');
      await pumpEventQueue();
      gated.answer(0);
      await pumpEventQueue();

      unawaited(g.changeQuantity(0, 3)); // request A
      await pumpEventQueue();
      unawaited(g.removeLine(1)); // request B, made while A is pending
      await pumpEventQueue();
      expect(gated.calls, hasLength(3));
      final b = gated.calls[2].$1;
      expect(b.requestId, g.request!.requestId);
      expect(b.items.map((i) => (i.productQuery, i.quantity)), [('coffee', 3)]);

      gated.answer(2); // B arrives first
      await pumpEventQueue();
      expect(g.preview!.requestId, b.requestId);
      expect(g.preview!.items, hasLength(1));
      gated.answer(1); // A arrives late
      await pumpEventQueue();
      expect(g.preview!.requestId, b.requestId, reason: 'stale answer dropped');
      expect(g.preview!.items, hasLength(1));
      expect(await g.confirmBill(), isTrue);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9900, 3),
      ]);
    });

    test('20/21. after a correction, Confirm Bill adds the CORRECTED server-resolved lines through the existing cart; a double confirm makes one draft', () async {
      await say('bill one sugar and two coffees');
      await v.chooseCandidate(0, v.preview!.issues.single.candidates.first);
      await v.changeQuantity(1, 4);
      expect(v.preview!.isReady, isTrue);
      final first = v.confirmBill();
      expect(await v.confirmBill(), isFalse);
      expect(await first, isTrue);
      expect(service.createCalls, 1);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9907, 1),
        (9900, 4),
      ]);
      expect(service.completeCalls, isEmpty);
      expect(v.canCorrect, isFalse, reason: 'added: no more corrections');
    });
  });

  group('operator Quick Bill screen', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    var checkoutOpened = 0;

    Future<void> open(WidgetTester tester, String spoken) async {
      weightEnabled = true;
      backend = FakeBackend(fakeServer);
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      addTearDown(cart.dispose);
      checkoutOpened = 0;
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
                    openCheckout: (_) async => checkoutOpened++,
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
      speech.say(spoken);
      await tester.pumpAndSettle();
    }

    String textOf(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(Key(key))).data!;

    testWidgets(
      '"Quick Bill" with no ids or developer wording; edit quantity -> new server total; remove line; Confirm Bill -> existing checkout',
      (tester) async {
        await open(tester, 'Jacky, bill two coffees and one water');
        expect(find.text('Quick Bill'), findsOneWidget);
        expect(find.textContaining('developer'), findsNothing);
        expect(find.text('Voice session'), findsNothing);
        expect(find.text('Request'), findsNothing);
        expect(find.text('CREATE_QUICK_BILL'), findsNothing);
        expect(find.byKey(const Key('voice-new-session')), findsNothing);
        final ids = jsonEncode(backend.lastBody);
        for (final id in [
          backend.lastBody['voice_session_id'],
          backend.lastBody['request_id'],
          '9900',
          '9901',
        ]) {
          expect(
            find.textContaining(id as String),
            findsNothing,
            reason: 'id $id shown in $ids',
          );
        }

        // Edit quantity through the existing quantity dialog.
        await tester.tap(find.byKey(const Key('voice-edit-line-0')));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '3');
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(
          textOf(tester, 'voice-preview-line-0-name'),
          '3 × Coffee — Regular',
        );
        expect(
          tester
              .widget<Text>(
                find
                    .descendant(
                      of: find.byKey(const Key('voice-preview-total')),
                      matching: find.byType(Text),
                    )
                    .last,
              )
              .data,
          '32.175',
        );

        await tester.tap(find.byKey(const Key('voice-remove-line-1')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('voice-preview-line-1')), findsNothing);
        expect(backend.requests, hasLength(3));

        await tester.tap(find.byKey(const Key('voice-confirm-bill')));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
        expect(checkoutOpened, 1);
        expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
          (9900, 3),
        ]);
        expect(service.completeCalls, isEmpty);
      },
    );

    testWidgets(
      'candidates are tappable choices on the operator screen — none pre-selected; no Confirm until the new preview is READY',
      (tester) async {
        await open(tester, 'bill one sugar');
        expect(find.byKey(const Key('voice-preview-unclear')), findsOneWidget);
        expect(find.byKey(const Key('voice-confirm-bill')), findsNothing);
        expect(find.byKey(const Key('voice-candidate-0-0')), findsOneWidget);
        expect(find.byKey(const Key('voice-candidate-0-1')), findsOneWidget);
        expect(backend.requests, hasLength(1));

        await tester.tap(find.byKey(const Key('voice-candidate-0-1')));
        await tester.pumpAndSettle();
        expect((backend.lastBody['items'] as List).single, {
          'product_query': 'sugar',
          'quantity': 1,
          'product_variation_id': 9908,
        });
        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);
        expect(
          textOf(tester, 'voice-preview-line-0-name'),
          '1 × Sugar — 500 g pack',
        );
        expect(find.byKey(const Key('voice-confirm-bill')), findsOneWidget);
        expect(
          service.createCalls,
          0,
          reason: 'nothing added until Confirm Bill',
        );
      },
    );

    testWidgets(
      'removing the last line returns to an empty, safe state (Speak Again / Cancel only)',
      (tester) async {
        await open(tester, 'bill two coffees');
        await tester.tap(find.byKey(const Key('voice-remove-line-0')));
        await tester.pumpAndSettle();
        expect(find.text(VoiceController.allRemovedMessage), findsOneWidget);
        expect(find.byKey(const Key('voice-confirm-bill')), findsNothing);
        expect(find.byKey(const Key('voice-speak-again')), findsOneWidget);
        expect(find.byKey(const Key('voice-preview-retry')), findsNothing);
        expect(service.createCalls, 0);
      },
    );
  });

  test('the cart sale model is untouched by previews (sanity: CartSale parse still works)', () {
    expect(CartSale.fromJson(saleJson())!.isDraft, isTrue);
  });
}
