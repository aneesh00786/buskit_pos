// Phase 3B — staff-to-customer translation, strictly separate from billing.
// Automated tests with FAKE recognition and FAKE translation providers: they
// do not prove microphone recognition or translation quality on a device.
import 'dart:async';
import 'dart:io';

import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/translation/translation_controller.dart';
import 'package:buskit_pos/features/voice/translation/translation_service.dart';
import 'package:buskit_pos/features/voice/translation/translation_view.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;
import 'voice_phase2_orders_test.dart' show FakeOrders;
import 'voice_phase3a_multilingual_test.dart' show LocaleRecognizer;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

const en = VoiceLanguage.english;
const ml = VoiceLanguage.malayalam;

/// A fake provider: English <-> Malayalam by a small phrase book; scripted
/// failures; optionally held until released.
class FakeTranslator implements TranslationService {
  final requests = <TranslationRequest>[];
  Object? throwWith;
  String? answerOverride;
  Completer<void>? hold;
  Set<(VoiceLanguage, VoiceLanguage)> pairs = {(en, ml), (ml, en)};

  @override
  String? get providerName => 'Fake';

  @override
  bool supports(VoiceLanguage s, VoiceLanguage t) => pairs.contains((s, t));

  /// Phase 3B.1: what is switched on follows [pairs].
  @override
  Future<TranslationSupport> loadSupport() async => TranslationSupport(
    available: pairs.isNotEmpty,
    sources: {for (final p in pairs) p.$1},
    targets: {for (final p in pairs) p.$2},
  );

  @override
  Future<TranslationResult> translate(TranslationRequest r) async {
    requests.add(r);
    if (hold != null) await hold!.future;
    if (throwWith != null) throw throwWith!;
    if (answerOverride != null) {
      return TranslationResult.translated(answerOverride!);
    }
    return TranslationResult.translated('[${r.target.code}] ${r.text}');
  }
}

TranslationController make({
  FakeTranslator? service,
  TranslationService? anyService,
  SpeechRecognizer? recognizer,
  VoicePermission permission = VoicePermission.granted,
  MockVoiceTtsService? tts,
  Duration timeout = const Duration(seconds: 15),
}) => TranslationController(
  permission: FakeMicrophone()..current = permission,
  recognizer: recognizer ?? FakeRecognizer(),
  service: anyService ?? service ?? FakeTranslator(),
  tts: tts,
  timeout: timeout,
);

void main() {
  group('service contract', () {
    test('requests: empty / whitespace and same-language pairs are refused before any provider call', () {
      expect(
        const TranslationRequest(source: en, target: ml, text: '  \n ').problem,
        TranslationErrorKind.emptyText,
      );
      expect(
        const TranslationRequest(source: en, target: en, text: 'hello').problem,
        TranslationErrorKind.sameLanguage,
      );
      expect(
        const TranslationRequest(source: en, target: ml, text: 'hello').problem,
        isNull,
      );
    });

    test('the default (no approved provider) is plainly unavailable and never echoes the text as a translation', () async {
      const s = UnavailableTranslationService();
      expect(s.providerName, isNull);
      expect(s.supports(en, ml), isFalse);
      final r = await s.translate(
        const TranslationRequest(source: en, target: ml, text: 'two coffees'),
      );
      expect(r.isTranslated, isFalse);
      expect(r.text, isNull);
      expect(r.error, TranslationErrorKind.unavailable);
    });

    test('languages come from the central configuration (adding one there offers it here)', () {
      expect(make().languages, VoiceLanguage.supported);
    });
  });

  group('staff -> customer', () {
    test('heard text is shown for review; translated only when asked; the source is never replaced', () async {
      final speech = FakeRecognizer();
      final t = FakeTranslator();
      final c = make(service: t, recognizer: speech);
      addTearDown(c.dispose);
      expect(
        await c.startListening(TranslationDirection.staffToCustomer),
        isTrue,
      );
      expect(speech.languages.last, en);
      speech.say('Do you want it with sugar?');
      await pumpEventQueue();
      expect(c.step, TranslationStep.recognized);
      expect(c.sourceText, 'Do you want it with sugar?');
      expect(t.requests, isEmpty, reason: 'nothing is translated until asked');
      await c.translate();
      expect(t.requests.single.text, 'Do you want it with sugar?');
      expect((t.requests.single.source, t.requests.single.target), (en, ml));
      expect(c.translatedText, '[ml-IN] Do you want it with sugar?');
      expect(c.sourceText, 'Do you want it with sugar?');
    });

    test('nothing heard: an error, and nothing to translate', () async {
      final speech = FakeRecognizer();
      final t = FakeTranslator();
      final c = make(service: t, recognizer: speech);
      addTearDown(c.dispose);
      await c.startListening(TranslationDirection.staffToCustomer);
      speech.say('   ');
      await pumpEventQueue();
      expect(c.errorKind, TranslationErrorKind.emptyText);
      await c.translate();
      expect(t.requests, isEmpty);
    });

    test('correcting the text removes the old translation; translate again uses the corrected text', () async {
      final t = FakeTranslator();
      final c = make(service: t);
      addTearDown(c.dispose);
      c.setSourceText('one tea');
      await c.translate();
      expect(c.translatedText, isNotNull);
      c.setSourceText('one tea, no sugar');
      expect(
        c.translatedText,
        isNull,
        reason: 'it no longer matches the source',
      );
      await c.translate();
      expect(t.requests.last.text, 'one tea, no sugar');
    });

    test('unsupported pair / no provider: clear errors, the source kept, no translation shown', () async {
      // Phase 3B.1: only English -> Malayalam switched on; the customer's
      // Malayalam reply (ml -> en) is not, and is refused before the provider.
      final speech = FakeRecognizer();
      final t = FakeTranslator()..pairs = {(en, ml)};
      final c = make(service: t, recognizer: speech);
      addTearDown(c.dispose);
      await c.startListening(TranslationDirection.customerToStaff);
      speech.say('hello');
      await pumpEventQueue();
      await c.translate();
      expect(c.errorKind, TranslationErrorKind.unsupportedPair);
      expect(c.translatedText, isNull);
      expect(c.sourceText, 'hello');
      expect(t.requests, isEmpty);
      final none = make(anyService: const UnavailableTranslationService())
        ..setSourceText('hello');
      addTearDown(none.dispose);
      await none.translate();
      // Phase 3B.1: with nothing set up only English / English remains, and
      // that is refused as the same language (never "translated").
      expect(none.providerAvailable, isFalse);
      expect((none.staffLanguage, none.customerLanguage), (en, en));
      expect(none.errorKind, TranslationErrorKind.sameLanguage);
      expect(none.translatedText, isNull);
      expect(none.sourceText, 'hello');
    });

    test('timeout, network error and an empty (malformed) answer: no translation, source kept for retry', () async {
      final slow = FakeTranslator()..hold = Completer<void>();
      final c1 = make(service: slow, timeout: const Duration(milliseconds: 30))
        ..setSourceText('hello');
      addTearDown(c1.dispose);
      await c1.translate();
      expect(c1.errorKind, TranslationErrorKind.timeout);
      expect(c1.sourceText, 'hello');
      final down = FakeTranslator()..throwWith = const SocketException('down');
      final c2 = make(service: down)..setSourceText('hello');
      addTearDown(c2.dispose);
      await c2.translate();
      expect(c2.errorKind, TranslationErrorKind.network);
      final bad = FakeTranslator()..answerOverride = '   ';
      final c3 = make(service: bad)..setSourceText('hello');
      addTearDown(c3.dispose);
      await c3.translate();
      expect(c3.errorKind, TranslationErrorKind.malformed);
      expect(c3.translatedText, isNull);
    });

    test('cancel during translation, or a language change, drops the late answer and keeps the source', () async {
      final t = FakeTranslator()..hold = Completer<void>();
      final c = make(service: t)..setSourceText('hello');
      addTearDown(c.dispose);
      final pending = c.translate();
      await pumpEventQueue();
      expect(c.step, TranslationStep.translating);
      await c.cancel();
      t.hold!.complete();
      await pending;
      expect(c.translatedText, isNull);
      expect(c.sourceText, 'hello');
      expect(c.step, TranslationStep.recognized);

      t.hold = Completer<void>();
      final again = c.translate();
      await pumpEventQueue();
      c.setLanguages(customer: en, staff: ml);
      t.hold!.complete();
      await again;
      expect(
        c.translatedText,
        isNull,
        reason: 'answer for the old pair dropped',
      );
      expect((c.sourceLanguage, c.targetLanguage), (ml, en));
      expect(c.sourceText, 'hello');
    });

    test(
      'clear drops every text; leaving the screen (dispose) drops it too',
      () async {
        final c = make()..setSourceText('hello');
        await c.translate();
        await c.clear();
        expect((c.sourceText, c.translatedText, c.error), ('', null, null));
        c.setSourceText('again');
        c.dispose();
        expect(c.sourceText, '');
      },
    );

    test('cancel while listening drops the partial text', () async {
      final speech = FakeRecognizer();
      final c = make(recognizer: speech);
      addTearDown(c.dispose);
      await c.startListening(TranslationDirection.staffToCustomer);
      speech.say('do you', isFinal: false);
      await pumpEventQueue();
      await c.cancel();
      expect(c.sourceText, '');
      expect(c.step, TranslationStep.idle);
    });
  });

  group('customer reply and devices', () {
    test('a customer reply is heard in the CUSTOMER language and translated into the staff language', () async {
      final speech = FakeRecognizer();
      final t = FakeTranslator();
      final c = make(service: t, recognizer: speech);
      addTearDown(c.dispose);
      await c.startListening(TranslationDirection.customerToStaff);
      expect(speech.languages.last, ml);
      speech.say('ഒരു ചായ മതി');
      await pumpEventQueue();
      await c.translate();
      expect((t.requests.single.source, t.requests.single.target), (ml, en));
      expect(c.translatedText, '[en-US] ഒരു ചായ മതി');
    });

    test('microphone refused, or the language not recognised on this device: no listening, a clear message', () async {
      final speech = FakeRecognizer();
      final denied = make(
        recognizer: speech,
        permission: VoicePermission.permanentlyDenied,
      );
      addTearDown(denied.dispose);
      expect(
        await denied.startListening(TranslationDirection.staffToCustomer),
        isFalse,
      );
      expect(denied.error, contains('Microphone access is turned off'));
      expect(speech.listenCalls, 0);
      final noMl = LocaleRecognizer({ml: false});
      final c = make(recognizer: noMl);
      addTearDown(c.dispose);
      expect(
        await c.startListening(TranslationDirection.customerToStaff),
        isFalse,
      );
      expect(
        c.error,
        'Malayalam speech recognition is not available on this device. Type the text instead.',
      );
      expect(noMl.listenCalls, 0);
    });

    test('playback only when asked (auto-play is off by default); no voice for the language: text stays, note shown', () async {
      final tts = MockVoiceTtsService();
      final c = make(tts: tts)..setSourceText('hello');
      addTearDown(c.dispose);
      await c.translate();
      expect(tts.spoken, isEmpty, reason: 'not spoken automatically');
      await c.speak();
      expect((tts.spoken.single, tts.languages.single), ('[ml-IN] hello', ml));
      c.setAutoSpeak(true);
      c.setSourceText('bye');
      await c.translate();
      await pumpEventQueue();
      expect(tts.spoken.last, '[ml-IN] bye');
      final mute = MockVoiceTtsService()..failWith = StateError('no voice');
      final d = make(tts: mute)..setSourceText('hello');
      addTearDown(d.dispose);
      await d.translate();
      await d.speak();
      expect(d.canSpeak(ml), isFalse);
      expect(d.translatedText, '[ml-IN] hello');
    });
  });

  group('screen', () {
    Future<(TranslationController, FakeRecognizer)> pump(
      WidgetTester tester, {
      Size size = const Size(1200, 900),
      TranslationService? service,
      MockVoiceTtsService? tts,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final speech = FakeRecognizer();
      final c = make(
        recognizer: speech,
        anyService: service ?? FakeTranslator(),
        tts: tts ?? MockVoiceTtsService(),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: c,
            child: const TranslationView(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return (c, speech);
    }

    for (final size in [const Size(390, 844), const Size(1200, 900)]) {
      testWidgets(
        'speak, review, edit, translate, play, translate again, clear — ${size.width.toInt()}x${size.height.toInt()}, no overflow',
        (tester) async {
          final tts = MockVoiceTtsService();
          final (c, speech) = await pump(tester, size: size, tts: tts);
          expect(
            find.byKey(const Key('translation-mode-banner')),
            findsOneWidget,
          );
          await tester.tap(find.byKey(const Key('translation-staff-speak')));
          await tester.pump();
          expect(find.byKey(const Key('translation-stop')), findsOneWidget);
          speech.say('one tea please');
          await tester.pumpAndSettle();
          expect(
            find.widgetWithText(TextField, 'one tea please'),
            findsOneWidget,
          );
          await tester.enterText(
            find.byKey(const Key('translation-source')),
            'one tea, no sugar',
          );
          await tester.pump();
          await tester.tap(find.byKey(const Key('translation-translate')));
          await tester.pumpAndSettle();
          expect(find.text('[ml-IN] one tea, no sugar'), findsOneWidget);
          expect(
            find.textContaining('Translation (Malayalam (മലയാളം))'),
            findsOneWidget,
          );
          await tester.ensureVisible(find.byKey(const Key('translation-play')));
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('translation-play')));
          await tester.pumpAndSettle();
          expect(tts.spoken.single, '[ml-IN] one tea, no sugar');
          await tester.ensureVisible(
            find.byKey(const Key('translation-clear')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('translation-clear')));
          await tester.pumpAndSettle();
          expect(c.sourceText, '');
          expect(find.byKey(const Key('translation-result')), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets(
      'language pickers and swap; provider-unavailable banner and error',
      (tester) async {
        final (c, _) = await pump(
          tester,
          service: const UnavailableTranslationService(),
        );
        expect(
          find.byKey(const Key('translation-provider-unavailable')),
          findsOneWidget,
        );
        // Phase 3B.1: nothing switched on -> English / English only (the
        // workflow can be tried; English -> English is never "translated").
        expect((c.staffLanguage, c.customerLanguage), (en, en));
        expect(c.canChooseCustomer(ml), isFalse);
        await tester.tap(find.byKey(const Key('translation-swap')));
        await tester.pump();
        expect((c.staffLanguage, c.customerLanguage), (en, en));
        await tester.enterText(
          find.byKey(const Key('translation-source')),
          'hello',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('translation-translate')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('translation-error')), findsOneWidget);
        expect(find.byKey(const Key('translation-result')), findsNothing);
      },
    );

    // ---- Phase 3B.1: English-only, deliberately configured targets --------

    testWidgets(
      'only English -> Malayalam switched on: Malayalam cannot be the staff language, English cannot be the customer language, replies are off',
      (tester) async {
        final t = FakeTranslator()..pairs = {(en, ml)};
        final (c, _) = await pump(tester, service: t);
        expect(c.supportLoaded, isTrue);
        expect((c.staffLanguage, c.customerLanguage), (en, ml));
        expect(c.canChooseStaff(ml), isFalse);
        expect(c.canChooseCustomer(en), isFalse);
        expect(c.canTranslateReplies, isFalse);
        expect(
          find.byKey(const Key('translation-provider-unavailable')),
          findsNothing,
        );
        expect(
          find.byKey(const Key('translation-replies-off')),
          findsOneWidget,
        );
        final reply = tester.widget<ButtonStyleButton>(
          find.byKey(const Key('translation-customer-speak')),
        );
        expect(reply.onPressed, isNull);
        final swap = tester.widget<IconButton>(
          find.byKey(const Key('translation-swap')),
        );
        expect(swap.onPressed, isNull, reason: 'ml -> en is not switched on');
        // A disallowed choice is ignored.
        c.setLanguages(staff: ml, customer: en);
        expect((c.staffLanguage, c.customerLanguage), (en, ml));
        await tester.enterText(
          find.byKey(const Key('translation-source')),
          'two coffees',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('translation-translate')));
        await tester.pumpAndSettle();
        expect(t.requests.single.source, en);
        expect(t.requests.single.target, ml);
        expect(find.text('[ml-IN] two coffees'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'nothing switched on: English / English, a clear setup message, English -> English refused as the same language and never sent',
      (tester) async {
        final t = FakeTranslator()..pairs = {};
        final (c, _) = await pump(tester, service: t);
        expect((c.staffLanguage, c.customerLanguage), (en, en));
        expect(c.providerAvailable, isFalse);
        expect(
          find.textContaining('not set up on the store server yet'),
          findsOneWidget,
        );
        await tester.tap(
          find.byKey(const Key('translation-customer-language')),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('(not set up)'), findsWidgets);
        await tester.tapAt(const Offset(5, 5));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('translation-source')),
          'hello',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('translation-translate')));
        await tester.pumpAndSettle();
        expect(c.errorKind, TranslationErrorKind.sameLanguage);
        expect(c.translatedText, isNull, reason: 'never a fake translation');
        expect(find.byKey(const Key('translation-result')), findsNothing);
        expect(t.requests, isEmpty);
      },
    );
  });

  group('ISOLATION from billing', () {
    test('the translation code depends on nothing that bills: no cart, sale, checkout, payment, order or command parser', () {
      for (final f in Directory(
        'lib/features/voice/translation',
      ).listSync().whereType<File>()) {
        final src = f.readAsStringSync();
        for (final banned in [
          'cart',
          'checkout',
          'payment',
          'voice_controller',
          'voice_intent',
          'order_service',
          'held_sales',
          // Phase 3B.1: only the server provider may use the HTTP client.
          if (!f.path.endsWith('api_translation_service.dart'))
            'pos_api_client',
        ]) {
          expect(
            RegExp("import '[^']*$banned").hasMatch(src),
            isFalse,
            reason: '${f.path} imports $banned',
          );
        }
      }
      // Phase 3B.1: and that provider calls only the translation endpoints.
      final api = File(
        'lib/features/voice/translation/api_translation_service.dart',
      ).readAsStringSync();
      expect(
        RegExp(r"'(/[a-z_/:-]+)'").allMatches(api).map((m) => m[1]).toSet(),
        {'/translation/translate', '/translation/languages'},
      );
    });

    testWidgets(
      'customer phrases in translation mode ("yes", "cancel", "add two", "pay cash", "bill order 1048") change NOTHING in billing; back in billing the bill still needs a real confirmation',
      (tester) async {
        weightEnabled = true;
        final backend = FakeBackend(fakeServer);
        final speech = FakeRecognizer(); // ONE recognizer shared by both modes
        final service = growingCart();
        final cart = CartController(service);
        addTearDown(cart.dispose);
        final orders = FakeOrders();
        final translator = FakeTranslator();
        var checkout = 0;
        await tester.binding.setSurfaceSize(const Size(1000, 1400));
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
                      orderService: orders,
                      translationService: translator,
                      tts: MockVoiceTtsService(),
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
        speech.say('bill two coffees');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);
        final previewRequests = backend.requests.length;

        // Into translation mode.
        await tester.tap(find.byKey(const Key('voice-translation-mode')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('translation-mode-banner')),
          findsOneWidget,
        );
        for (final phrase in [
          'yes',
          'Yes, confirm the bill.',
          'cancel',
          'Cancel this bill.',
          'add two coffees',
          'pay cash',
          'bill order 1048',
          'bill two coffees',
          'അതെ',
        ]) {
          for (final who in [
            'translation-staff-speak',
            'translation-customer-speak',
          ]) {
            await tester.ensureVisible(find.byKey(Key(who)));
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(Key(who)));
            await tester.pump();
            speech.say(phrase);
            await tester.pumpAndSettle();
            await tester.ensureVisible(
              find.byKey(const Key('translation-translate')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.byKey(const Key('translation-translate')));
            await tester.pumpAndSettle();
            expect(
              find.byKey(const Key('translation-result')),
              findsOneWidget,
              reason: phrase,
            );
          }
        }
        expect(
          translator.requests,
          hasLength(18),
          reason: 'every phrase went to translation',
        );
        // Billing untouched while in translation mode.
        expect(
          backend.requests.length,
          previewRequests,
          reason: 'no quick bill / correction preview',
        );
        expect(service.addCalls, isEmpty, reason: 'nothing added to the cart');
        expect(service.createCalls, 0);
        expect(service.resumeCalls, isEmpty, reason: 'no order resumed');
        expect(
          service.completeCalls,
          isEmpty,
          reason: 'no sale completed / payment',
        );
        expect(orders.lookups, isEmpty, reason: 'no order lookup');
        expect(orders.tableLookups, isEmpty);
        expect(checkout, 0, reason: 'checkout never opened');

        // Back to billing: the same bill, still waiting for a real confirmation.
        await tester.tap(find.byKey(const Key('translation-close')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);
        expect(
          find.byKey(const Key('voice-awaiting-confirmation')),
          findsOneWidget,
        );
        expect(service.addCalls, isEmpty);
        await tester.tap(find.byKey(const Key('voice-confirm-bill')));
        await tester.pumpAndSettle();
        expect(checkout, 1);
        expect(
          [for (final c in service.addCalls) (c.variationId, c.quantity)],
          [(9900, 2)],
        );
        expect(service.completeCalls, isEmpty);
      },
    );

    testWidgets(
      'translation mode cannot be opened while billing is listening or adding a bill',
      (tester) async {
        weightEnabled = true;
        final speech = FakeRecognizer();
        final cart = CartController(growingCart());
        addTearDown(cart.dispose);
        await tester.binding.setSurfaceSize(const Size(1000, 1400));
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
                      openCheckout: (_) async {},
                      permission: FakeMicrophone()
                        ..current = VoicePermission.granted,
                      recognizer: speech,
                      previewService: ApiVoicePreviewService(
                        FakeBackend(fakeServer).client,
                      ),
                      scope: () => staffA,
                      translationService: FakeTranslator(),
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
        final button = tester.widget<IconButton>(
          find.byKey(const Key('voice-translation-mode')),
        );
        expect(button.onPressed, isNull, reason: 'billing is listening');
      },
    );
  });
}
