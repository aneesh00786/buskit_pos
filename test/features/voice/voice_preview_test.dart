// Phase 13C-B — spoken quick bill -> backend preview -> verification card.
// The real ApiVoicePreviewService / PosApiClient run against a mock backend
// that records every request, so "nothing but the preview was called" is
// checked on the wire. (Confirm Bill -> cart: voice_bill_checkout_test.)
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/intent/voice_intent.dart';
import 'package:buskit_pos/features/voice/models/quick_bill_preview.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;

/// A recording mock of the POS backend. [respond] gets the decoded request
/// body and returns (status, envelope).
class FakeBackend {
  FakeBackend(this.respond);
  (int, Map<String, dynamic>) Function(Map<String, dynamic> body) respond;
  final requests = <http.Request>[];
  Object? throwError;
  int unauthorizedCalls = 0;

  late final client = PosApiClient(
    baseUrl: 'http://pos.test',
    httpClient: MockClient((r) async {
      requests.add(r);
      if (throwError != null) throw throwError!;
      final (status, envelope) = respond(
        jsonDecode(r.body) as Map<String, dynamic>,
      );
      return http.Response(
        jsonEncode(envelope),
        status,
        headers: {'content-type': 'application/json'},
      );
    }),
    tokenProvider: () => 'staff-token',
    onUnauthorized: (_) => unauthorizedCalls++,
  );

  Map<String, dynamic> get lastBody =>
      jsonDecode(requests.last.body) as Map<String, dynamic>;
}

Map<String, dynamic> ok(Object data) => {
  'status_code': 200,
  'status': true,
  'message': 'Quick bill preview',
  'data': data,
};

Map<String, dynamic> fail(
  int status,
  String message, {
  String? code,
  Object? data,
}) => {
  'status_code': status,
  'status': false,
  'message': message,
  'error_code': ?code,
  'data': data,
};

Map<String, dynamic> line(
  int index,
  String name,
  String? variant,
  num qty, {
  String? unit,
  String mode = 'PIECE',
  required num price,
  required num tax,
  required num total,
  bool incl = false,
}) => {
  'item_index': index,
  'status': 'RESOLVED',
  'product_variation_id': 9900 + index,
  'product_id': 'P-$index',
  'product_name': name,
  'variant_name': variant,
  'barcode': null,
  'selling_mode': mode,
  'quantity': qty,
  'unit': unit,
  'unit_price': price,
  'price_source': 'catalogue',
  'tax_percent': 5,
  'tax_included': incl,
  'line_subtotal': incl ? total - tax : total - tax,
  'tax': tax,
  'line_total': total,
};

/// "Bill two coffees and one water" priced by the server; ids echoed.
(int, Map<String, dynamic>) readyCoffeeWater(Map<String, dynamic> b) => (
  200,
  ok({
    'status': 'READY',
    'voice_session_id': b['voice_session_id'],
    'request_id': b['request_id'],
    'recognized_text': b['recognized_text'],
    'items': [
      line(0, 'Coffee', 'Regular', 2, price: 4.5, tax: 0.45, total: 9.45),
      line(1, 'Water', '1 L', 1, price: 18, tax: 0.857, total: 18, incl: true),
    ],
    'issues': [],
    'subtotal': 26.593,
    'tax': 1.307,
    'total': 27.45,
    'pricing_note': 'Current POS prices and tax; promotions, loyalty and discounts are applied at checkout.',
  }),
);

/// "coffee" names two products: the server asks, it does not pick.
(int, Map<String, dynamic>) unclearCoffee(Map<String, dynamic> b) => (
  200,
  ok({
    'status': 'NEEDS_CLARIFICATION',
    'voice_session_id': b['voice_session_id'],
    'request_id': b['request_id'],
    'recognized_text': b['recognized_text'],
    'items': [
      line(1, 'Water', '1 L', 1, price: 18, tax: 0.857, total: 18, incl: true),
    ],
    'issues': [
      {
        'item_index': 0,
        'status': 'NEEDS_CLARIFICATION',
        'code': 'MULTIPLE_PRODUCT_MATCHES',
        'message': "More than one product matches 'coffee'. Which one?",
        'product_query': 'coffee',
        'variant_query': null,
        'candidates': [
          {
            'product_variation_id': 9901,
            'product_name': 'Coffee',
            'variant_name': 'Large',
            'selling_mode': 'PIECE',
          },
          {
            'product_variation_id': 9902,
            'product_name': 'Coffee',
            'variant_name': 'Small',
            'selling_mode': 'PIECE',
          },
        ],
      },
    ],
    'subtotal': null,
    'tax': null,
    'total': null,
    'pricing_note': 'x',
  }),
);

VoiceController controllerFor(FakeBackend backend, FakeRecognizer speech) =>
    VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: speech,
      scope: () => staffA,
      previewService: ApiVoicePreviewService(backend.client),
    );

/// Speaks [text] through the controller and waits for intent + preview.
Future<void> speak(
  VoiceController v,
  FakeRecognizer speech,
  String text,
) async {
  await v.start();
  speech.say(text);
  await pumpEventQueue();
}

void main() {
  group('API client + controller', () {
    test('sends ONLY what was said and the voice ids — no price, tax, product id or scope; ids preserved end to end', () async {
      final backend = FakeBackend(readyCoffeeWater);
      final speech = FakeRecognizer();
      final v = controllerFor(backend, speech);
      addTearDown(v.dispose);
      await speak(v, speech, 'Bill two large coffees and 1.5 kg rice');

      expect(backend.requests, hasLength(1));
      final r = backend.requests.single;
      expect(r.method, 'POST');
      expect(r.url.path, endsWith('/voice/quick-bill/preview'));
      expect(r.headers['Authorization'], 'Bearer staff-token');
      final body = backend.lastBody;
      expect(body.keys.toSet(), {
        'intent',
        'voice_session_id',
        'request_id',
        'recognized_text',
        'items',
      });
      expect(body['intent'], 'CREATE_QUICK_BILL');
      expect(body['voice_session_id'], v.session!.voiceSessionId);
      expect(body['request_id'], v.request!.requestId);
      expect(body['recognized_text'], 'Bill two large coffees and 1.5 kg rice');
      expect(body['items'], [
        {'product_query': 'coffee', 'variant_query': 'large', 'quantity': 2},
        {'product_query': 'rice', 'quantity': 1.5, 'unit': 'kg'},
      ]);

      // The answer is tied to the same session / request.
      expect(v.previewState, VoicePreviewState.loaded);
      expect(v.preview!.voiceSessionId, v.session!.voiceSessionId);
      expect(v.preview!.requestId, v.request!.requestId);
    });

    test('a response for a different request id is not shown (no stale or foreign preview)', () async {
      final backend = FakeBackend((b) {
        final (s, env) = readyCoffeeWater(b);
        (env['data'] as Map)['request_id'] = 'someone-else';
        return (s, env);
      });
      final speech = FakeRecognizer();
      final v = controllerFor(backend, speech);
      addTearDown(v.dispose);
      await speak(v, speech, 'Bill two coffees and one water');
      expect(v.previewState, VoicePreviewState.failed);
      expect(v.preview, isNull);
      expect(v.previewError, contains('did not match this request'));
    });

    test('only CREATE_QUICK_BILL is previewed: clarification / unknown intents send nothing', () async {
      final backend = FakeBackend(readyCoffeeWater);
      final speech = FakeRecognizer();
      final v = controllerFor(backend, speech);
      addTearDown(v.dispose);
      for (final t in ['Bill some coffee', 'Bill two', 'what time is it']) {
        await speak(v, speech, t);
        expect(v.previewState, VoicePreviewState.none, reason: t);
      }
      expect(backend.requests, isEmpty);
    });

    group('API errors -> safe messages', () {
      Future<VoiceController> failWith(FakeBackend backend) async {
        final speech = FakeRecognizer();
        final v = controllerFor(backend, speech);
        addTearDown(v.dispose);
        await speak(v, speech, 'Bill two coffees');
        expect(v.previewState, VoicePreviewState.failed);
        expect(v.preview, isNull);
        return v;
      }

      test('401: the existing session-expiry handling is triggered', () async {
        final backend = FakeBackend((_) => (401, fail(401, 'Invalid token')));
        final v = await failWith(backend);
        expect(backend.unauthorizedCalls, 1);
        expect(v.previewError, 'Invalid token');
        expect(v.previewRetryable, isFalse);
      });

      test('403: the shared permission wording', () async {
        final v = await failWith(
          FakeBackend(
            (_) => (
              403,
              fail(
                403,
                'Forbidden',
                code: 'POS_PERMISSION_DENIED',
                data: {'permission': 'sales.edit_current'},
              ),
            ),
          ),
        );
        expect(
          v.previewError,
          'You do not have permission to change this sale. Ask a manager or administrator.',
        );
      });

      test(
        'network / timeout: a clear retry message; Retry re-sends the same lines in the SAME session with a NEW request id (Phase 15A)',
        () async {
          final backend = FakeBackend(readyCoffeeWater)
            ..throwError = const SocketException('down');
          final v = await failWith(backend);
          expect(
            v.previewError,
            'Could not reach the server to check this bill. Check the connection and tap Retry.',
          );
          expect(v.previewRetryable, isTrue);
          final first = backend.lastBody;
          backend.throwError = null;
          await v.retryPreview();
          expect(v.previewState, VoicePreviewState.loaded);
          expect(
            backend.lastBody['voice_session_id'],
            first['voice_session_id'],
          );
          expect(backend.lastBody['request_id'], isNot(first['request_id']));
          expect(backend.lastBody['items'], first['items']);
          expect(v.preview!.requestId, v.request!.requestId);
        },
      );

      test('422: the validation message', () async {
        final v = await failWith(
          FakeBackend(
            (_) => (
              422,
              fail(
                422,
                'items[0].quantity must be a positive number',
                code: 'POS_VOICE_PREVIEW_INVALID',
              ),
            ),
          ),
        );
        expect(
          v.previewError,
          'This request could not be checked: items[0].quantity must be a positive number',
        );
        expect(v.previewRetryable, isFalse);
      });

      test(
        '409 shows the backend message; 500 never shows server text',
        () async {
          var v = await failWith(
            FakeBackend((_) => (409, fail(409, 'The shift is closed.'))),
          );
          expect(v.previewError, 'The shift is closed.');
          v = await failWith(
            FakeBackend(
              (_) => (
                500,
                fail(
                  500,
                  "ER_BAD_FIELD_ERROR: Unknown column 'x' at pos_sales",
                ),
              ),
            ),
          );
          expect(v.previewError, isNot(contains('ER_')));
          expect(v.previewError, isNot(contains('pos_sales')));
          expect(v.previewRetryable, isTrue);
        },
      );

      test(
        'an unusable 200 response is an error, never a partial bill',
        () async {
          final v = await failWith(
            FakeBackend((b) => (200, ok({'status': 'READY'}))),
          );
          expect(v.previewError, contains('could not be read'));
        },
      );
    });
  });

  group('models', () {
    test(
      'READY parses exact server values; a READY without totals is rejected',
      () {
        final (_, env) = readyCoffeeWater({
          'voice_session_id': 's',
          'request_id': 'r',
          'recognized_text': 't',
        });
        final p = QuickBillPreview.fromJson(env['data'])!;
        expect(p.isReady, isTrue);
        expect(p.items.map((l) => (l.productName, l.quantity, l.lineTotal)), [
          ('Coffee', 2, 9.45),
          ('Water', 1, 18.0),
        ]);
        expect((p.subtotal, p.tax, p.total), (26.593, 1.307, 27.45));
        final noTotal = Map<String, dynamic>.from(env['data'] as Map)
          ..['total'] = null;
        expect(QuickBillPreview.fromJson(noTotal), isNull);
      },
    );
  });

  group('verification screen', () {
    late FakeBackend backend;
    late FakeRecognizer speech;
    late VoiceController voice;

    Future<void> show(WidgetTester tester, String spoken) async {
      speech = FakeRecognizer();
      voice = controllerFor(backend, speech);
      addTearDown(voice.dispose);
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
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
    }

    String textOf(WidgetTester tester, String key) =>
        tester.widget<Text>(find.byKey(Key(key))).data!;

    testWidgets(
      'READY with several products: request, product/variant, quantity, unit price, tax, line totals, subtotal, tax, total',
      (tester) async {
        backend = FakeBackend(readyCoffeeWater);
        await show(tester, 'Bill two coffees and one water');

        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);
        expect(
          textOf(tester, 'voice-preview-said'),
          'You said: "Bill two coffees and one water"',
        );
        expect(
          textOf(tester, 'voice-preview-line-0-name'),
          '2 × Coffee — Regular',
        );
        expect(
          textOf(tester, 'voice-preview-line-0-detail'),
          'Unit price 4.50 · Tax 0.45 (5%)',
        );
        expect(textOf(tester, 'voice-preview-line-0-total'), '9.45');
        expect(textOf(tester, 'voice-preview-line-1-name'), '1 × Water — 1 L');
        expect(
          textOf(tester, 'voice-preview-line-1-detail'),
          'Unit price 18.00 · Tax 0.857 (5% incl.)',
        );
        expect(textOf(tester, 'voice-preview-line-1-total'), '18.00');
        Finder amount(String key) => find.descendant(
          of: find.byKey(Key(key)),
          matching: find.byType(Text),
        );
        expect(
          tester.widget<Text>(amount('voice-preview-subtotal').last).data,
          '26.593',
        );
        expect(
          tester.widget<Text>(amount('voice-preview-tax').last).data,
          '1.307',
        );
        expect(
          tester.widget<Text>(amount('voice-preview-total').last).data,
          '27.45',
        );
        expect(find.byKey(const Key('voice-preview-note')), findsOneWidget);
        for (final k in [
          'voice-confirm-bill',
          'voice-speak-again',
          'voice-cancel-bill',
        ]) {
          expect(find.byKey(Key(k)), findsOneWidget, reason: k);
        }
        expect(find.text('Edit / Speak Again'), findsOneWidget);
      },
    );

    testWidgets(
      'exact quantity / unit: 1.25 kg of a WEIGHT product is shown as said, priced by the server',
      (tester) async {
        backend = FakeBackend(
          (b) => (
            200,
            ok({
              'status': 'READY',
              'voice_session_id': b['voice_session_id'],
              'request_id': b['request_id'],
              'recognized_text': b['recognized_text'],
              'items': [
                line(
                  0,
                  'Loose Rice',
                  'Per kg',
                  1.25,
                  unit: 'kg',
                  mode: 'WEIGHT',
                  price: 89.99,
                  tax: 0,
                  total: 112.488,
                ),
              ],
              'issues': [],
              'subtotal': 112.488,
              'tax': 0,
              'total': 112.488,
            }),
          ),
        );
        await show(tester, 'Bill 1.25 kg rice');
        expect(backend.lastBody['items'], [
          {'product_query': 'rice', 'quantity': 1.25, 'unit': 'kg'},
        ]);
        expect(
          textOf(tester, 'voice-preview-line-0-name'),
          '1.25 kg × Loose Rice — Per kg',
        );
        expect(textOf(tester, 'voice-preview-line-0-total'), '112.488');
      },
    );

    testWidgets(
      'NEEDS_CLARIFICATION: the unclear line, the backend message and the candidates — none chosen, no total, no Confirm',
      (tester) async {
        backend = FakeBackend(unclearCoffee);
        await show(tester, 'Bill two coffees and one water');

        expect(find.byKey(const Key('voice-preview-unclear')), findsOneWidget);
        expect(find.text('"coffee"'), findsOneWidget);
        expect(
          textOf(tester, 'voice-preview-issue-0-message'),
          "More than one product matches 'coffee'. Which one?",
        );
        expect(textOf(tester, 'voice-candidate-0-0'), '• Coffee — Large');
        expect(textOf(tester, 'voice-candidate-0-1'), '• Coffee — Small');
        // The clear line is still shown; nothing is totalled or confirmable.
        expect(find.byKey(const Key('voice-preview-line-1')), findsOneWidget);
        expect(find.byKey(const Key('voice-preview-total')), findsNothing);
        expect(find.byKey(const Key('voice-confirm-bill')), findsNothing);
        expect(find.text('Speak Again'), findsOneWidget);

        // A candidate is not a choice: tapping it changes nothing, sends nothing.
        await tester.tap(find.byKey(const Key('voice-candidate-0-0')));
        await tester.pumpAndSettle();
        expect(backend.requests, hasLength(1));
        expect(voice.preview!.isReady, isFalse);
        expect(find.byKey(const Key('voice-confirm-bill')), findsNothing);
      },
    );

    testWidgets(
      'without a cart (the Settings developer entry) Confirm Bill sends nothing and says where to bill from',
      (tester) async {
        backend = FakeBackend(readyCoffeeWater);
        await show(tester, 'Bill two coffees and one water');
        await tester.tap(find.byKey(const Key('voice-confirm-bill')));
        await tester.pumpAndSettle();

        expect(voice.billState, VoiceBillState.none);
        expect(find.text(VoiceController.noCartMessage), findsOneWidget);
        expect(backend.requests.map((r) => r.url.path), [
          endsWith('/voice/quick-bill/preview'),
        ]);
        expect(
          backend.requests.where(
            (r) =>
                r.url.path.contains('/sales') || r.url.path.contains('payment'),
          ),
          isEmpty,
        );
      },
    );

    testWidgets(
      'Edit / Speak Again returns to listening in the same voice session with a new request; Cancel clears the bill',
      (tester) async {
        backend = FakeBackend(readyCoffeeWater);
        await show(tester, 'Bill two coffees and one water');
        final sessionId = voice.session!.voiceSessionId;
        final firstRequest = voice.request!.requestId;

        await tester.tap(find.byKey(const Key('voice-speak-again')));
        await tester.pump();
        expect(voice.state, VoiceState.listening);
        expect(speech.listenCalls, 2);
        expect(voice.preview, isNull);
        expect(voice.intent, isNull);
        expect(find.byKey(const Key('voice-preview-ready')), findsNothing);
        expect(voice.session!.voiceSessionId, sessionId);
        expect(voice.request!.requestId, isNot(firstRequest));

        speech.say('Bill one water');
        await tester.pumpAndSettle();
        expect(backend.lastBody['request_id'], voice.request!.requestId);
        expect(backend.lastBody['voice_session_id'], sessionId);
        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);

        await tester.tap(find.byKey(const Key('voice-cancel-bill')));
        await tester.pumpAndSettle();
        expect(voice.state, VoiceState.idle);
        expect(voice.preview, isNull);
        expect(find.byKey(const Key('voice-preview-ready')), findsNothing);
        expect(backend.requests, hasLength(2));
      },
    );

    testWidgets(
      'a network failure shows the retry message and Retry; nothing internal is shown',
      (tester) async {
        backend = FakeBackend(readyCoffeeWater)
          ..throwError = const SocketException('connection refused 10.0.0.5');
        await show(tester, 'Bill two coffees');
        expect(
          textOf(tester, 'voice-preview-error'),
          'Could not reach the server to check this bill. Check the connection and tap Retry.',
        );
        expect(find.textContaining('10.0.0.5'), findsNothing);
        backend.throwError = null;
        await tester.tap(find.byKey(const Key('voice-preview-retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('voice-preview-ready')), findsOneWidget);
      },
    );
  });

  test('the intent type wire value is what the backend expects', () {
    expect(VoiceIntentType.createQuickBill.wire, 'CREATE_QUICK_BILL');
  });
}
