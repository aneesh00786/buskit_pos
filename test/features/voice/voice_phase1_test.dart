// Phase 1 — English voice billing: natural commands (with or without
// "Jacky,"), corrections by position ("change the first item to four",
// "make that two instead"), a spoken yes / no / cancel to "Would you like to
// confirm this bill?", and the bill's payment status after the EXISTING
// checkout — read from authoritative state only.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/utils/format.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent_parser.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/state/voice_payment_status.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

class FakeRecovery implements PaymentRecoveryService {
  FakeRecovery(this.answer);
  PaymentRecoveryResult Function(List<int> saleIds) answer;
  final asked = <List<int>>[];
  bool fail = false;
  @override
  Future<PaymentRecoveryResult> fetch({
    bool refresh = false,
    List<int> saleIds = const [],
  }) async {
    asked.add(saleIds);
    if (refresh) throw StateError('voice status must never ask the provider');
    if (fail) {
      throw const ApiException(kind: ApiErrorKind.network, message: 'offline');
    }
    return answer(saleIds);
  }

  @override
  Future<void> cancelAttempt(int attemptId) =>
      throw StateError('never cancels');
}

RecoverableSale recoverable(int id, RecoveryState state) => RecoverableSale(
  saleId: id,
  state: state,
  sale: CartSaleFactory.sale(id: id),
  attempts: const [],
  canComplete: false,
  nextAction: 'CONTACT_MANAGER',
  completionPayments: const [],
);

void main() {
  const intents = RuleBasedIntentParser();
  const corrections = RuleBasedCorrectionParser();
  const replies = RuleBasedReplyParser();
  Future<VoiceIntent> parse(String t) =>
      intents.parse(t, voiceSessionId: 's', requestId: 'r');
  List<(num, String, String?)> lines(VoiceIntent i) => [
    for (final x in i.items) (x.quantity, x.productQuery, x.variantQuery),
  ];

  group('1A. natural English commands', () {
    test(
      'quick bills: "Jacky," prefix, "bill" / "ring up", spoken numbers, sizes',
      () async {
        final ice = await parse(
          'Jacky, bill three small butterscotch cones and two small waters.',
        );
        expect(ice.type, VoiceIntentType.createQuickBill);
        expect(lines(ice), [
          (3, 'butterscotch cone', 'small'),
          (2, 'water', 'small'),
        ]);
        expect(lines(await parse('Bill two coffees.')), [(2, 'coffee', null)]);
        expect(lines(await parse('Ring up three cappuccinos.')), [
          (3, 'cappuccino', null),
        ]);
        expect(lines(await parse('bill twenty five coffees')), [
          (25, 'coffee', null),
        ]);
        expect(lines(await parse('bill 12 coffees, 1 tea')), [
          (12, 'coffee', null),
          (1, 'tea', null),
        ]);
      },
    );

    test('capitalisation and punctuation make no difference', () async {
      final plain = lines(await parse('bill two coffees and one water'));
      for (final t in [
        'JACKY, BILL TWO COFFEES AND ONE WATER!',
        'Jacky bill two coffees & one water.',
        'jacky, Bill Two Coffees, One Water?',
      ]) {
        expect(lines(await parse(t)), plain, reason: t);
      }
    });

    test(
      'unrelated speech is never a bill, a correction or an answer',
      () async {
        for (final t in [
          "What's the weather like today?",
          'hello',
          'Jacky',
          'the coffee machine is broken',
          'I need to call my supplier',
        ]) {
          expect((await parse(t)).type, VoiceIntentType.unknown, reason: t);
          expect(corrections.parse(t), isNull, reason: t);
          expect(replies.parse(t), isNull, reason: t);
        }
      },
    );

    test('a vague quantity or product asks instead of guessing', () async {
      expect(
        (await parse('bill some coffee')).clarification,
        'How many coffee?',
      );
      expect((await parse('bill two')).need, ClarificationNeed.product);
    });

    test('corrections: by position, "instead", remove, add', () {
      final first = corrections.parse('Change the first item to four.')!;
      expect(
        (first.kind, first.position, first.target, first.quantity),
        (VoiceCorrectionKind.setQuantity, 1, null, 4),
      );
      final instead = corrections.parse('Make that two instead.')!;
      expect(
        (instead.kind, instead.position, instead.target, instead.quantity),
        (VoiceCorrectionKind.setQuantity, null, null, 2),
      );
      final second = corrections.parse('make the second one 3')!;
      expect((second.position, second.quantity), (2, 3));
      final item2 = corrections.parse('change item 2 to five')!;
      expect((item2.position, item2.quantity), (2, 5));
      final last = corrections.parse('remove the last item')!;
      expect((last.kind, last.position), (VoiceCorrectionKind.remove, -1));
      final water = corrections.parse('Remove the water.')!;
      expect((water.kind, water.target), (VoiceCorrectionKind.remove, 'water'));
      final add = corrections.parse('Add one chocolate cone.')!;
      expect(add.kind, VoiceCorrectionKind.add);
      expect(
        [for (final i in add.items) (i.quantity, i.productQuery)],
        [(1, 'chocolate cone')],
      );
    });

    test('answers: yes / no / cancel; mixed answers are unclear; "no" may carry the correction', () {
      VoiceReply? r(String t) => replies.parse(t)?.reply;
      for (final t in [
        'Yes, confirm the bill.',
        'yes',
        'Yeah',
        'Jacky, yes',
        "Yes that's correct",
        'OK confirm it',
        'go ahead',
      ]) {
        expect(r(t), VoiceReply.confirm, reason: t);
      }
      for (final t in [
        'No, I want to change something.',
        'no',
        'Nope',
        "No, that's not right",
        'no wait',
      ]) {
        expect(r(t), VoiceReply.reject, reason: t);
        expect(replies.parse(t)!.rest, isNull, reason: t);
      }
      for (final t in [
        'Cancel this bill.',
        'cancel',
        'Jacky, cancel the bill please',
      ]) {
        expect(r(t), VoiceReply.cancel, reason: t);
      }
      for (final t in ['yes no', 'yes, add one coffee', 'no yes']) {
        expect(r(t), VoiceReply.unclear, reason: t);
      }
      expect(
        replies.parse('No, make the coffee three')!.rest,
        'make the coffee three',
      );
    });

    test('answers only in a language with a grammar (Phase 3A adds Malayalam; any other language: none)', () {
      expect(replies.parse('yes', language: const VoiceLanguage('ta-IN', 'Tamil')), isNull);
      expect(replies.parse('അതെ', language: VoiceLanguage.malayalam)!.reply, VoiceReply.confirm);
      expect(replies.parse('അതെ'), isNull, reason: 'English sessions do not read Malayalam words');
    });
  });

  group('1B / 1C. spoken corrections and yes / no confirmation (controller)', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late FakeCartService service;
    late CartController cart;
    late MockVoiceTtsService tts;
    late VoiceController v;

    setUp(() {
      weightEnabled = true;
      backend = FakeBackend(fakeServer);
      speech = FakeRecognizer();
      service = growingCart();
      cart = CartController(service);
      tts = MockVoiceTtsService();
      v = VoiceController(
        permission: FakeMicrophone()..current = VoicePermission.granted,
        recognizer: speech,
        scope: () => staffA,
        previewService: ApiVoicePreviewService(backend.client),
        cart: cart,
        tts: tts,
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

    Future<void> answer(String t) async {
      expect(await v.startCorrection(), isTrue, reason: t);
      speech.say(t);
      await pumpEventQueue();
    }

    List<(int, num)> added() => [
      for (final c in service.addCalls) (c.variationId, c.quantity),
    ];

    test('the server-checked bill is shown and the server total is spoken with the confirmation question', () async {
      await bill('Jacky, bill two coffees and one water');
      expect(v.preview!.isReady, isTrue);
      expect(
        tts.spoken.last,
        'The total is ${formatMoney(v.preview!.total!)}. Would you like to confirm this bill?',
      );
      expect(tts.spoken.last, contains('Would you like to confirm this bill?'));
      expect(
        service.addCalls,
        isEmpty,
        reason: 'nothing billed before an explicit confirmation',
      );
    });

    test('spoken "yes" confirms THIS bill through Confirm Bill: lines go into the cart for the existing checkout; nothing is paid or completed', () async {
      await bill('bill two coffees and one water');
      await answer('Yes, confirm the bill.');
      expect(v.billState, VoiceBillState.added);
      expect(v.confirmedByVoice, isTrue);
      expect(added(), [(9900, 2), (9901, 1)]);
      expect(service.completeCalls, isEmpty);
    });

    test(
      'a repeated "yes" (or a tap after it) never adds the bill twice',
      () async {
        await bill('bill two coffees');
        await answer('yes');
        expect(
          await v.startCorrection(),
          isFalse,
          reason: 'nothing left to answer',
        );
        expect(await v.confirmBill(), isFalse);
        expect(added(), [(9900, 2)]);
      },
    );

    test('spoken "no" keeps the bill unfinalised and asks what to change; a correction then needs a NEW confirmation', () async {
      await bill('bill two coffees and one water');
      final first = v.preview;
      await answer('No, I want to change something.');
      expect(v.correctionQuestion, VoiceController.whatToChangeQuestion);
      expect(tts.spoken.last, 'What would you like to change?');
      expect(identical(v.preview, first), isTrue);
      expect(service.addCalls, isEmpty);

      await answer('Change the first item to four.');
      expect(backend.lastBody['items'], [
        {'product_query': 'coffee', 'quantity': 4},
        {'product_query': 'water', 'quantity': 1},
      ]);
      expect(v.preview!.isReady, isTrue);
      expect(
        v.confirmedByVoice,
        isFalse,
        reason: 'a corrected bill must be confirmed again',
      );
      expect(tts.spoken.last, contains('Would you like to confirm this bill?'));
      expect(service.addCalls, isEmpty);

      await answer('yes');
      expect(added(), [
        (9900, 4),
        (9901, 1),
      ], reason: 'the corrected revision, never the first one');
    });

    test('"no, make the coffee three" applies the correction in one answer; "make that two instead" targets the single line', () async {
      await bill('bill two coffees and one water');
      await answer('No, make the coffee three');
      expect((backend.lastBody['items'] as List).first, {
        'product_query': 'coffee',
        'quantity': 3,
      });
      await answer('remove the water');
      await answer('Make that two instead.');
      expect(backend.lastBody['items'], [
        {'product_query': 'coffee', 'quantity': 2},
      ]);
    });

    test('positions outside the bill ask instead of guessing', () async {
      await bill('bill two coffees and one water');
      await answer('change the third item to two');
      expect(
        v.correctionQuestion,
        startsWith('There is no item 3 on this bill.'),
      );
      expect(backend.requests, hasLength(1), reason: 'nothing sent');
    });

    test('an unclear answer asks for yes or no and changes nothing', () async {
      await bill('bill two coffees');
      await answer('yes, add one coffee');
      expect(v.correctionQuestion, VoiceController.yesOrNoQuestion);
      expect(service.addCalls, isEmpty);
      expect(backend.requests, hasLength(1));
    });

    test(
      '"yes" while the bill still needs clarification confirms nothing',
      () async {
        await bill('bill one sugar');
        expect(v.preview!.isReady, isFalse);
        expect(await v.startCorrection(), isTrue);
        speech.say('yes');
        await pumpEventQueue();
        expect(v.correctionQuestion, VoiceController.notReadyToConfirmMessage);
        expect(service.addCalls, isEmpty);
      },
    );

    test(
      '"cancel this bill" discards the bill; nothing is added or paid',
      () async {
        await bill('bill two coffees');
        await answer('Cancel this bill.');
        expect(v.preview, isNull);
        expect(v.previewState, VoicePreviewState.none);
        expect(service.addCalls, isEmpty);
        expect(tts.spoken.last, 'The bill was cancelled. Nothing was billed.');
      },
    );

    test('a "yes" heard after the bill was cancelled confirms nothing (late speech is ignored)', () async {
      await bill('bill two coffees');
      expect(await v.startCorrection(), isTrue);
      v.cancelBill();
      speech.say('yes');
      await pumpEventQueue();
      expect(service.addCalls, isEmpty);
      expect(v.confirmedByVoice, isFalse);
    });

    test('a stale preview cannot be confirmed by voice: the reviewed revision must be the current one', () async {
      await bill('bill two coffees');
      final old = v.preview!;
      await answer('make it three');
      v.debugSetPreview(old); // the screen somehow shows the old revision
      await answer('yes');
      expect(service.addCalls, isEmpty);
      expect(v.previewError, VoiceController.staleBillMessage);
    });
  });

  test(
    '1E. two staff members: each "yes" confirms only that member\'s own bill',
    () async {
      weightEnabled = true;
      final backend = FakeBackend(fakeServer);
      final speechA = FakeRecognizer(), speechB = FakeRecognizer();
      final serviceA = growingCart(), serviceB = growingCart();
      final cartA = CartController(serviceA), cartB = CartController(serviceB);
      VoiceController make(FakeRecognizer s, CartController c, scope) =>
          VoiceController(
            permission: FakeMicrophone()..current = VoicePermission.granted,
            recognizer: s,
            scope: () => scope,
            previewService: ApiVoicePreviewService(backend.client),
            cart: c,
          );
      final a = make(speechA, cartA, staffA), b = make(speechB, cartB, staffB);
      addTearDown(() {
        a.dispose();
        b.dispose();
        cartA.dispose();
        cartB.dispose();
      });
      await a.start();
      speechA.say('bill two coffees');
      await b.start();
      speechB.say('bill one water');
      await pumpEventQueue();
      expect(a.session!.voiceSessionId, isNot(b.session!.voiceSessionId));
      expect(await a.startCorrection(), isTrue);
      speechA.say('yes');
      await pumpEventQueue();
      expect(
        [for (final c in serviceA.addCalls) (c.variationId, c.quantity)],
        [(9900, 2)],
      );
      expect(serviceB.addCalls, isEmpty, reason: "B's bill is untouched");
      expect(b.billState, VoiceBillState.none);
      expect(b.preview!.isReady, isTrue);
    },
  );

  group('1D. payment status (authoritative state only)', () {
    test('every server recovery state maps to a plain English status; captured-but-unfinished is never "paid"', () {
      VoicePaymentStatus of(RecoveryState s) => describeRecovery(
        PaymentRecoveryResult(recoverable: [recoverable(7, s)]),
        7,
      ).status;
      expect(of(RecoveryState.noPayment), VoicePaymentStatus.unpaid);
      expect(of(RecoveryState.pending), VoicePaymentStatus.pending);
      expect(of(RecoveryState.captured), VoicePaymentStatus.pending);
      expect(of(RecoveryState.authorized), VoicePaymentStatus.pending);
      expect(of(RecoveryState.failed), VoicePaymentStatus.failed);
      expect(of(RecoveryState.cancelled), VoicePaymentStatus.cancelled);
      expect(
        describeRecovery(
          PaymentRecoveryResult(
            recoverable: [recoverable(7, RecoveryState.captured)],
          ),
          7,
        ).message,
        contains('do not take payment again'),
      );
      expect(
        describeRecovery(
          const PaymentRecoveryResult(
            resolved: [ResolvedSale(saleId: 7, status: 'SALE_COMPLETED')],
          ),
          7,
        ).status,
        VoicePaymentStatus.paid,
      );
      expect(
        describeRecovery(
          const PaymentRecoveryResult(
            resolved: [ResolvedSale(saleId: 7, status: 'SALE_VOIDED')],
          ),
          7,
        ).status,
        VoicePaymentStatus.cancelled,
      );
      expect(
        describeRecovery(const PaymentRecoveryResult(), 7).status,
        VoicePaymentStatus.unpaid,
      );
      expect(
        describeRecovery(
          PaymentRecoveryResult(
            recoverable: [recoverable(8, RecoveryState.captured)],
          ),
          7,
        ).status,
        VoicePaymentStatus.unpaid,
        reason: "another sale's state is never used",
      );
    });

    test('read-only server view (no provider refresh); unreachable server or no service = unknown, never paid', () async {
      final cart = CartController(growingCart());
      addTearDown(cart.dispose);
      final recovery = FakeRecovery(
        (_) => PaymentRecoveryResult(
          recoverable: [recoverable(7, RecoveryState.pending)],
        ),
      );
      final pending = await voicePaymentOutcome(
        cart: cart,
        saleId: 7,
        recovery: recovery,
      );
      expect(pending.status, VoicePaymentStatus.pending);
      expect(recovery.asked, [
        [7],
      ]);
      recovery.fail = true;
      final down = await voicePaymentOutcome(
        cart: cart,
        saleId: 7,
        recovery: recovery,
      );
      expect(down.status, VoicePaymentStatus.unknown);
      expect(down.message, contains('Payment Recovery'));
      expect(
        (await voicePaymentOutcome(cart: cart, saleId: 7)).status,
        VoicePaymentStatus.unknown,
      );
      expect(
        (await voicePaymentOutcome(
          cart: cart,
          saleId: null,
          recovery: recovery,
        )).status,
        VoicePaymentStatus.unknown,
      );
    });
  });

  testWidgets(
    'end to end: speak the bill, say "yes" — the dialog closes, the EXISTING checkout opens, then the server payment status is shown',
    (tester) async {
      weightEnabled = true;
      final backend = FakeBackend(fakeServer);
      final speech = FakeRecognizer();
      final service = growingCart();
      final cart = CartController(service);
      addTearDown(cart.dispose);
      final recovery = FakeRecovery(
        (ids) => PaymentRecoveryResult(
          recoverable: [recoverable(ids.single, RecoveryState.noPayment)],
        ),
      );
      var checkoutOpened = 0;
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
                    recovery: recovery,
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
      speech.say('Jacky, bill two coffees');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('voice-awaiting-confirmation')),
        findsOneWidget,
      );
      expect(
        find.textContaining('Jacky'),
        findsNothing,
        reason: 'the name is never shown',
      );
      await tester.tap(find.text('Answer by voice'));
      await tester.pump();
      speech.say('Yes, confirm the bill.');
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(checkoutOpened, 1);
      expect(service.completeCalls, isEmpty);
      expect(find.byKey(const Key('voice-payment-status')), findsOneWidget);
      expect(
        find.text(
          'Voice bill: Unpaid — no payment has been taken for this bill.',
        ),
        findsOneWidget,
      );
      expect(recovery.asked, [
        [cart.sale!.id],
      ]);
    },
  );
}
