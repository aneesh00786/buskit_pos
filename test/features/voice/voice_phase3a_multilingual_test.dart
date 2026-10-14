// Phase 3A — multilingual POS voice commands (English + Malayalam) on the
// existing workflows: Quick Bill, corrections (incl. item positions),
// existing orders, tables, spoken yes / no / cancel, replies in the session
// language, the device's speech engines checked (never assumed), and the
// language kept per staff member without touching the bill or cart.
//
// These are AUTOMATED tests of parsing, state and wording. They do not prove
// that a device's microphone recognises Malayalam — that needs a real device
// with a Malayalam recogniser (see the Phase 3A report).
import 'package:buskit_pos/core/utils/format.dart';
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
import 'package:buskit_pos/features/voice/state/voice_payment_status.dart';
import 'package:buskit_pos/features/voice/state/voice_responses.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB;
import 'voice_phase1_test.dart' show recoverable;
import 'voice_phase21_tables_test.dart' show heldAt, summary;
import 'voice_phase2_orders_test.dart' show FakeOrders;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

const ml = VoiceLanguage.malayalam;
const en = VoiceLanguage.english;
const tamil = VoiceLanguage('ta-IN', 'Tamil');

/// A recognizer that reports which languages the device supports.
class LocaleRecognizer extends FakeRecognizer implements LocaleAwareRecognizer {
  LocaleRecognizer(this.support);
  final Map<VoiceLanguage, bool?> support;
  @override
  Future<bool?> supportsLanguage(VoiceLanguage language) async =>
      support[language];
}

/// The speech_to_text plugin with a scripted locale list.
class ScriptedStt extends stt.SpeechToText {
  ScriptedStt(this.list) : super.withMethodChannel();
  final Future<List<stt.LocaleName>> Function() list;
  @override
  Future<List<stt.LocaleName>> locales() => list();
}

void main() {
  const parser = RuleBasedIntentParser();
  const corrections = RuleBasedCorrectionParser();
  const replies = RuleBasedReplyParser();
  Future<VoiceIntent> mlParse(String t) =>
      parser.parse(t, voiceSessionId: 's', requestId: 'r', language: ml);
  Future<VoiceIntent> enParse(String t) =>
      parser.parse(t, voiceSessionId: 's', requestId: 'r');

  group('language configuration', () {
    test('English and Malayalam: locales, own names and every command capability; others unsupported', () {
      expect((en.speechLocale, en.ttsLocale), ('en-US', 'en-US'));
      expect(
        (ml.speechLocale, ml.ttsLocale, ml.nativeLabel),
        ('ml-IN', 'ml-IN', 'മലയാളം'),
      );
      expect(ml.displayName, 'Malayalam (മലയാളം)');
      for (final c in VoiceCapability.values) {
        expect(en.can(c) && ml.can(c), isTrue, reason: '$c');
      }
      expect(tamil.isSupported, isFalse);
      expect(VoiceSettings().setLanguage(tamil), isFalse);
    });

    test('the language choice is kept per staff member; others start with the device default', () {
      final s = VoiceSettings();
      expect(s.setLanguage(ml, staff: '1:A'), isTrue);
      expect(s.languageFor('1:A'), ml);
      expect(s.languageFor('1:B'), en);
      expect(s.languageFor(null), en);
      expect(s.language, en);
    });
  });

  group('Malayalam grammar (real Malayalam text)', () {
    test(
      'Quick Bill: quantities, units, sizes; English catalogue names',
      () async {
        final a = await mlParse('ജാക്കി, രണ്ട് coffee ബിൽ ചെയ്യൂ');
        expect(a.type, VoiceIntentType.createQuickBill);
        expect(
          [for (final i in a.items) (i.quantity, i.productQuery)],
          [(2, 'coffee')],
        );
        final b = await mlParse('ഒരു കിലോ rice, മൂന്ന് small water ബിൽ ചെയ്യൂ');
        expect(
          [
            for (final i in b.items)
              (i.quantity, i.unit, i.productQuery, i.variantQuery),
          ],
          [(1, 'kg', 'rice', null), (3, null, 'water', 'small')],
        );
      },
    );

    test('existing orders: digits (also Malayalam digits), "that order"; long number words are asked about', () async {
      for (final t in [
        'ഓർഡർ 1048 ബിൽ ചെയ്യൂ',
        'ജാക്കി, 1048 നമ്പർ ഓർഡർ കാണിക്കൂ',
        'ഓർഡർ ൧൦൪൮ തുറക്കൂ',
        'bill order 1048',
      ]) {
        final i = await mlParse(t);
        expect(
          (i.type, i.orderNumber),
          (VoiceIntentType.billOrder, 1048),
          reason: t,
        );
      }
      expect(
        (await mlParse('ആ ഓർഡർ ബിൽ ചെയ്യൂ')).type,
        VoiceIntentType.billShownOrder,
      );
      for (final t in [
        'ഓർഡർ ബിൽ ചെയ്യൂ',
        'ഓർഡർ ആയിരത്തി നാൽപ്പത്തിയെട്ട് ബിൽ ചെയ്യൂ',
      ]) {
        final i = await mlParse(t);
        expect(
          (i.type, i.need),
          (VoiceIntentType.needsClarification, ClarificationNeed.order),
          reason: t,
        );
        expect(i.orderNumber, isNull, reason: 'never guessed');
      }
    });

    test('tables: digits or Malayalam number words', () async {
      for (final (t, n) in [
        ('ടേബിൾ 6 ബിൽ ചെയ്യൂ', 6),
        ('ആറ് നമ്പർ ടേബിൾ കാണിക്കൂ', 6),
        ('മേശ 4-ലെ ഓർഡറുകൾ കാണിക്കൂ', 4),
      ]) {
        final i = await mlParse(t);
        expect(
          (i.type, i.tableNumber),
          (VoiceIntentType.tableOrder, n),
          reason: t,
        );
      }
      expect(
        (await mlParse('ടേബിൾ ബിൽ ചെയ്യൂ')).type,
        VoiceIntentType.needsClarification,
      );
    });

    test('corrections: by name, by position (first / last), add', () {
      final pos = corrections.parse('ആദ്യത്തെ ഇനം നാല് ആക്കൂ', language: ml)!;
      expect(
        (pos.kind, pos.position, pos.quantity),
        (VoiceCorrectionKind.setQuantity, 1, 4),
      );
      final last = corrections.parse(
        'അവസാനത്തെ ഇനം നീക്കം ചെയ്യൂ',
        language: ml,
      )!;
      expect((last.kind, last.position), (VoiceCorrectionKind.remove, -1));
      final byName = corrections.parse('coffee മൂന്ന് ആക്കൂ', language: ml)!;
      expect(
        (byName.kind, byName.target, byName.quantity),
        (VoiceCorrectionKind.setQuantity, 'coffee', 3),
      );
      final add = corrections.parse('ഒരു water കൂടി ചേർക്കൂ', language: ml)!;
      expect(add.kind, VoiceCorrectionKind.add);
    });

    test('answers: yes / no / cancel; mixed is unclear; a "no" can carry its correction', () {
      VoiceReply? r(String t) => replies.parse(t, language: ml)?.reply;
      for (final t in ['അതെ', 'ശരി, ബിൽ ചെയ്യൂ', 'ഉവ്വ്', 'ഓക്കെ']) {
        expect(r(t), VoiceReply.confirm, reason: t);
      }
      for (final t in ['വേണ്ട', 'ഇല്ല, എനിക്ക് മാറ്റണം', 'ശരിയല്ല']) {
        expect(r(t), VoiceReply.reject, reason: t);
      }
      for (final t in ['ബിൽ റദ്ദാക്കൂ', 'റദ്ദാക്കൂ']) {
        expect(r(t), VoiceReply.cancel, reason: t);
      }
      expect(r('അതെ വേണ്ട'), VoiceReply.unclear);
      expect(
        replies.parse('വേണ്ട, coffee മൂന്ന് ആക്കൂ', language: ml)!.rest,
        'coffee മൂന്ന് ആക്കൂ',
      );
    });

    test(
      'unrelated speech is never a command, a correction or an answer',
      () async {
        for (final t in ['ഇന്ന് നല്ല മഴയുണ്ട്', 'ഹലോ', 'ജാക്കി']) {
          expect((await mlParse(t)).type, VoiceIntentType.unknown, reason: t);
          expect(corrections.parse(t, language: ml), isNull, reason: t);
          expect(replies.parse(t, language: ml), isNull, reason: t);
        }
      },
    );

    test('no grammar for a language means no command; English sessions do not read Malayalam', () async {
      expect(
        (await parser.parse(
          'bill two coffees',
          voiceSessionId: 's',
          requestId: 'r',
          language: tamil,
        )).type,
        VoiceIntentType.unsupportedLanguage,
      );
      expect(
        (await enParse('ഓർഡർ 1048 ബിൽ ചെയ്യൂ')).type,
        VoiceIntentType.unknown,
      );
      expect(replies.parse('അതെ'), isNull);
    });
  });

  group('replies in the session language', () {
    test('every Phase 1 / 2 / 2.1 reply has Malayalam wording; server amounts are passed through unchanged', () {
      const m = MalayalamVoiceResponses();
      const e = EnglishVoiceResponses();
      final pairs = <(String, String)>[
        (m.whatToChange(), e.whatToChange()),
        (m.yesOrNo(), e.yesOrNo()),
        (m.notReadyToConfirm(), e.notReadyToConfirm()),
        (m.billCancelled(), e.billCancelled()),
        (m.orderNotFound(7), e.orderNotFound(7)),
        (m.orderChanged(), e.orderChanged()),
        (m.orderUncertain(), e.orderUncertain()),
        (m.noTableOrders('6'), e.noTableOrders('6')),
        (m.tableChoose(2, '6'), e.tableChoose(2, '6')),
        (m.staleBill(), e.staleBill()),
        (
          m.recognitionUnavailable('Malayalam'),
          e.recognitionUnavailable('Malayalam'),
        ),
      ];
      for (final (mlText, enText) in pairs) {
        expect(mlText, isNot(enText));
        expect(RegExp('[ഀ-ൿ]').hasMatch(mlText), isTrue, reason: mlText);
      }
      expect(m.orderPrompt(1048, '1,234.50'), contains('1,234.50'));
      expect(m.orderPrompt(1048, '1,234.50'), contains('1048'));
    });

    test('payment status: Malayalam wording for every status message; the status itself never changes', () {
      final outcomes = [
        for (final s in RecoveryState.values)
          describeRecovery(
            PaymentRecoveryResult(recoverable: [recoverable(7, s)]),
            7,
          ),
        describeRecovery(
          const PaymentRecoveryResult(
            resolved: [ResolvedSale(saleId: 7, status: 'SALE_COMPLETED')],
          ),
          7,
        ),
        describeRecovery(
          const PaymentRecoveryResult(
            resolved: [ResolvedSale(saleId: 7, status: 'SALE_VOIDED')],
          ),
          7,
        ),
      ];
      for (final o in outcomes) {
        expect(o.messageIn(en), o.message);
        expect(o.messageIn(ml), isNot(o.message), reason: o.message);
        expect(RegExp('[ഀ-ൿ]').hasMatch(o.messageIn(ml)), isTrue);
      }
    });
  });

  group('controller (Malayalam session)', () {
    late FakeOrders orders;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late MockVoiceTtsService tts;
    late VoiceSettings settings;
    late VoiceController v;

    VoiceController make(
      FakeRecognizer s,
      CartController c,
      scope, {
      MockVoiceTtsService? t,
    }) => VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: s,
      scope: () => scope,
      previewService: ApiVoicePreviewService(FakeBackend(fakeServer).client),
      orderService: orders,
      cart: c,
      tts: t ?? tts,
      settings: settings,
    );

    setUp(() {
      weightEnabled = true;
      orders = FakeOrders()..orders[1048] = heldAt(1048, '6');
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      tts = MockVoiceTtsService();
      settings = VoiceSettings();
      v = make(speech, cart, staffA);
      expect(v.selectLanguage(ml), isTrue);
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
      expect(await v.startCorrection(), isTrue, reason: t);
      speech.say(t);
      await pumpEventQueue();
    }

    test('Quick Bill in Malayalam; "അതെ" confirms THIS revision through Confirm Bill (nothing paid)', () async {
      await say('രണ്ട് coffee ബിൽ ചെയ്യൂ');
      expect(v.session!.language, ml);
      expect(speech.languages.last, ml);
      expect(v.preview!.isReady, isTrue);
      await answer('അതെ');
      expect(v.billState, VoiceBillState.added);
      expect(
        [for (final c in service.addCalls) (c.variationId, c.quantity)],
        [(9900, 2)],
      );
      expect(service.completeCalls, isEmpty);
    });

    test('"വേണ്ട" asks what to change in Malayalam; a positional correction needs a NEW confirmation', () async {
      await say('രണ്ട് coffee, ഒരു water ബിൽ ചെയ്യൂ');
      await answer('വേണ്ട');
      expect(
        v.correctionQuestion,
        const MalayalamVoiceResponses().whatToChange(),
      );
      await answer('ആദ്യത്തെ ഇനം നാല് ആക്കൂ');
      expect(v.preview!.items.firstWhere((l) => l.itemIndex == 0).quantity, 4);
      expect(service.addCalls, isEmpty);
      await answer('അതെ');
      expect(
        [for (final c in service.addCalls) (c.variationId, c.quantity)],
        [(9900, 4), (9901, 1)],
      );
    });

    test(
      '"ബിൽ റദ്ദാക്കൂ" cancels; nothing billed; said in Malayalam',
      () async {
        await say('രണ്ട് coffee ബിൽ ചെയ്യൂ');
        await answer('ബിൽ റദ്ദാക്കൂ');
        expect(v.preview, isNull);
        expect(service.addCalls, isEmpty);
        expect(
          tts.spoken.last,
          const MalayalamVoiceResponses().billCancelled(),
        );
        expect(tts.languages.last, ml);
      },
    );

    test('existing order in Malayalam: shown with the server total, asked in Malayalam, "അതെ" resumes that version', () async {
      await say('ഓർഡർ 1048 ബിൽ ചെയ്യൂ');
      expect(v.orderState, VoiceOrderState.loaded);
      expect(
        tts.spoken.last,
        const MalayalamVoiceResponses().orderPrompt(
          1048,
          formatMoney(v.order!.totals.grandTotal ?? 0),
        ),
      );
      expect(await v.startOrderAnswer(), isTrue);
      speech.say('അതെ');
      await pumpEventQueue();
      expect(
        (
          service.resumeCalls.single.saleId,
          service.resumeCalls.single.expectedVersion,
        ),
        (1048, 3),
      );
      expect(v.confirmedByVoice, isTrue);
    });

    test('missing order / empty table / several orders at a table: Malayalam messages; never chosen automatically', () async {
      await say('ഓർഡർ 77 ബിൽ ചെയ്യൂ');
      expect(v.orderMessage, const MalayalamVoiceResponses().orderNotFound(77));
      await say('ടേബിൾ 9 ബിൽ ചെയ്യൂ');
      expect(
        v.orderMessage,
        const MalayalamVoiceResponses().noTableOrders('9'),
      );
      orders.tables['6'] = [summary(1048), summary(1050)];
      await say('ടേബിൾ 6 കാണിക്കൂ');
      expect(v.orderState, VoiceOrderState.choosing);
      expect(
        tts.spoken.last,
        const MalayalamVoiceResponses().tableChoose(2, '6'),
      );
      expect(await v.confirmOrder(), isFalse);
    });

    test('changing the language mid-bill keeps the bill, its language and the cart; the next bill uses the new language', () async {
      await say('രണ്ട് coffee ബിൽ ചെയ്യൂ');
      final preview = v.preview;
      await cart.addItem(9901, 1); // something already in the cart
      expect(v.selectLanguage(en), isTrue);
      expect(v.session!.language, ml);
      expect(identical(v.preview, preview), isTrue);
      expect(cart.sale!.items, hasLength(1));
      await answer('അതെ'); // still understood in the bill's own language
      expect(
        v.billError,
        isNotNull,
        reason: 'the cart already has a sale: refused, not merged',
      );
      v.cancelBill();
      await say('bill one water');
      expect(v.session!.language, en);
    });

    test('per staff: staff A chose Malayalam; staff B on the same device starts in English', () async {
      final b = make(FakeRecognizer(), CartController(growingCart()), staffB);
      addTearDown(b.dispose);
      expect(v.language, ml);
      expect(b.language, en);
    });

    test('recognizer says Malayalam is not installed: no listening, a clear Malayalam message, English still works', () async {
      final noMl = LocaleRecognizer({ml: false, en: true});
      final c = make(noMl, cart, staffA);
      addTearDown(c.dispose);
      expect(await c.start(), isFalse);
      expect(noMl.listenCalls, 0);
      expect(c.state, VoiceState.error);
      expect(
        c.error,
        const MalayalamVoiceResponses().recognitionUnavailable('Malayalam'),
      );
      expect(c.recognitionAvailable(ml), isFalse);
      expect(c.session, isNull, reason: 'never falls back to another language');
      c.selectLanguage(en);
      expect(await c.start(), isTrue);
      expect(noMl.languages.last, en);
    });

    test('recognizer cannot tell (null): tried as before', () async {
      final unknown = LocaleRecognizer({ml: null});
      final c = make(unknown, cart, staffA);
      addTearDown(c.dispose);
      expect(await c.start(), isTrue);
      expect(unknown.languages.last, ml);
    });

    test('no Malayalam voice for spoken replies: replies stay on screen, with a note', () async {
      final mute = MockVoiceTtsService()
        ..failWith = StateError('No Malayalam voice');
      final c = make(speech, cart, staffA, t: mute);
      addTearDown(c.dispose);
      await c.start();
      speech.say('ഓർഡർ 77 ബിൽ ചെയ്യൂ');
      await pumpEventQueue();
      expect(c.orderMessage, const MalayalamVoiceResponses().orderNotFound(77));
      expect(
        c.spokenRepliesNote,
        const MalayalamVoiceResponses().spokenRepliesUnavailable('Malayalam'),
      );
    });
  });

  group('device recognizer locale check (speech_to_text)', () {
    test('matches the language part of the device locales; empty or failing lists are "cannot tell"', () async {
      Future<bool?> check(
        Future<List<stt.LocaleName>> Function() list,
        VoiceLanguage l,
      ) => SpeechToTextRecognizer(ScriptedStt(list)).supportsLanguage(l);
      Future<List<stt.LocaleName>> locales() async => [
        stt.LocaleName('en_US', 'English'),
        stt.LocaleName('ml_IN', 'Malayalam'),
      ];
      expect(await check(locales, ml), isTrue);
      expect(await check(locales, en), isTrue);
      expect(
        await check(() async => [stt.LocaleName('en-US', 'English')], ml),
        isFalse,
      );
      expect(await check(() async => [], ml), isNull);
      expect(
        await check(() async => throw StateError('no engine'), ml),
        isNull,
      );
    });
  });

  test('a held order resumed by voice in Malayalam keeps the SAME sale (no duplicate) — summary sanity', () {
    final o = heldAt(1048, '6');
    expect(o, isA<CartSale>());
    expect(TableOrderSummary(id: 1, version: 1).id, 1);
  });
}
