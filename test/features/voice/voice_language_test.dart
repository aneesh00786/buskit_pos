// Phase 13G — multilingual voice FOUNDATION. One language (English, en-US)
// flows through recognition -> parser -> corrections -> TTS, kept by the
// voice session. A language without an implementation can never be
// selected and is never parsed as English. English behaviour is unchanged.

import 'package:buskit_pos/features/cart/state/cart_controller.dart';
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
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart'
    show GatedPreviews, fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

/// A language with NO implementation (stands in for any future one).
const notImplemented = VoiceLanguage('xx-XX', 'Test language');

/// Settings that report a language regardless of what is implemented
/// (to prove the rest of the flow refuses it rather than guessing).
class ForcedSettings extends VoiceSettings {
  VoiceLanguage forced = VoiceLanguage.english;
  @override
  VoiceLanguage get language => forced;
}

/// Records the language the controller hands the parser.
class RecordingParser implements VoiceIntentParser {
  final languages = <VoiceLanguage>[];
  @override
  Future<VoiceIntent> parse(
    String recognizedText, {
    required String voiceSessionId,
    required String requestId,
    VoiceLanguage language = VoiceLanguage.english,
  }) {
    languages.add(language);
    return const RuleBasedIntentParser().parse(
      recognizedText,
      voiceSessionId: voiceSessionId,
      requestId: requestId,
      language: language,
    );
  }
}

void main() {
  group('language model and setting', () {
    test('1. English is the default and maps to en-US', () {
      expect(VoiceSettings().language, VoiceLanguage.english);
      expect(VoiceLanguage.english.code, 'en-US');
      expect(VoiceLanguage.english.label, 'English');
      // Phase 13H added Malayalam; English stays the default.
      expect(VoiceLanguage.supported, [
        VoiceLanguage.english,
        VoiceLanguage.malayalam,
      ]);
      expect(VoiceLanguage.english.isSupported, isTrue);
      expect(
        voiceSettings.language,
        VoiceLanguage.english,
        reason: 'app setting',
      );
    });

    test('8a. a language without an implementation cannot be selected', () {
      final s = VoiceSettings();
      var notified = 0;
      s.addListener(() => notified++);
      expect(notImplemented.isSupported, isFalse);
      expect(s.setLanguage(notImplemented), isFalse);
      expect(s.language, VoiceLanguage.english);
      expect(s.setLanguage(VoiceLanguage.english), isTrue);
      expect(notified, 0, reason: 'nothing changed');
    });
  });

  group('parser boundary', () {
    const parser = RuleBasedIntentParser();
    test(
      '4/5. English via the language boundary = the existing parser, exactly',
      () async {
        for (final t in [
          'Jacky, bill two large coffees and three waters',
          'Bill 1.5 kg rice',
          'Bill some coffee',
          'what time is it',
        ]) {
          final a = await parser.parse(t, voiceSessionId: 's', requestId: 'r');
          final b = await parser.parse(
            t,
            voiceSessionId: 's',
            requestId: 'r',
            language: VoiceLanguage.english,
          );
          expect(b.toJson(), a.toJson(), reason: t);
          expect(b.need, a.need, reason: t);
        }
      },
    );

    test('8b. a language without a parser is UNSUPPORTED_LANGUAGE — never parsed as English', () async {
      final i = await parser.parse(
        'bill two coffees',
        voiceSessionId: 's',
        requestId: 'r',
        language: notImplemented,
      );
      expect(i.type, VoiceIntentType.unsupportedLanguage);
      expect(i.type.wire, 'UNSUPPORTED_LANGUAGE');
      expect(i.items, isEmpty);
      expect((i.voiceSessionId, i.requestId), ('s', 'r'));
      final c = const RuleBasedCorrectionParser().parse(
        'make it three',
        language: notImplemented,
      );
      expect(c!.kind, VoiceCorrectionKind.unclear);
      expect(c.question, contains('not available in Test language'));
      expect(
        const RuleBasedCorrectionParser()
            .parse('make it three', language: VoiceLanguage.english)!
            .kind,
        VoiceCorrectionKind.setQuantity,
      );
    });
  });

  group('Quick Bill flow carries the session language', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late MockVoiceTtsService tts;
    late RecordingParser parser;
    late ForcedSettings settings;
    late VoiceController v;

    VoiceController make({VoicePreviewService? previews}) => VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: speech,
      scope: () => staffA,
      previewService: previews ?? ApiVoicePreviewService(backend.client),
      cart: cart,
      tts: tts,
      settings: settings,
      intentParser: parser,
    );

    setUp(() {
      weightEnabled = true;
      backend = FakeBackend(fakeServer);
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      tts = MockVoiceTtsService();
      parser = RecordingParser();
      settings = ForcedSettings();
      v = make();
    });
    tearDown(() {
      v.dispose();
      cart.dispose();
    });

    test('2/3/5/6/9/10/14. English (en-US) reaches recognition, parser and TTS; the session keeps it; Confirm Bill is unchanged', () async {
      await v.start();
      speech.say('bill two coffees and one water');
      await pumpEventQueue();
      expect(v.session!.language, VoiceLanguage.english);
      expect(speech.languages.map((l) => l.code), ['en-US']);
      expect(parser.languages, [VoiceLanguage.english]);
      expect(tts.languages, isNotEmpty);
      expect(tts.languages.every((l) => l.code == 'en-US'), isTrue);
      expect(
        tts.spoken.last,
        'The total is 27.45. Would you like to confirm this bill?',
      );
      expect(backend.lastBody.keys.toSet(), {
        'intent',
        'voice_session_id',
        'request_id',
        'recognized_text',
        'items',
      }, reason: 'the backend contract is unchanged (no language field)');
      final first = v.confirmBill();
      expect(await v.confirmBill(), isFalse);
      expect(await first, isTrue);
      expect(service.createCalls, 1);
      expect(service.completeCalls, isEmpty);
    });

    test('7. a correction stays in its session language even if the setting changes meanwhile', () async {
      await v.start();
      speech.say('bill two coffees');
      await pumpEventQueue();
      final session = v.session!.voiceSessionId;
      settings.forced = notImplemented; // e.g. a future setting change
      expect(await v.startCorrection(), isTrue);
      speech.say('make it three');
      await pumpEventQueue();
      expect(v.session!.voiceSessionId, session);
      expect(v.session!.language, VoiceLanguage.english);
      expect(speech.languages.map((l) => l.code), ['en-US', 'en-US']);
      expect((backend.lastBody['items'] as List).single, {
        'product_query': 'coffee',
        'quantity': 3,
      });
      expect(tts.languages.every((l) => l == VoiceLanguage.english), isTrue);
    });

    test('8c. a NEW bill in a language without an implementation fails safely: no listening, no preview, no cart change', () async {
      settings.forced = notImplemented;
      expect(await v.start(), isFalse);
      expect(v.state, VoiceState.error);
      expect(v.error, 'Voice is not available in Test language yet.');
      expect(speech.listenCalls, 0);
      expect(v.session, isNull);
      expect(backend.requests, isEmpty);
      expect(service.createCalls, 0);
    });

    test(
      'a stale answer from a previous session never updates the new one',
      () async {
        final gated = GatedPreviews();
        final g = make(previews: gated);
        addTearDown(g.dispose);
        await g.start();
        speech.say('bill two coffees');
        await pumpEventQueue();
        final oldSession = g.session!.voiceSessionId;
        await g.newSession();
        expect(g.session!.voiceSessionId, isNot(oldSession));
        expect(g.session!.language, VoiceLanguage.english);
        gated.answer(0);
        await pumpEventQueue();
        expect(g.preview, isNull);
        expect(g.previewState, VoicePreviewState.none);
        expect(tts.spoken, isEmpty, reason: 'nothing spoken for it either');
      },
    );
  });

  testWidgets(
    'screen: operator Quick Bill shows "Language: English" (no code); the developer screen shows the code',
    (tester) async {
      final backend = FakeBackend(fakeServer);
      final speech = FakeRecognizer();
      final cart = CartController(growingCart());
      addTearDown(cart.dispose);
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
      expect(find.textContaining('en-US'), findsNothing);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      final dev = VoiceController(
        permission: FakeMicrophone()..current = VoicePermission.granted,
        recognizer: FakeRecognizer(),
        scope: () => staffA,
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
      expect(find.text('Voice (developer test)'), findsOneWidget);
      expect(find.text('English (en-US)'), findsOneWidget);
    },
  );
}
