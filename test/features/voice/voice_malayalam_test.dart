// Phase 13H — Malayalam Quick Bill. Malayalam carries numbers, units, the
// bill / correction words and Jacky's replies (ml-IN); the PRODUCT is the
// English name the cashier says, resolved by the existing English catalogue
// on the server. Same QuickBillRequest, same safety rules as English.
import 'dart:async';

import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/state/voice_responses.dart';
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
import 'voice_tts_test.dart' show MockVoiceTtsService;

const ml = VoiceLanguage.malayalam;

void main() {
  group('language', () {
    test('1-5. Malayalam (ml-IN) is supported and selectable; English stays en-US; others stay unavailable', () {
      expect(ml.code, 'ml-IN');
      expect(ml.label, 'Malayalam');
      expect(ml.isSupported, isTrue);
      expect(VoiceLanguage.english.code, 'en-US');
      final s = VoiceSettings();
      expect(s.language, VoiceLanguage.english, reason: 'default');
      expect(s.setLanguage(ml), isTrue);
      expect(s.language, ml);
      expect(s.setLanguage(const VoiceLanguage('hi-IN', 'Hindi')), isFalse);
      expect(s.language, ml);
    });
  });

  group('Malayalam parser', () {
    const parser = RuleBasedIntentParser();
    Future<VoiceIntent> parse(String t) =>
        parser.parse(t, voiceSessionId: 's', requestId: 'r', language: ml);
    List<(num, String, String?, String?)> lines(VoiceIntent i) => [
      for (final x in i.items)
        (x.quantity, x.productQuery, x.variantQuery, x.unit),
    ];

    test('6/7. "രണ്ട് coffee" and bill wording become a quick bill with an ENGLISH product query', () async {
      for (final t in [
        'രണ്ട് coffee',
        'രണ്ട് coffee ബിൽ ചെയ്യൂ',
        'Jacky, രണ്ട് coffee',
        'ജാക്കി, രണ്ട് coffees ബിൽ ചെയ്യൂ',
      ]) {
        final i = await parse(t);
        expect(i.type, VoiceIntentType.createQuickBill, reason: t);
        expect(lines(i), [(2, 'coffee', null, null)], reason: t);
        expect(i.recognizedText, t);
      }
      expect(lines(await parse('ഒരു water')), [(1, 'water', null, null)]);
      expect(lines(await parse('മൂന്ന് water ബിൽ ചെയ്യൂ')), [
        (3, 'water', null, null),
      ]);
      expect(lines(await parse('രണ്ട് large coffee പിന്നെ ഒരു water')), [
        (2, 'coffee', 'large', null),
        (1, 'water', null, null),
      ]);
      expect(lines(await parse('രണ്ട് coffee, ഒരു water')).length, 2);
    });

    test('8. number words 1–10, digits and Malayalam digits', () async {
      const words = {
        'ഒന്ന്': 1, 'രണ്ട്': 2, 'മൂന്ന്': 3, 'നാല്': 4, 'അഞ്ച്': 5, //
        'ആറ്': 6, 'ഏഴ്': 7, 'എട്ട്': 8, 'ഒമ്പത്': 9, 'പത്ത്': 10,
      };
      for (final MapEntry(:key, :value) in words.entries) {
        expect(lines(await parse('$key coffee')), [
          (value, 'coffee', null, null),
        ], reason: key);
      }
      expect(lines(await parse('12 water')).single.$1, 12);
      expect(lines(await parse('൩ water')).single.$1, 3);
    });

    test('9. units (Malayalam and English forms) — no conversion', () async {
      const units = {
        'കിലോ': 'kg', 'ഗ്രാം': 'g', 'ലിറ്റർ': 'l', 'മില്ലി': 'ml', //
        'പാക്ക്': 'pack', 'ബോട്ടിൽ': 'bottle', 'ബോക്സ്': 'box',
      };
      for (final MapEntry(:key, :value) in units.entries) {
        expect(lines(await parse('രണ്ട് $key water')), [
          (2, 'water', null, value),
        ], reason: key);
      }
      expect(lines(await parse('1.255 കിലോ rice')), [
        (1.255, 'rice', null, 'kg'),
      ]);
      expect(lines(await parse('2 kg rice')), [(2, 'rice', null, 'kg')]);
    });

    test('10. unclear or unknown Malayalam never becomes a bill (and is never parsed as English)', () async {
      final ask = await parse('രണ്ട് കോഫി');
      expect(
        ask.type,
        VoiceIntentType.needsClarification,
        reason: 'Malayalam-only product',
      );
      expect(ask.need, ClarificationNeed.product);
      expect(ask.clarification, contains('ഇംഗ്ലീഷിൽ'));
      expect(ask.items, isEmpty);
      expect((await parse('coffee ബിൽ ചെയ്യൂ')).clarification, 'എത്ര coffee?');
      expect((await parse('ബിൽ ചെയ്യൂ')).need, ClarificationNeed.product);
      expect(
        (await parse('1.5 coffee ബിൽ ചെയ്യൂ')).need,
        ClarificationNeed.quantity,
      );
      for (final t in ['ഇന്ന് എന്താണ് സമയം', 'നമസ്കാരം', 'coffee', '']) {
        expect((await parse(t)).type, VoiceIntentType.unknown, reason: t);
      }
      // The same text in an English session is not Malayalam-parsed.
      final en = await parser.parse(
        'രണ്ട് coffee',
        voiceSessionId: 's',
        requestId: 'r',
      );
      expect(en.type, VoiceIntentType.unknown);
    });

    test('corrections: quantity, "ഇത്", remove, add — English product targets, Malayalam verbs', () {
      const p = RuleBasedCorrectionParser();
      (VoiceCorrectionKind, String?, num?, String?)? c(String t) {
        final r = p.parse(t, language: ml);
        return r == null ? null : (r.kind, r.target, r.quantity, r.unit);
      }

      const set = VoiceCorrectionKind.setQuantity;
      const rm = VoiceCorrectionKind.remove;
      expect(c('coffee മൂന്ന് ആക്കൂ'), (set, 'coffee', 3, null));
      expect(c('ഇത് മൂന്ന് ആക്കൂ'), (set, null, 3, null));
      expect(c('coffee എണ്ണം മൂന്ന് ആക്കൂ'), (set, 'coffee', 3, null));
      expect(c('coffeeയുടെ എണ്ണം മൂന്ന് ആക്കൂ'), (set, 'coffee', 3, null));
      expect(c('rice 1.255 കിലോ ആക്കൂ'), (set, 'rice', 1.255, 'kg'));
      expect(c('coffee നീക്കം ചെയ്യൂ'), (rm, 'coffee', null, null));
      expect(c('water നീക്കം ചെയ്യൂ'), (rm, 'water', null, null));
      expect(c('ഇത് നീക്കം ചെയ്യൂ'), (rm, null, null, null));
      final add = p.parse('ഒരു coffee കൂടി ചേർക്കൂ', language: ml)!;
      expect(add.kind, VoiceCorrectionKind.add);
      expect(add.items.map((i) => (i.quantity, i.productQuery)), [
        (1, 'coffee'),
      ]);
      // Old-style chillu encoding (ര + ് + ZWJ) is the same word.
      expect(
        p.parse('ഒരു water കൂടി ചേര്‍ക്കൂ', language: ml)!.kind,
        VoiceCorrectionKind.add,
      );
      for (final t in [
        'കോഫി നീക്കം ചെയ്യൂ',
        'coffee ആക്കൂ',
        'രണ്ട് coffee നീക്കം ചെയ്യൂ',
        'ഒരു കോഫി കൂടി ചേർക്കൂ',
      ]) {
        expect(c(t)?.$1, VoiceCorrectionKind.unclear, reason: t);
      }
      expect(c('നമസ്കാരം'), isNull);
    });
  });

  group('Malayalam Quick Bill (controller)', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late MockVoiceTtsService tts;
    late VoiceSettings settings;
    late VoiceController v;

    VoiceController make({VoiceSettings? s, VoicePreviewService? previews}) =>
        VoiceController(
          permission: FakeMicrophone()..current = VoicePermission.granted,
          recognizer: speech,
          scope: () => staffA,
          previewService: previews ?? ApiVoicePreviewService(backend.client),
          cart: cart,
          tts: tts,
          settings: s ?? settings,
        );

    setUp(() {
      weightEnabled = true;
      backend = FakeBackend(fakeServer);
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      tts = MockVoiceTtsService();
      settings = VoiceSettings()..setLanguage(ml);
      v = make();
    });
    tearDown(() {
      v.dispose();
      cart.dispose();
    });

    Future<void> bill(String t) async {
      await v.start();
      speech.say(t);
      await pumpEventQueue();
    }

    Future<void> correct(String t) async {
      expect(await v.startCorrection(), isTrue, reason: t);
      speech.say(t);
      await pumpEventQueue();
    }

    List<Object?> sent() => backend.lastBody['items'] as List;

    test('12/13/14/27. the same preview flow: unchanged request shape, server-resolved products, Malayalam READY reply in ml-IN', () async {
      await bill('രണ്ട് coffee പിന്നെ ഒരു water ബിൽ ചെയ്യൂ');
      expect(speech.languages.map((l) => l.code), ['ml-IN']);
      expect(v.session!.language, ml);
      expect(backend.lastBody.keys.toSet(), {
        'intent',
        'voice_session_id',
        'request_id',
        'recognized_text',
        'items',
      });
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 2},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(v.preview!.isReady, isTrue);
      expect(v.preview!.items.map((l) => l.productName), ['Coffee', 'Water']);
      expect(
        tts.spoken.last,
        'നിങ്ങളുടെ ബിൽ തയ്യാറാണ്. മൊത്തം 27.45 ആണ്. സ്ഥിരീകരിച്ച ശേഷം മാത്രം ബിൽ പൂർത്തിയാക്കുക.',
      );
      expect(tts.languages.every((l) => l.code == 'ml-IN'), isTrue);
    });

    test('a Malayalam-only product name is asked about locally — nothing is sent to the server', () async {
      await bill('രണ്ട് കോഫി ബിൽ ചെയ്യൂ');
      expect(v.intent!.type, VoiceIntentType.needsClarification);
      expect(backend.requests, isEmpty);
      expect(v.preview, isNull);
    });

    test('15/16/28. an ambiguous product stays NEEDS_CLARIFICATION (Malayalam question with the server\'s names); explicit choice works', () async {
      await bill('ഒരു sugar');
      expect(v.preview!.isReady, isFalse);
      expect(
        tts.spoken.last,
        'എനിക്ക് കുറച്ച് വ്യക്തത വേണം. ഏത് sugar ആണ് വേണ്ടത്: Sugar 1 kg pack അല്ലെങ്കിൽ Sugar 500 g pack?',
      );
      expect(tts.languages.last, ml);
      await v.chooseCandidate(0, v.preview!.issues.single.candidates[1]);
      expect((sent().single as Map)['product_variation_id'], 9908);
      expect(v.preview!.isReady, isTrue);
    });

    test('17/24/26/29. "coffee മൂന്ന് ആക്കൂ": same session, new request id, fresh preview; the old one is not confirmable; replies in ml-IN', () async {
      await bill('രണ്ട് coffee പിന്നെ ഒരു water');
      final session = v.session!.voiceSessionId;
      final firstRequest = v.request!.requestId;
      final old = v.preview!;
      tts.spoken.clear();
      await correct('coffee മൂന്ന് ആക്കൂ');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(backend.lastBody['voice_session_id'], session);
      expect(backend.lastBody['request_id'], isNot(firstRequest));
      expect(speech.languages.map((l) => l.code), ['ml-IN', 'ml-IN']);
      expect(tts.spoken.first, 'ബിൽ പരിശോധിക്കുകയാണ്.');
      expect(tts.languages.every((l) => l == ml), isTrue);
      v.debugSetPreview(old);
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
    });

    test('18/19. "ഇത് മൂന്ന് ആക്കൂ" works with one line; with several it asks in Malayalam and changes nothing', () async {
      await bill('രണ്ട് coffee');
      await correct('ഇത് മൂന്ന് ആക്കൂ');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
      ]);
      await bill('രണ്ട് coffee പിന്നെ ഒരു water');
      final sentBefore = backend.requests.length;
      await correct('ഇത് മൂന്ന് ആക്കൂ');
      expect(backend.requests.length, sentBefore);
      expect(
        v.correctionQuestion,
        startsWith('ഏത് ഇനമാണ്? ഈ ബില്ലിൽ: Coffee (Regular), Water (1 L).'),
      );
      expect(
        tts.spoken.last,
        'ഏത് ഇനമാണ്? Coffee Regular അല്ലെങ്കിൽ Water 1 L?',
      );
      expect(
        v.preview!.isReady,
        isTrue,
        reason: 'bill unchanged, still confirmable',
      );
    });

    test('20/21. remove and add: "coffee നീക്കം ചെയ്യൂ", "ഒരു water കൂടി ചേർക്കൂ", unknown line, last line removed', () async {
      await bill('രണ്ട് coffee');
      await correct('ഒരു coffee കൂടി ചേർക്കൂ');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
      ]);
      await correct('ഒരു water കൂടി ചേർക്കൂ');
      expect(sent(), [
        {'product_query': 'coffee', 'quantity': 3},
        {'product_query': 'water', 'quantity': 1},
      ]);
      await correct('tea നീക്കം ചെയ്യൂ');
      expect(tts.spoken.last, 'ഈ ബില്ലിൽ ആ ഇനം ഇല്ല.');
      expect(v.correctionQuestion, startsWith('ഈ ബില്ലിൽ tea ഇല്ല.'));
      await correct('coffee നീക്കം ചെയ്യൂ');
      expect(sent(), [
        {'product_query': 'water', 'quantity': 1},
      ]);
      await correct('ഇത് നീക്കം ചെയ്യൂ');
      const removed =
          'എല്ലാ ഇനങ്ങളും നീക്കം ചെയ്തു. പുതിയ ബിൽ ആരംഭിക്കാൻ വീണ്ടും പറയുക.';
      expect(v.previewError, removed);
      expect(tts.spoken.last, removed);
      expect(await v.confirmBill(), isFalse);
      expect(service.createCalls, 0);
    });

    test('22/23. PIECE stays whole; WEIGHT keeps exact 3 decimals in kg (no conversion)', () async {
      await bill('രണ്ട് coffee');
      await correct('coffee 1.5 ആക്കൂ');
      expect(
        backend.requests,
        hasLength(1),
        reason: '1.5 coffee refused, nothing sent',
      );
      expect(v.correctionQuestion, isNotNull);
      await bill('1.25 കിലോ rice');
      await correct('rice 1.255 കിലോ ആക്കൂ');
      expect(sent(), [
        {'product_query': 'rice', 'quantity': 1.255, 'unit': 'kg'},
      ]);
      expect(backend.requests.last.body, contains('"quantity":1.255,'));
    });

    test('25. a late answer to an older Malayalam correction is discarded and not spoken', () async {
      final gated = GatedPreviews();
      final g = make(previews: gated);
      addTearDown(g.dispose);
      await g.start();
      speech.say('രണ്ട് coffee പിന്നെ ഒരു water');
      await pumpEventQueue();
      gated.answer(0);
      await pumpEventQueue();
      await g.startCorrection();
      speech.say('coffee മൂന്ന് ആക്കൂ'); // A
      await pumpEventQueue();
      unawaited(g.removeLine(1)); // B
      await pumpEventQueue();
      final b = gated.calls[2].$1;
      gated.answer(2);
      await pumpEventQueue();
      final spoken = List.of(tts.spoken);
      gated.answer(1); // A, late
      await pumpEventQueue();
      expect(g.preview!.requestId, b.requestId);
      expect(tts.spoken, spoken);
    });

    test('30/31/32. no Malayalam TTS voice: Quick Bill still works; Confirm Bill makes ONE draft; speech makes no cart/sale activity', () async {
      tts.failWith = StateError('No Malayalam voice on this device');
      await bill('രണ്ട് coffee');
      expect(v.preview!.isReady, isTrue);
      expect(v.error, isNull);
      expect(service.createCalls, 0, reason: 'nothing from speaking');
      final first = v.confirmBill();
      expect(await v.confirmBill(), isFalse);
      expect(await first, isTrue);
      expect(service.createCalls, 1);
      expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
        (9900, 2),
      ]);
      expect(service.completeCalls, isEmpty);
    });

    test('33. changing the language does not change an open session; the next bill uses the new language', () async {
      await bill('രണ്ട് coffee');
      final session = v.session!.voiceSessionId;
      expect(v.selectLanguage(VoiceLanguage.english), isTrue);
      expect(v.session!.language, ml);
      await correct('coffee മൂന്ന് ആക്കൂ'); // still Malayalam
      expect(v.session!.voiceSessionId, session);
      expect((sent().single as Map)['quantity'], 3);
      expect(speech.languages.last, ml);
      await bill('bill two waters');
      expect(v.session!.voiceSessionId, isNot(session));
      expect(v.session!.language, VoiceLanguage.english);
      expect(speech.languages.last.code, 'en-US');
      expect(tts.spoken.last, startsWith('Your bill is ready.'));
    });

    test('Malayalam recognition unavailable on the device: a safe error, no fallback to English, no bill or cart change', () async {
      await v.start();
      speech.fail('error_language_not_supported');
      await pumpEventQueue();
      expect(v.state, VoiceState.error);
      expect(
        v.error,
        'Speech recognition in Malayalam is not available on this device.',
      );
      expect(speech.listenCalls, 1);
      expect(speech.languages.single, ml);
      expect(backend.requests, isEmpty);
      expect(service.createCalls, 0);
    });

    test(
      'responses: Malayalam provider for ml-IN; English provider unchanged',
      () {
        expect(VoiceResponses.forLanguage(ml), isA<MalayalamVoiceResponses>());
        expect(
          VoiceResponses.forLanguage(VoiceLanguage.english),
          isA<EnglishVoiceResponses>(),
        );
        expect(
          const MalayalamVoiceResponses().checking(),
          'ബിൽ പരിശോധിക്കുകയാണ്.',
        );
        expect(
          const MalayalamVoiceResponses().preview(null),
          'ബിൽ പരിശോധിക്കാൻ കഴിഞ്ഞില്ല. ദയവായി വീണ്ടും ശ്രമിക്കുക.',
        );
        expect(const EnglishVoiceResponses().checking(), 'Checking the bill.');
      },
    );
  });

  testWidgets(
    'screen: pick Malayalam (label, no code); an open Malayalam bill keeps its language when English is picked',
    (tester) async {
      final backend = FakeBackend(fakeServer);
      final speech = FakeRecognizer();
      final cart = CartController(growingCart());
      addTearDown(cart.dispose);
      final settings = VoiceSettings();
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ChangeNotifierProvider<CartController>.value(
          value: cart,
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: TextButton(
                  onPressed: () => startVoiceBill(
                    ctx,
                    openCheckout: (_) async {},
                    permission: FakeMicrophone()
                      ..current = VoicePermission.granted,
                    recognizer: speech,
                    previewService: ApiVoicePreviewService(backend.client),
                    scope: () => staffA,
                    tts: MockVoiceTtsService(),
                    settings: settings,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Language: English'), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-language-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Malayalam').last);
      await tester.pumpAndSettle();
      expect(settings.language, ml);
      expect(find.text('Language: Malayalam'), findsOneWidget);
      expect(find.textContaining('ml-IN'), findsNothing);

      await tester.tap(find.byKey(const Key('voice-start')));
      await tester.pump();
      speech.say('രണ്ട് coffee');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);

      await tester.tap(find.byKey(const Key('voice-language-picker')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English').last);
      await tester.pumpAndSettle();
      expect(
        find.text('Language: Malayalam'),
        findsOneWidget,
        reason: 'open bill',
      );
      expect(find.text('The next bill will use English.'), findsOneWidget);
    },
  );

  testWidgets('developer screen shows "Malayalam (ml-IN)"', (tester) async {
    final dev = VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: FakeRecognizer(),
      scope: () => staffA,
      settings: VoiceSettings()..setLanguage(ml),
    );
    addTearDown(dev.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChangeNotifierProvider<VoiceController>.value(
            value: dev,
            child: const VoiceTestView(),
          ),
        ),
      ),
    );
    expect(find.text('Malayalam (ml-IN)'), findsOneWidget);
  });
}
