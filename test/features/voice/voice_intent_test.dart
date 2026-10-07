// Phase 13B — recognized voice text -> structured POS intent (preview only).
// The rule-based parser is tested as pure functions; the controller and the
// developer screen with the Phase 13A fakes (no microphone). Nothing here is
// billed: the intent carries only what was said, never an id, price or stock.
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;

const parser = RuleBasedIntentParser();
Future<VoiceIntent> parse(String text) =>
    parser.parse(text, voiceSessionId: 'session-1', requestId: 'request-1');

List<Map<String, dynamic>> itemsOf(VoiceIntent i) => [
  for (final x in i.items) x.toJson(),
];

class ThrowingParser implements VoiceIntentParser {
  @override
  Future<VoiceIntent> parse(
    String recognizedText, {
    required String voiceSessionId,
    required String requestId,
    VoiceLanguage language = VoiceLanguage.english,
  }) => throw StateError('provider down');
}

void main() {
  group('parser: CREATE_QUICK_BILL', () {
    test('1. "Bill two coffees"', () async {
      final i = await parse('Bill two coffees');
      expect(i.type, VoiceIntentType.createQuickBill);
      expect(itemsOf(i), [
        {'spokenText': 'two coffees', 'quantity': 2, 'productQuery': 'coffee'},
      ]);
    });

    test('2. "Bill two large coffees" (variant)', () async {
      final i = await parse('Bill two large coffees');
      expect(itemsOf(i), [
        {
          'spokenText': 'two large coffees',
          'quantity': 2,
          'productQuery': 'coffee',
          'variantQuery': 'large',
        },
      ]);
    });

    test('3. several items: "Bill two large coffees and three waters" (the spec example)', () async {
      final i = await parse('Bill two large coffees and three waters');
      expect(i.toJson(), {
        'intent': 'CREATE_QUICK_BILL',
        'voiceSessionId': 'session-1',
        'requestId': 'request-1',
        'recognizedText': 'Bill two large coffees and three waters',
        'items': [
          {
            'spokenText': 'two large coffees',
            'quantity': 2,
            'productQuery': 'coffee',
            'variantQuery': 'large',
          },
          {
            'spokenText': 'three waters',
            'quantity': 3,
            'productQuery': 'water',
          },
        ],
      });
      final j = await parse('quick bill 2 coffee, 1 tea & 3 samosas');
      expect(j.items.map((x) => '${x.quantity}x${x.productQuery}'), [
        '2xcoffee',
        '1xtea',
        '3xsamosa',
      ]);
    });

    test('4. numbers: spoken words, digits, compound tens, "a", a unit with a decimal; a plain "two coffees" without "bill"', () async {
      expect((await parse('two coffees')).items.single.quantity, 2);
      expect(
        (await parse('two coffees')).type,
        VoiceIntentType.createQuickBill,
      );
      expect((await parse('Bill 12 waters')).items.single.quantity, 12);
      expect(
        (await parse('Bill twenty five samosas')).items.single.quantity,
        25,
      );
      expect((await parse('Bill a coffee')).items.single.quantity, 1);
      final kg = (await parse('Bill 1.5 kg rice')).items.single;
      expect((kg.quantity, kg.unit, kg.productQuery), (1.5, 'kg', 'rice'));
      expect(
        (await parse('Bill two coffees.')).type,
        VoiceIntentType.createQuickBill,
        reason: 'punctuation from the recognizer',
      );
    });
  });

  group('parser: NEEDS_CLARIFICATION (never a guess)', () {
    test('5. quantity missing: "Bill some coffee", "Bill coffee"; an impossible quantity', () async {
      for (final t in ['Bill some coffee', 'Bill coffee']) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.needsClarification, reason: t);
        expect(i.need, ClarificationNeed.quantity);
        expect(i.clarification, 'How many coffee?');
        expect(i.items, isEmpty);
      }
      expect((await parse('Bill 0 coffee')).need, ClarificationNeed.quantity);
      expect(
        (await parse('Bill 1.5 coffee')).need,
        ClarificationNeed.quantity,
        reason: 'a fraction of a piece needs a unit',
      );
    });

    test('6. product missing: "Bill two", "Bill something", "Bill two large", "Bill"', () async {
      for (final t in [
        'Bill two',
        'Bill something',
        'Bill two large',
        'Bill',
      ]) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.needsClarification, reason: t);
        expect(i.need, ClarificationNeed.product, reason: t);
        expect(i.clarification, contains('Which product?'));
      }
    });

    test('a clear item next to an unclear one: the clear one is kept, the question is about the unclear one', () async {
      final i = await parse('Bill two coffees and some water');
      expect(i.type, VoiceIntentType.needsClarification);
      expect(i.items.single.productQuery, 'coffee');
      expect(i.clarification, 'How many water?');
    });
  });

  group('parser: UNKNOWN', () {
    test('7. unrelated speech and loose words are not POS commands', () async {
      for (final t in [
        'what time is it',
        'hello there',
        'a lot of noise',
        'refund the last sale',
        'coffee',
      ]) {
        expect((await parse(t)).type, VoiceIntentType.unknown, reason: t);
      }
    });

    test(
      '12. empty / invalid recognition results are handled safely',
      () async {
        for (final t in ['', '   ', '!!!', '...']) {
          final i = await parse(t);
          expect(i.type, VoiceIntentType.unknown, reason: '"$t"');
          expect(i.items, isEmpty);
        }
      },
    );
  });

  test('8/9/10. every intent keeps its voiceSessionId and requestId; it never carries a product id, price, stock or payment', () async {
    for (final t in [
      'Bill two large coffees and three waters',
      'Bill two',
      'what time is it',
    ]) {
      final i = await parser.parse(t, voiceSessionId: 'S-42', requestId: 'R-7');
      expect((i.voiceSessionId, i.requestId), ('S-42', 'R-7'));
      final json = i.toJson();
      expect(json['voiceSessionId'], 'S-42');
      expect(json['requestId'], 'R-7');
      final keys = {
        ...json.keys,
        for (final item in json['items'] as List) ...(item as Map).keys,
      };
      for (final forbidden in [
        'productId',
        'product_id',
        'variationId',
        'price',
        'unitPrice',
        'total',
        'stock',
        'payment',
        'paymentStatus',
        'amount',
      ]) {
        expect(keys, isNot(contains(forbidden)), reason: forbidden);
      }
    }
  });

  group('controller (Phase 13A lifecycle + 13B intent)', () {
    late FakeMicrophone mic;
    late FakeRecognizer speech;
    late VoiceController voice;
    setUp(() {
      mic = FakeMicrophone()..current = VoicePermission.granted;
      speech = FakeRecognizer();
      voice = VoiceController(
        permission: mic,
        recognizer: speech,
        scope: () => staffA,
      );
    });
    tearDown(() => voice.dispose());

    test('11. lifecycle unchanged; recognized text becomes an intent tied to THIS session and request', () async {
      expect(await voice.start(), isTrue);
      expect(voice.intent, isNull);
      await voice.stop();
      speech.say('Bill two large coffees and three waters');
      expect(voice.state, VoiceState.recognized);
      await pumpEventQueue();
      final intent = voice.intent!;
      expect(intent.type, VoiceIntentType.createQuickBill);
      expect(intent.voiceSessionId, voice.session!.voiceSessionId);
      expect(intent.requestId, voice.request!.requestId);
      expect(intent.items.length, 2);
      // A new request starts without the previous intent; cancel clears it.
      await voice.start();
      expect(voice.intent, isNull);
      await voice.cancel();
      expect(voice.intent, isNull);
      expect(voice.state, VoiceState.idle);
    });

    test('12. a silent / empty result stays an error (no intent); a failing interpreter yields UNKNOWN, never an exception', () async {
      await voice.start();
      speech.say('');
      await pumpEventQueue();
      expect(voice.state, VoiceState.error);
      expect(voice.intent, isNull);

      final v2 = VoiceController(
        permission: mic,
        recognizer: speech,
        scope: () => staffA,
        intentParser: ThrowingParser(),
      );
      addTearDown(v2.dispose);
      await v2.start();
      speech.say('Bill two coffees');
      await pumpEventQueue();
      expect(v2.state, VoiceState.recognized);
      expect(v2.intent!.type, VoiceIntentType.unknown);
      expect(v2.intent!.requestId, v2.request!.requestId);
    });
  });

  group('preview on the developer screen', () {
    Future<VoiceController> showWith(WidgetTester tester, String spoken) async {
      final mic = FakeMicrophone()..current = VoicePermission.granted;
      final speech = FakeRecognizer();
      final voice = VoiceController(
        permission: mic,
        recognizer: speech,
        scope: () => staffA,
      );
      addTearDown(voice.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<VoiceController>.value(
              value: voice,
              child: const VoiceTestView(),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('voice-start')));
      await tester.pump();
      speech.say(spoken);
      await tester.pumpAndSettle();
      return voice;
    }

    testWidgets(
      'CREATE_QUICK_BILL: recognized text, intent and items (with variant) — no prices',
      (tester) async {
        await showWith(tester, 'Bill two large coffees and three waters');
        expect(
          find.text('"Bill two large coffees and three waters"'),
          findsOneWidget,
        );
        expect(find.text('CREATE_QUICK_BILL'), findsOneWidget);
        expect(find.text('2 × coffee'), findsOneWidget);
        expect(find.text('Variant: large'), findsOneWidget);
        expect(find.text('3 × water'), findsOneWidget);
        expect(find.textContaining('₹'), findsNothing);
        expect(find.textContaining('Total'), findsNothing);
      },
    );

    testWidgets(
      'NEEDS_CLARIFICATION shows the question; UNKNOWN says no POS command was found',
      (tester) async {
        await showWith(tester, 'Bill two');
        expect(find.text('NEEDS_CLARIFICATION'), findsOneWidget);
        expect(find.text('Which product?'), findsOneWidget);
        await showWith(tester, 'what time is it');
        expect(find.text('UNKNOWN'), findsOneWidget);
        expect(find.text("I couldn't identify a POS command."), findsOneWidget);
      },
    );
  });
}
