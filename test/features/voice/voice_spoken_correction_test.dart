// Phase 13E — spoken Quick Bill corrections ("make it three", "remove the
// coffee", "add one more coffee") on the operator screen. A correction is
// matched against the bill's own lines (never guessed), applied through the
// Phase 13D correction path (same voice session, NEW request id, fresh
// server preview) and leaves the bill untouched when it is not clear.
import 'dart:async';

import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart'
    show GatedPreviews, fakeServer, weightEnabled;

void main() {
  group('correction parser', () {
    const p = RuleBasedCorrectionParser();
    (VoiceCorrectionKind, String?, num?, String?)? read(String t) {
      final c = p.parse(t);
      return c == null ? null : (c.kind, c.target, c.quantity, c.unit);
    }

    test('quantity changes', () {
      const set = VoiceCorrectionKind.setQuantity;
      expect(read('make it three'), (set, null, 3, null));
      expect(read('Make that 2'), (set, null, 2, null));
      expect(read('change coffee to 3'), (set, 'coffee', 3, null));
      expect(read('make coffee 3'), (set, 'coffee', 3, null));
      expect(read('make the water 2'), (set, 'water', 2, null));
      expect(read('change water quantity to 2'), (set, 'water', 2, null));
      expect(read('change the coffees to twenty five'), (
        set,
        'coffee',
        25,
        null,
      ));
      expect(read('make coffee 1.250 kg'), (set, 'coffee', 1.25, 'kg'));
      expect(read('Jacky, make it three'), (set, null, 3, null));
    });

    test('remove and add', () {
      const rm = VoiceCorrectionKind.remove;
      expect(read('remove coffee'), (rm, 'coffee', null, null));
      expect(read('remove the coffee'), (rm, 'coffee', null, null));
      expect(read('Remove water.'), (rm, 'water', null, null));
      expect(read('remove it'), (rm, null, null, null));
      final more = p.parse('add one more coffee')!;
      expect(more.kind, VoiceCorrectionKind.add);
      expect(
        [for (final i in more.items) i.toJson()],
        [
          {'spokenText': 'one coffee', 'quantity': 1, 'productQuery': 'coffee'},
        ],
      );
      expect(
        p
            .parse('add one water and two large teas')!
            .items
            .map((i) => (i.quantity, i.productQuery, i.variantQuery)),
        [(1, 'water', null), (2, 'tea', 'large')],
      );
    });

    test('unclear corrections ask; other speech is not a correction', () {
      for (final t in [
        'make it',
        'make it lots',
        'change coffee to',
        'make it 1.2345',
        'remove',
        'remove two coffees',
        'add coffee',
        'add',
      ]) {
        expect(p.parse(t)?.kind, VoiceCorrectionKind.unclear, reason: t);
        expect(p.parse(t)?.question, isNotNull, reason: t);
      }
      for (final t in ['bill two coffees', 'hello', 'Jacky', '']) {
        expect(p.parse(t), isNull, reason: t);
      }
    });
  });

  group('spoken corrections (controller)', () {
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

    Future<void> bill(String t) async {
      await v.start();
      speech.say(t);
      await pumpEventQueue();
      expect(v.previewState, VoicePreviewState.loaded, reason: t);
    }

    Future<void> correct(String t) async {
      expect(await v.startCorrection(), isTrue, reason: t);
      speech.say(t);
      await pumpEventQueue();
    }

    List<Object?> sent() => backend.lastBody['items'] as List;

    test('"make it three" with ONE line: same session, NEW request id, fresh server total; the old preview is never confirmable', () async {
      await bill('bill two coffees');
      final session = v.session!.voiceSessionId;
      final firstRequest = v.request!.requestId;
      final old = v.preview!;

      await correct('make it three');
      expect(backend.requests, hasLength(2));
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
      ]);
      expect(backend.lastBody['voice_session_id'], session);
      expect(backend.lastBody['request_id'], isNot(firstRequest));
      expect(v.session!.voiceSessionId, session);
      expect(v.preview!.requestId, v.request!.requestId);
      expect(v.preview!.total, 14.175);

      v.debugSetPreview(old);
      expect(await v.confirmBill(), isFalse);
      expect(v.previewError, VoiceController.staleBillMessage);
      expect(service.createCalls, 0);
    });

    test('"make it three" with SEVERAL lines asks which (listing them) and changes nothing — the bill stays confirmable', () async {
      await bill('bill two coffees and one water');
      final before = v.preview;
      final request = v.request!.requestId;
      await correct('make it three');
      expect(backend.requests, hasLength(1), reason: 'nothing sent');
      expect(
        v.correctionQuestion,
        'Which item? This bill has Coffee (Regular), Water (1 L). '
        'Say for example "make the coffee three".',
      );
      expect(identical(v.preview, before), isTrue);
      expect(v.request!.requestId, request);
      expect(await v.confirmBill(), isTrue);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9900, 2),
        (9901, 1),
      ]);
    });

    test(
      'a name that fits two lines, or none, asks and changes nothing',
      () async {
        await bill('bill two coffees and one large coffee');
        await correct('make coffee 3');
        expect(v.correctionQuestion, startsWith('Which coffee?'));
        await correct('remove the tea');
        expect(
          v.correctionQuestion,
          startsWith('There is no tea on this bill.'),
        );
        expect(backend.requests, hasLength(1));
      },
    );

    test(
      '"change coffee to 3" / "make the water 2" target the named line only',
      () async {
        await bill('bill two coffees and one water');
        await correct('change coffee to 3');
        expect(sent(), [
          {'product_query': 'coffee', 'quantity': 3},
          {'product_query': 'water', 'quantity': 1},
        ]);
        await correct('make the water 2');
        expect(sent(), [
          {'product_query': 'coffee', 'quantity': 3},
          {'product_query': 'water', 'quantity': 2},
        ]);
        expect(v.preview!.isReady, isTrue);
        expect(v.correctionQuestion, isNull);
      },
    );

    test('"remove coffee" behaves like the Remove button; removing the last line leaves the bill empty', () async {
      await bill('bill two coffees and one water');
      await correct('remove coffee');
      expect(sent(), [
        {'product_query': 'water', 'quantity': 1},
      ]);
      final count = backend.requests.length;
      await correct('remove it');
      expect(backend.requests.length, count, reason: 'empty bill not sent');
      expect(v.preview, isNull);
      expect(v.previewError, VoiceController.allRemovedMessage);
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
    });

    test('"add one more coffee" adds to the coffee line; "add one water" adds a NEW line resolved by the server', () async {
      await bill('bill two coffees');
      await correct('add one more coffee');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
      ]);
      await correct('add one water');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(v.preview!.items.map((l) => l.productName), ['Coffee', 'Water']);
      // An ambiguous new product stays a clarification (never chosen).
      await correct('add one sugar');
      expect(v.preview!.isReady, isFalse);
      expect(v.preview!.issues.single.code, 'MULTIPLE_PRODUCT_MATCHES');
      expect(await v.confirmBill(), isFalse);
    });

    test('PIECE stays whole: "make coffee 1.5" is refused with the existing rule, nothing sent', () async {
      await bill('bill two coffees');
      await correct('make coffee 1.5');
      expect(v.correctionQuestion, isNotNull);
      expect(backend.requests, hasLength(1));
      expect(v.preview!.items.single.quantity, 2);
    });

    test('WEIGHT keeps exact 3 decimals ("make it 1.255 kg"); 4 decimals are not accepted', () async {
      await bill('bill 1.25 kg rice');
      await correct('make it 1.255 kg');
      expect(sent(), [
        {'product_query': 'rice', 'quantity': 1.255, 'unit': 'kg'},
      ]);
      expect(backend.requests.last.body, contains('"quantity":1.255,'));
      await correct('make it 1.2555 kg');
      expect(v.correctionQuestion, isNotNull);
      expect(backend.requests, hasLength(2));
    });

    test('an explicitly chosen candidate is kept when its quantity is corrected by voice', () async {
      await bill('bill one sugar');
      await v.chooseCandidate(0, v.preview!.issues.single.candidates[1]);
      await correct('make the sugar 3');
      expect(sent(), [
        {'product_query': 'sugar', 'quantity': 3, 'product_variation_id': 9908},
      ]);
      expect(v.preview!.items.single.variantName, '500 g pack');
    });

    test('Confirm Bill is impossible while a correction is being listened to; cancelling it keeps the bill (one draft on confirm)', () async {
      await bill('bill two coffees');
      expect(await v.startCorrection(), isTrue);
      expect(v.isCorrecting, isTrue);
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
      await v.cancel();
      expect(v.isCorrecting, isFalse);
      expect(v.preview!.isReady, isTrue);
      final first = v.confirmBill();
      expect(await v.confirmBill(), isFalse);
      expect(await first, isTrue);
      expect(service.createCalls, 1);
    });

    test('nothing heard, or speech that is not a correction, leaves the bill unchanged and confirmable', () async {
      await bill('bill two coffees');
      expect(await v.startCorrection(), isTrue);
      speech.say('');
      await pumpEventQueue();
      expect(v.isCorrecting, isFalse);
      expect(v.preview!.isReady, isTrue);
      await correct('what time is it');
      expect(v.correctionQuestion, startsWith("I didn't understand that."));
      expect(backend.requests, hasLength(1));
      expect(await v.confirmBill(), isTrue);
    });

    test('a late answer to an older spoken correction is discarded; after a correction a double confirm makes one draft', () async {
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

      await g.startCorrection();
      speech.say('make the coffee 3'); // request A
      await pumpEventQueue();
      expect(gated.calls, hasLength(2));
      expect(g.previewState, VoicePreviewState.loading);
      expect(await g.confirmBill(), isFalse);
      unawaited(g.removeLine(1)); // request B while A is pending
      await pumpEventQueue();
      final b = gated.calls[2].$1;

      gated.answer(2);
      await pumpEventQueue();
      gated.answer(1); // A arrives late
      await pumpEventQueue();
      expect(g.preview!.requestId, b.requestId);
      expect(g.preview!.items.map((l) => (l.productName, l.quantity)), [
        ('Coffee', 3),
      ]);
      final first = g.confirmBill();
      expect(await g.confirmBill(), isFalse);
      expect(await first, isTrue);
      expect(service.createCalls, 1);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9900, 3),
      ]);
    });
  });

  testWidgets(
    'operator screen: "Speak correction" while the bill is shown; Confirm is off while listening; the corrected bill then goes to the existing checkout',
    (tester) async {
      weightEnabled = true;
      final backend = FakeBackend(fakeServer);
      final speech = FakeRecognizer();
      final service = growingCart();
      final cart = CartController(service);
      addTearDown(cart.dispose);
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
      speech.say('Jacky, bill two coffees and one water');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('voice-speak-correction')));
      await tester.pump();
      expect(
        find.byKey(const Key('voice-correction-listening')),
        findsOneWidget,
      );
      final confirm = tester.widget<FilledButton>(
        find.ancestor(
          of: find.text('Confirm Bill'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(confirm.onPressed, isNull, reason: 'off while listening');

      speech.say('make the water 2');
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<Text>(find.byKey(const Key('voice-preview-line-1-name')))
            .data,
        '2 × Water — 1 L',
      );
      expect(
        find.textContaining(backend.lastBody['request_id'] as String),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('voice-speak-correction')));
      await tester.pump();
      speech.say('make it three');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('voice-correction-question')),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const Key('voice-confirm-bill')));
      await tester.pumpAndSettle();
      expect(checkout, 1);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9900, 2),
        (9901, 2),
      ]);
      expect(service.completeCalls, isEmpty);
    },
  );
}
