// Phase 13F — Jacky's spoken replies on the operator Quick Bill screen. TTS
// is presentation only: a MockVoiceTtsService records what would be said;
// no speaker, microphone or platform TTS is used. Replies are short, carry
// no ids, follow only the CURRENT request, stop on new listening / cancel /
// close, and never affect the bill or Confirm Bill.
import 'dart:async';

import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/data/voice_tts.dart';
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

class MockVoiceTtsService implements VoiceTtsService {
  final spoken = <String>[];
  final languages = <VoiceLanguage>[];
  int stops = 0;
  int disposes = 0;
  Object? failWith;

  /// When set, speech "plays" until the test completes it (or it is stopped).
  Completer<void>? playing;
  bool hold = false;

  @override
  Future<void> speak(
    String text, {
    VoiceLanguage language = VoiceLanguage.english,
  }) async {
    spoken.add(text);
    languages.add(language);
    if (failWith != null) throw failWith!;
    if (hold) {
      playing = Completer<void>();
      await playing!.future;
    }
  }

  @override
  Future<void> stop() async {
    stops++;
    if (playing?.isCompleted == false) playing!.complete();
  }

  @override
  Future<void> dispose() async => disposes++;
}

void main() {
  late FakeBackend backend;
  late FakeRecognizer speech;
  late FakeCartService service;
  late CartController cart;
  late MockVoiceTtsService tts;
  late VoiceController v;

  VoiceController make({VoicePreviewService? previews}) => VoiceController(
    permission: FakeMicrophone()..current = VoicePermission.granted,
    recognizer: speech,
    scope: () => staffA,
    previewService: previews ?? ApiVoicePreviewService(backend.client),
    cart: cart,
    tts: tts,
  );

  setUp(() {
    weightEnabled = true;
    backend = FakeBackend(fakeServer);
    speech = FakeRecognizer();
    service = growingCart();
    cart = CartController(service);
    tts = MockVoiceTtsService();
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
    expect(await v.startCorrection(), isTrue);
    speech.say(t);
    await pumpEventQueue();
  }

  test(
    '1. READY speaks a short verification prompt with the server total',
    () async {
      await bill('Jacky, bill two coffees and one water');
      expect(
        tts.spoken.last,
        'Your bill is ready. The total is 27.45. Please verify it before confirming.',
      );
      expect(v.isSpeaking, isFalse, reason: 'finished');
    },
  );

  test('2/3. NEEDS_CLARIFICATION speaks the question; candidates are only the server\'s, by name', () async {
    await bill('bill one sugar');
    expect(
      tts.spoken.last,
      'I need some clarification. Which sugar would you like: Sugar 1 kg pack or Sugar 500 g pack?',
    );
    await bill('bill two unicorn milks');
    expect(
      tts.spoken.last,
      "I need some clarification. Could not find a matching product for 'unicorn milk'.",
    );
  });

  test('4. ambiguous "it" and an unknown line: the same question as the screen, in speech form', () async {
    await bill('bill two coffees and one water');
    await correct('make it three');
    expect(tts.spoken.last, 'Which item? Coffee Regular or Water 1 L?');
    expect(
      v.correctionQuestion,
      startsWith('Which item? This bill has Coffee (Regular), Water (1 L).'),
    );
    await correct('remove the tea');
    expect(tts.spoken.last, 'There is no tea on this bill.');
    expect(backend.requests, hasLength(1), reason: 'the bill was not changed');
  });

  test('5. a correction says "Checking the bill." then the new result; removing the last line speaks the existing message', () async {
    await bill('bill two coffees');
    tts.spoken.clear();
    await correct('make it three');
    expect(tts.spoken, [
      'Checking the bill.',
      'Your bill is ready. The total is 14.175. Please verify it before confirming.',
    ]);
    await correct('remove it');
    expect(tts.spoken.last, VoiceController.allRemovedMessage);
  });

  test('6/12/13. a failing TTS never affects the bill: READY, Confirm Bill through the existing cart, one draft on double confirm', () async {
    tts.failWith = StateError('no TTS engine');
    await bill('bill two coffees and one water');
    expect(v.preview!.isReady, isTrue);
    expect(v.isSpeaking, isFalse);
    expect(v.error, isNull);
    final first = v.confirmBill();
    expect(await v.confirmBill(), isFalse);
    expect(await first, isTrue);
    expect(service.createCalls, 1);
    expect(service.addCalls.map((c) => (c.variationId, c.quantity)), [
      (9900, 2),
      (9901, 1),
    ]);
    expect(service.completeCalls, isEmpty);
  });

  test('7. starting to listen stops the current reply', () async {
    tts.hold = true;
    await bill('bill two coffees');
    expect(v.isSpeaking, isTrue);
    final before = tts.stops;
    await v.start();
    expect(tts.stops, greaterThan(before));
    expect(v.isSpeaking, isFalse);
  });

  test(
    '8. starting a new correction stops the current reply; Cancel stops it too',
    () async {
      tts.hold = true;
      await bill('bill two coffees');
      expect(v.isSpeaking, isTrue);
      expect(await v.startCorrection(), isTrue);
      expect(v.isSpeaking, isFalse);
      final before = tts.stops;
      await v.cancel();
      expect(tts.stops, greaterThan(before));
      tts.hold = false;
      v.cancelBill();
      expect(v.isSpeaking, isFalse);
    },
  );

  test('9. disposing the controller stops and releases TTS', () async {
    final c = make();
    await c.start();
    speech.say('bill two coffees');
    await pumpEventQueue();
    final stops = tts.stops;
    c.dispose();
    await pumpEventQueue();
    expect(tts.stops, greaterThan(stops));
    expect(tts.disposes, 1);
  });

  test('10. a late answer to an older request never speaks', () async {
    final gated = GatedPreviews();
    final g = make(previews: gated);
    addTearDown(g.dispose);
    await g.start();
    speech.say('bill two coffees and one water');
    await pumpEventQueue();
    gated.answer(0);
    await pumpEventQueue();
    unawaited(g.changeQuantity(0, 3)); // A
    await pumpEventQueue();
    unawaited(g.removeLine(1)); // B
    await pumpEventQueue();
    gated.answer(2);
    await pumpEventQueue();
    final afterB = List.of(tts.spoken);
    expect(
      afterB.last,
      'Your bill is ready. The total is 14.175. Please verify it before confirming.',
    );
    gated.answer(1); // A, late
    await pumpEventQueue();
    expect(tts.spoken, afterB, reason: 'nothing spoken for the stale answer');
  });

  test('11/14. replies never carry ids or technical detail, and speaking creates no cart, payment or sale activity', () async {
    await bill('bill one sugar and two coffees');
    await v.chooseCandidate(0, v.preview!.issues.single.candidates.first);
    await correct('make the coffee 3');
    await correct('make it four');
    await correct('add one water');
    await correct('remove the water');
    expect(tts.spoken, isNotEmpty);
    final requestIds = [
      for (final r in backend.requests)
        RegExp(r'"request_id":"([^"]+)"').firstMatch(r.body)!.group(1)!,
    ];
    for (final text in tts.spoken) {
      for (final id in [
        v.session!.voiceSessionId,
        ...requestIds,
        'STAFF-A',
        '9900',
        '9901',
        '9907',
        '9908',
        'CREATE_QUICK_BILL',
        'product_variation_id',
        'request',
        'session',
      ]) {
        expect(text.contains(id), isFalse, reason: '"$id" in "$text"');
      }
    }
    expect(service.createCalls, 0);
    expect(service.addCalls, isEmpty);
    expect(service.completeCalls, isEmpty);
    expect(
      backend.requests.every(
        (r) => r.url.path.endsWith('/voice/quick-bill/preview'),
      ),
      isTrue,
    );
  });

  testWidgets(
    'screen: "Jacky is speaking…" while a reply plays; Confirm Bill still opens the existing checkout; closing the screen stops TTS',
    (tester) async {
      tts.hold = true;
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
                    tts: tts,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.byKey(const Key('open-voice')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('voice-start')));
        await tester.pump();
        speech.say('bill two coffees');
        await tester.pump();
        await tester.pump();
      }

      await open();
      expect(find.byKey(const Key('voice-speaking')), findsOneWidget);
      expect(find.text('Jacky is speaking…'), findsOneWidget);
      // Closing the screen stops and releases TTS.
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tts.disposes, 1);
      expect(tts.playing!.isCompleted, isTrue, reason: 'stopped');

      tts.hold = false;
      await open();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('voice-confirm-bill')));
      await tester.pumpAndSettle();
      expect(checkout, 1);
      expect(service.createCalls, 1);
      expect(service.completeCalls, isEmpty);
    },
  );
}
