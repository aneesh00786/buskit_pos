// Phase 3B.1 — translation through the store server (Google Cloud
// Translation behind it). The SERVER is faked here (mock HTTP): no Google
// credentials, no live calls, no quota. Real translation quality is not
// tested by these tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/models/voice_language.dart';
import 'package:buskit_pos/features/voice/translation/api_translation_service.dart';
import 'package:buskit_pos/features/voice/translation/translation_controller.dart';
import 'package:buskit_pos/features/voice/translation/translation_service.dart';
import 'package:buskit_pos/features/voice/translation/translation_view.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'voice_bill_checkout_test.dart' show growingCart;
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, staffA;
import 'voice_phase2_orders_test.dart' show FakeOrders;
import 'voice_preview_test.dart' show FakeBackend;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

const en = VoiceLanguage.english;
const ml = VoiceLanguage.malayalam;

/// A fake STORE SERVER for /translation/translate.
class FakeServer {
  FakeServer(this.respond);
  (int, Map<String, dynamic>) Function(Map<String, dynamic> body) respond;
  final requests = <http.Request>[];
  Object? throwError;
  Completer<void>? hold;

  /// Phase 3B.1: GET /translation/languages (not recorded in [requests]).
  /// By default English and Malayalam both ways, so the older tests run.
  Map<String, dynamic> languages = {
    'available': true,
    'source_languages': ['en-US', 'ml-IN'],
    'target_languages': ['ml-IN', 'en-US'],
    'max_chars': 5000,
  };
  int languageCalls = 0;
  Object? languagesError;

  late final client = PosApiClient(
    baseUrl: 'http://pos.test',
    httpClient: MockClient((r) async {
      if (r.method == 'GET' && r.url.path.endsWith('/translation/languages')) {
        languageCalls++;
        if (languagesError != null) throw languagesError!;
        return http.Response(
          jsonEncode({'status_code': 200, 'status': true, 'data': languages}),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }
      requests.add(r);
      if (hold != null) await hold!.future;
      if (throwError != null) throw throwError!;
      final (status, envelope) = respond(
        jsonDecode(r.body) as Map<String, dynamic>,
      );
      return http.Response(
        jsonEncode(envelope),
        status,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }),
    tokenProvider: () => 'staff-token',
  );
  ApiTranslationService get service => ApiTranslationService(client);
}

(int, Map<String, dynamic>) translated(
  String text, {
  String s = 'en',
  String t = 'ml',
}) => (
  200,
  {
    'status_code': 200,
    'status': true,
    'message': 'Translated',
    'data': {
      'translated_text': text,
      'source_language': s,
      'target_language': t,
    },
  },
);
(int, Map<String, dynamic>) failure(
  int status,
  String code, [
  String message = 'failed',
]) => (
  status,
  {
    'status_code': status,
    'status': false,
    'message': message,
    'error_code': code,
  },
);

TranslationController controllerWith(
  TranslationService s, {
  SpeechRecognizer? recognizer,
}) => TranslationController(
  permission: FakeMicrophone()..current = VoicePermission.granted,
  recognizer: recognizer ?? FakeRecognizer(),
  service: s,
  tts: MockVoiceTtsService(),
);

void main() {
  group('Phase 3B.1 English-only: what the store server switched on', () {
    test('GET /translation/languages decides what is offered; unknown codes ignored; not set up / refused / unreachable -> none', () async {
      final server = FakeServer((b) => translated('x'))
        ..languages = {
          'available': true,
          'source_languages': ['en-US'],
          'target_languages': ['ml-IN', 'xx-YY'],
          'max_chars': 5000,
        };
      final s = await server.service.loadSupport();
      expect(s.available, isTrue);
      expect(s.sources, {en});
      expect(s.targets, {ml});
      expect(s.allows(en, ml), isTrue);
      expect(s.allows(ml, en), isFalse, reason: 'not switched on');
      expect(
        s.allows(en, en),
        isFalse,
        reason: 'English -> English is never translation',
      );
      expect(server.requests, isEmpty, reason: 'no translation was sent');

      server.languages = {
        'available': false,
        'source_languages': <String>[],
        'target_languages': <String>[],
        'max_chars': 5000,
      };
      expect((await server.service.loadSupport()).available, isFalse);
      final down = FakeServer((b) => translated('x'))
        ..languagesError = const SocketException('down');
      expect((await down.service.loadSupport()).available, isFalse);
    });

    test('controller: en -> ml translated through the server; the reply ml -> en is refused locally and never sent', () async {
      final server = FakeServer((b) => translated('രണ്ട് കാപ്പി'))
        ..languages = {
          'available': true,
          'source_languages': ['en-US'],
          'target_languages': ['ml-IN'],
          'max_chars': 5000,
        };
      final speech = FakeRecognizer();
      final c = TranslationController(
        permission: FakeMicrophone(),
        recognizer: speech,
        service: server.service,
      );
      addTearDown(c.dispose);
      c.setSourceText('two coffees');
      await c.translate();
      expect(c.translatedText, 'രണ്ട് കാപ്പി');
      expect(server.requests, hasLength(1));
      expect(c.canTranslateReplies, isFalse);
      await c.startListening(TranslationDirection.customerToStaff);
      speech.say('വേണം');
      await pumpEventQueue();
      await c.translate();
      expect(c.errorKind, TranslationErrorKind.unsupportedPair);
      expect(c.translatedText, isNull);
      expect(server.requests, hasLength(1), reason: 'nothing more was sent');
    });
  });

  group('server provider', () {
    test('English -> Malayalam: sends ONLY the reviewed text and the two language codes; shows the server translation', () async {
      final server = FakeServer((b) => translated('രണ്ട് കാപ്പി'));
      final r = await server.service.translate(
        const TranslationRequest(source: en, target: ml, text: 'two coffees'),
      );
      expect(r.text, 'രണ്ട് കാപ്പി');
      final req = server.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, endsWith('/translation/translate'));
      expect(jsonDecode(req.body), {
        'text': 'two coffees',
        'source_language': 'en-US',
        'target_language': 'ml-IN',
      });
      expect(
        req.headers['Authorization'],
        'Bearer staff-token',
        reason: 'the staff session identifies the caller',
      );
    });

    test('Malayalam -> English', () async {
      final server = FakeServer(
        (b) => translated('two coffees', s: 'ml', t: 'en'),
      );
      final r = await server.service.translate(
        const TranslationRequest(source: ml, target: en, text: 'രണ്ട് കാപ്പി'),
      );
      expect(r.text, 'two coffees');
      expect(
        jsonDecode(server.requests.single.body)['source_language'],
        'ml-IN',
      );
    });

    test(
      'every server error maps to a translation error — never a translation',
      () async {
        final cases = <((int, Map<String, dynamic>), TranslationErrorKind)>[
          (
            failure(422, 'POS_TRANSLATION_EMPTY'),
            TranslationErrorKind.emptyText,
          ),
          (
            failure(422, 'POS_TRANSLATION_SAME_LANGUAGE'),
            TranslationErrorKind.sameLanguage,
          ),
          (
            failure(422, 'POS_TRANSLATION_UNSUPPORTED_LANGUAGE'),
            TranslationErrorKind.unsupportedPair,
          ),
          (
            failure(422, 'POS_TRANSLATION_TOO_LONG'),
            TranslationErrorKind.tooLong,
          ),
          (
            failure(503, 'POS_TRANSLATION_UNAVAILABLE'),
            TranslationErrorKind.unavailable,
          ),
          (
            failure(503, 'POS_TRANSLATION_PROVIDER_DENIED'),
            TranslationErrorKind.permissionDenied,
          ),
          (
            failure(429, 'POS_TRANSLATION_RATE_LIMITED'),
            TranslationErrorKind.rateLimited,
          ),
          (
            failure(429, 'POS_TRANSLATION_BUSY'),
            TranslationErrorKind.rateLimited,
          ),
          (
            failure(504, 'POS_TRANSLATION_TIMEOUT'),
            TranslationErrorKind.timeout,
          ),
          (
            failure(502, 'POS_TRANSLATION_NETWORK'),
            TranslationErrorKind.network,
          ),
          (
            failure(502, 'POS_TRANSLATION_MALFORMED'),
            TranslationErrorKind.malformed,
          ),
          (
            failure(502, 'POS_TRANSLATION_UPSTREAM_ERROR'),
            TranslationErrorKind.upstream,
          ),
          (
            failure(502, 'POS_TRANSLATION_UPSTREAM_REJECTED'),
            TranslationErrorKind.upstream,
          ),
          (
            failure(403, 'POS_JACKY_NOT_LICENSED'),
            TranslationErrorKind.permissionDenied,
          ),
          (failure(429, 'X'), TranslationErrorKind.rateLimited),
          (failure(500, 'X'), TranslationErrorKind.upstream),
        ];
        for (final (answer, kind) in cases) {
          final r = await FakeServer((b) => answer).service.translate(
            const TranslationRequest(source: en, target: ml, text: 'hello'),
          );
          expect(
            (r.isTranslated, r.error),
            (false, kind),
            reason: '${answer.$2}',
          );
        }
      },
    );

    test('malformed success (missing / empty translated_text) is an error; a network failure too', () async {
      for (final data in [
        <String, dynamic>{},
        {'translated_text': '  '},
        {'translated_text': 7},
      ]) {
        final s = FakeServer(
          (b) => (200, {'status_code': 200, 'status': true, 'data': data}),
        ).service;
        expect(
          (await s.translate(
            const TranslationRequest(source: en, target: ml, text: 'hi'),
          )).error,
          TranslationErrorKind.malformed,
        );
      }
      final down = FakeServer((b) => translated('x'))
        ..throwError = const SocketException('down');
      expect(
        (await down.service.translate(
          const TranslationRequest(source: en, target: ml, text: 'hi'),
        )).error,
        TranslationErrorKind.network,
      );
      expect(
        ApiTranslationService.errorFor(
          const ApiException(kind: ApiErrorKind.timeout, message: 't'),
        ),
        TranslationErrorKind.timeout,
      );
    });
  });

  group('controller with the server provider', () {
    test(
      'failure keeps the source; retry after a transient error succeeds',
      () async {
        var calls = 0;
        final server = FakeServer(
          (b) => ++calls == 1
              ? failure(429, 'POS_TRANSLATION_BUSY')
              : translated('നന്ദി'),
        );
        final c = controllerWith(server.service)..setSourceText('thank you');
        addTearDown(c.dispose);
        await c.translate();
        expect(c.errorKind, TranslationErrorKind.rateLimited);
        expect(c.sourceText, 'thank you');
        expect(c.translatedText, isNull);
        await c.translate();
        expect(c.translatedText, 'നന്ദി');
      },
    );

    test('too long: refused before sending (same 5000-character limit as the server)', () async {
      final server = FakeServer((b) => translated('x'));
      final c = controllerWith(server.service)..setSourceText('a' * 5001);
      addTearDown(c.dispose);
      await c.translate();
      expect(c.errorKind, TranslationErrorKind.tooLong);
      expect(server.requests, isEmpty);
    });

    test('a language change or a cancel while the server is answering: the late answer is dropped; clear removes everything', () async {
      final server = FakeServer((b) => translated('late'))
        ..hold = Completer<void>();
      final c = controllerWith(server.service)..setSourceText('hello');
      addTearDown(c.dispose);
      final a = c.translate();
      await pumpEventQueue();
      c.setLanguages(staff: ml, customer: en);
      server.hold!.complete();
      await a;
      expect(c.translatedText, isNull);
      expect(c.sourceText, 'hello');
      server.hold = Completer<void>();
      final b = c.translate();
      await pumpEventQueue();
      await c.cancel();
      server.hold!.complete();
      await b;
      expect(c.translatedText, isNull);
      server.hold = null;
      await c.translate();
      expect(c.translatedText, 'late');
      await c.clear();
      expect((c.sourceText, c.translatedText), ('', null));
    });
  });

  testWidgets(
    'screen: speak, review, translate through the server, the real result shown; responsive',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final speech = FakeRecognizer();
      final server = FakeServer((b) => translated('ചൂടുള്ള ചായ വേണോ?'));
      final c = controllerWith(server.service, recognizer: speech);
      await tester.pumpWidget(
        MaterialApp(
          home: ChangeNotifierProvider.value(
            value: c,
            child: const TranslationView(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('translation-provider-unavailable')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('translation-staff-speak')));
      await tester.pump();
      speech.say('Would you like hot tea?');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('translation-translate')));
      await tester.pumpAndSettle();
      expect(find.text('ചൂടുള്ള ചായ വേണോ?'), findsOneWidget);
      expect(
        find.widgetWithText(TextField, 'Would you like hot tea?'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ISOLATION with the server provider: customer phrases go only to /translation/translate; billing untouched',
    (tester) async {
      weightEnabled = true;
      final billing = FakeBackend(fakeServer);
      final translationServer = FakeServer((b) => translated('translated'));
      final speech = FakeRecognizer();
      final service = growingCart();
      final cart = CartController(service);
      addTearDown(cart.dispose);
      final orders = FakeOrders();
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
                    previewService: ApiVoicePreviewService(billing.client),
                    scope: () => staffA,
                    orderService: orders,
                    translationService: translationServer.service,
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
      final billingRequests = billing.requests.length;
      await tester.tap(find.byKey(const Key('voice-translation-mode')));
      await tester.pumpAndSettle();
      for (final phrase in [
        'yes',
        'cancel',
        'add two coffees',
        'pay cash',
        'bill table 6',
        'bill order 1048',
      ]) {
        await tester.ensureVisible(
          find.byKey(const Key('translation-customer-speak')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('translation-customer-speak')));
        await tester.pump();
        speech.say(phrase);
        await tester.pumpAndSettle();
        await tester.ensureVisible(
          find.byKey(const Key('translation-translate')),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('translation-translate')));
        await tester.pumpAndSettle();
      }
      expect(
        translationServer.requests
            .map((r) => r.url.path.split('/').last)
            .toSet(),
        {'translate'},
      );
      expect(translationServer.requests, hasLength(6));
      expect(
        billing.requests.length,
        billingRequests,
        reason: 'no bill preview / correction',
      );
      expect(service.addCalls, isEmpty);
      expect(service.resumeCalls, isEmpty);
      expect(service.completeCalls, isEmpty);
      expect(orders.lookups, isEmpty);
      expect(orders.tableLookups, isEmpty);
      expect(checkout, 0);
      await tester.tap(find.byKey(const Key('translation-close')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('voice-awaiting-confirmation')),
        findsOneWidget,
      );
    },
  );
}
