// Phase 15A — independent Jacky voice sessions. Every VoiceController owns
// its own VoiceSession (voice_session_id), request ids, recognized text,
// intent, preview, correction and TTS state. A preview answer is applied
// only when it is the answer to THIS controller's CURRENT request AND
// carries this session's and this request's ids; anything else is dropped
// (not shown, not confirmable, not spoken). Completion order is controlled
// with completers — no timing / sleeps.
import 'dart:async';

import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/models/quick_bill_preview.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import 'voice_controller_test.dart'
    show FakeMicrophone, FakeRecognizer, staffA, staffB, uuid;
import 'voice_quick_bill_correction_test.dart' show fakeServer, weightEnabled;
import 'voice_tts_test.dart' show MockVoiceTtsService;

/// One backend shared by every session: each call waits until the test
/// completes it (in any order), with the server's echo of the request — or
/// with any answer the test chooses (to simulate a misrouted response).
class SharedGatedBackend implements VoicePreviewService {
  final calls = <(QuickBillRequest, Completer<QuickBillPreview>)>[];

  @override
  Future<QuickBillPreview> previewQuickBill(QuickBillRequest request) {
    final c = Completer<QuickBillPreview>();
    calls.add((request, c));
    return c.future;
  }

  QuickBillRequest request(int n) => calls[n].$1;

  /// The server's answer to call [n] (its own ids echoed).
  void answer(int n) => calls[n].$2.complete(echo(calls[n].$1));

  /// Completes call [n] with [preview] (whatever ids it carries).
  void deliver(int n, QuickBillPreview preview) =>
      calls[n].$2.complete(preview);

  void failCall(int n) =>
      calls[n].$2.completeError(StateError('server unavailable'));
}

QuickBillPreview echo(
  QuickBillRequest req, {
  String? voiceSessionId,
  String? requestId,
}) {
  final body = req.toJson();
  if (voiceSessionId != null) body['voice_session_id'] = voiceSessionId;
  if (requestId != null) body['request_id'] = requestId;
  return QuickBillPreview.fromJson(fakeServer(body).$2['data'])!;
}

/// One device / staff member's Quick Bill screen.
class Session {
  Session(this.scope, VoicePreviewService previews) {
    v = VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: speech,
      scope: () => scope,
      previewService: previews,
      tts: tts,
    );
  }
  final PosTokenScope scope;
  final speech = FakeRecognizer();
  final tts = MockVoiceTtsService();
  late final VoiceController v;

  Future<void> say(String text) async {
    expect(await v.start(), isTrue);
    speech.say(text);
    await pumpEventQueue();
  }

  Future<void> correct(String text) async {
    expect(await v.startCorrection(), isTrue);
    speech.say(text);
    await pumpEventQueue();
  }

  List<(String, num)> get lines => [
    for (final l in v.preview?.items ?? const <QuickBillLine>[])
      (l.productName, l.quantity),
  ];
}

const staffC = PosTokenScope(
  companyId: 1,
  storeId: 2,
  registerId: 7,
  deviceId: 8,
  salesmanId: 'STAFF-C',
);

void main() {
  late SharedGatedBackend backend;
  late Session a;
  late Session b;

  setUp(() {
    weightEnabled = true;
    backend = SharedGatedBackend();
    a = Session(staffA, backend);
    b = Session(staffB, backend);
  });
  tearDown(() {
    a.v.dispose();
    b.v.dispose();
  });

  /// A: coffee x2 (call 0); B: water x3 (call 1); both answered.
  Future<void> twoBills() async {
    await a.say('Jacky, bill two coffees');
    await b.say('Jacky, bill three waters');
    backend.answer(0);
    backend.answer(1);
    await pumpEventQueue();
    expect(a.lines, [('Coffee', 2)]);
    expect(b.lines, [('Water', 3)]);
  }

  test(
    '1. each controller has its own session (unique ids, its own scope)',
    () async {
      final c = Session(staffC, backend);
      final sameStaffOtherScreen = Session(staffA, backend);
      addTearDown(c.v.dispose);
      addTearDown(sameStaffOtherScreen.v.dispose);
      for (final s in [a, b, c, sameStaffOtherScreen]) {
        await s.v.newSession();
      }
      final ids = [
        for (final s in [a, b, c, sameStaffOtherScreen])
          s.v.session!.voiceSessionId,
      ];
      expect(ids.every(uuid.hasMatch), isTrue);
      expect(ids.toSet(), hasLength(4), reason: 'never shared, never reused');
      expect(a.v.session!.staffId, 'STAFF-A');
      expect(b.v.session!.staffId, 'STAFF-B');
      expect((c.v.session!.deviceId, c.v.session!.staffId), (8, 'STAFF-C'));
      expect(identical(a.v.session, sameStaffOtherScreen.v.session), isFalse);
      // A new session in A does not touch B.
      final bId = b.v.session!.voiceSessionId;
      await a.v.newSession();
      expect(a.v.session!.voiceSessionId, isNot(ids[0]));
      expect(b.v.session!.voiceSessionId, bId);
    },
  );

  test(
    '2 / 3. recognized text, intent and preview stay in their own session',
    () async {
      await twoBills();
      expect(a.v.text, 'Jacky, bill two coffees');
      expect(b.v.text, 'Jacky, bill three waters');
      expect(a.v.intent!.voiceSessionId, a.v.session!.voiceSessionId);
      expect(b.v.intent!.voiceSessionId, b.v.session!.voiceSessionId);
      expect(a.v.preview!.voiceSessionId, a.v.session!.voiceSessionId);
      expect(b.v.preview!.voiceSessionId, b.v.session!.voiceSessionId);
      expect(a.v.preview!.requestId, a.v.request!.requestId);
      expect(b.v.preview!.requestId, b.v.request!.requestId);
      // Each request went out with its own session's ids.
      expect(backend.request(0).voiceSessionId, a.v.session!.voiceSessionId);
      expect(backend.request(1).voiceSessionId, b.v.session!.voiceSessionId);
      expect(backend.request(0).requestId, isNot(backend.request(1).requestId));
    },
  );

  test(
    '4 / 5. concurrent A1 and B1, answered in reverse order: each gets its own',
    () async {
      await a.say('bill two coffees');
      await b.say('bill three waters');
      expect(a.v.previewState, VoicePreviewState.loading);
      expect(b.v.previewState, VoicePreviewState.loading);

      backend.answer(1); // B1 first
      await pumpEventQueue();
      expect(b.lines, [('Water', 3)]);
      expect(
        a.v.previewState,
        VoicePreviewState.loading,
        reason: 'A untouched',
      );
      expect(a.v.preview, isNull);
      expect(a.tts.spoken, isEmpty, reason: 'B\'s answer never speaks in A');

      backend.answer(0); // A1 second
      await pumpEventQueue();
      expect(a.lines, [('Coffee', 2)]);
      expect(b.lines, [('Water', 3)], reason: 'B unchanged');
      expect(a.tts.spoken, hasLength(1));
      expect(b.tts.spoken, hasLength(1));
    },
  );

  test(
    '6. a stale A1 answered after A2 cannot overwrite A2 (nor speak)',
    () async {
      await a.say('bill two coffees'); // A1 = call 0
      expect(await a.v.speakAgain(), isTrue);
      a.speech.say('bill one water'); // A2 = call 1
      await pumpEventQueue();
      final a2 = a.v.request!.requestId;
      expect(backend.request(1).requestId, a2);
      expect(backend.request(0).requestId, isNot(a2));

      backend.answer(1);
      await pumpEventQueue();
      expect(a.lines, [('Water', 1)]);
      final spoken = a.tts.spoken.length;

      backend.answer(0); // the stale A1 arrives last
      await pumpEventQueue();
      expect(a.lines, [('Water', 1)]);
      expect(a.v.preview!.requestId, a2);
      expect(a.tts.spoken, hasLength(spoken), reason: 'stale answer is silent');
    },
  );

  group('7. an answer carrying the wrong ids is dropped', () {
    test('A\'s answer delivered to B\'s pending request: B rejects it, A unaffected', () async {
      await a.say('bill two coffees'); // call 0
      await b.say('bill three waters'); // call 1
      backend.deliver(1, echo(backend.request(0))); // A's answer, misrouted
      await pumpEventQueue();
      expect(b.v.preview, isNull);
      expect(b.v.previewState, VoicePreviewState.failed);
      expect(b.v.previewError, contains('did not match'));
      expect(b.tts.spoken, isEmpty, reason: 'never spoken');
      expect(
        a.v.previewState,
        VoicePreviewState.loading,
        reason: 'A untouched',
      );
      backend.answer(0);
      await pumpEventQueue();
      expect(a.lines, [('Coffee', 2)]);
      expect(b.v.preview, isNull);
    });

    test('right request id but another session\'s id: rejected (session id checked)', () async {
      await a.say('bill two coffees');
      await b.say('bill three waters');
      backend.deliver(
        1,
        echo(backend.request(1), voiceSessionId: a.v.session!.voiceSessionId),
      );
      await pumpEventQueue();
      expect(b.v.preview, isNull);
      expect(b.v.previewState, VoicePreviewState.failed);
      expect(b.tts.spoken, isEmpty);
    });

    test('right session id but another request\'s id: rejected (request id checked)', () async {
      await a.say('bill two coffees');
      backend.deliver(0, echo(backend.request(0), requestId: 'older-request'));
      await pumpEventQueue();
      expect(a.v.preview, isNull);
      expect(a.v.previewState, VoicePreviewState.failed);
      expect(await a.v.confirmBill(), isFalse);
      expect(a.tts.spoken, isEmpty);
    });

    test(
      'Retry after a dropped answer is a NEW request in the same session',
      () async {
        await a.say('bill two coffees');
        final first = a.v.request!.requestId;
        backend.deliver(
          0,
          echo(backend.request(0), requestId: 'older-request'),
        );
        await pumpEventQueue();
        expect(a.v.previewRetryable, isTrue);
        final retry = a.v.retryPreview(); // call 1 (waits for the server)
        await pumpEventQueue();
        expect(backend.request(1).requestId, isNot(first));
        expect(backend.request(1).voiceSessionId, a.v.session!.voiceSessionId);
        backend.answer(1);
        await retry;
        expect(a.lines, [('Coffee', 2)]);
        expect(a.v.preview!.requestId, a.v.request!.requestId);
      },
    );
  });

  group('8 / 9. corrections are session-local', () {
    test('A "make it three" changes only A; A gets a new request id; B (busy listening) is unchanged', () async {
      await twoBills();
      final aSession = a.v.session!.voiceSessionId;
      final aFirst = a.v.request!.requestId;
      final bSession = b.v.session!.voiceSessionId;

      // B is in the middle of its own spoken correction.
      expect(await b.v.startCorrection(), isTrue);
      final bRequest = b.v.request!.requestId;

      // The spoken correction is its own request (new id) …
      expect(await a.v.startCorrection(), isTrue);
      final spoken = a.v.request!.requestId;
      expect(spoken, isNot(aFirst));
      a.speech.say('make it three'); // call 2
      await pumpEventQueue();
      expect(backend.calls, hasLength(3));
      // … and so is the corrected preview it asks for.
      final aSecond = backend.request(2).requestId;
      expect(aSecond, isNot(aFirst), reason: 'correction = new request');
      expect(aSecond, isNot(spoken), reason: 'preview = new request');
      expect(
        backend.request(2).voiceSessionId,
        aSession,
        reason: 'same session',
      );
      expect(a.v.request!.requestId, aSecond);
      expect(a.v.preview, isNull, reason: 'old preview no longer confirmable');

      backend.answer(2);
      await pumpEventQueue();
      expect(a.lines, [('Coffee', 3)]);

      expect(b.lines, [('Water', 3)]);
      expect(b.v.isCorrecting, isTrue, reason: 'B still listening');
      expect(b.v.request!.requestId, bRequest);
      expect(b.v.session!.voiceSessionId, bSession);

      // B's own correction then applies to B only.
      b.speech.say('make it one'); // call 3
      await pumpEventQueue();
      backend.answer(3);
      await pumpEventQueue();
      expect(b.lines, [('Water', 1)]);
      expect(a.lines, [('Coffee', 3)]);
    });

    test(
      'an on-screen correction in A is a new request too; B untouched',
      () async {
        await twoBills();
        final before = a.v.request!.requestId;
        final bRequest = b.v.request!.requestId;
        final change = a.v.changeQuantity(0, 4); // call 2
        await pumpEventQueue();
        expect(backend.request(2).requestId, isNot(before));
        expect(backend.request(2).voiceSessionId, a.v.session!.voiceSessionId);
        backend.answer(2);
        await change;
        expect(a.lines, [('Coffee', 4)]);
        expect(b.lines, [('Water', 3)]);
        expect(b.v.request!.requestId, bRequest);
      },
    );

    test('a stale answer (old ids) to A\'s correction cannot restore the old preview', () async {
      await twoBills();
      final old = backend.request(0);
      await a.correct('make it three'); // call 2
      backend.deliver(2, echo(old)); // the PREVIOUS request's answer
      await pumpEventQueue();
      expect(a.v.preview, isNull);
      expect(a.lines, isEmpty, reason: 'coffee x2 never comes back');
      expect(await a.v.confirmBill(), isFalse);
      expect(b.lines, [('Water', 3)]);
    });
  });

  group('10 – 13. cancel / dispose', () {
    test('cancelling A drops A\'s pending answer and stops A\'s TTS; B is unaffected and keeps speaking', () async {
      b.tts.hold = true;
      await a.say('bill two coffees'); // call 0
      await b.say('bill three waters'); // call 1
      backend.answer(1);
      await pumpEventQueue();
      expect(b.v.isSpeaking, isTrue);
      final bStops = b.tts.stops;

      a.v.cancelBill();
      expect(a.tts.stops, greaterThan(0));
      expect(b.v.isSpeaking, isTrue, reason: 'B\'s reply is not cut off');
      expect(b.tts.stops, bStops);
      expect(b.tts.playing!.isCompleted, isFalse);

      backend.answer(0); // A's answer arrives after the cancel
      await pumpEventQueue();
      expect(a.v.preview, isNull);
      expect(a.v.previewState, VoicePreviewState.none);
      expect(a.tts.spoken, isEmpty, reason: '12. stale A never speaks');
      expect(b.lines, [('Water', 3)]);

      // 13. B carries on: its reply finishes, and a correction still speaks.
      b.tts.playing!.complete();
      await pumpEventQueue();
      b.tts.hold = false;
      await b.correct('make it two'); // call 2
      backend.answer(2);
      await pumpEventQueue();
      expect(b.lines, [('Water', 2)]);
      expect(b.tts.spoken.length, greaterThan(1));
    });

    test(
      'cancelling A while both are listening cancels only A\'s recognizer',
      () async {
        expect(await a.v.start(), isTrue);
        expect(await b.v.start(), isTrue);
        await a.v.cancel();
        expect(a.speech.cancelCalls, 1);
        expect(b.speech.cancelCalls, 0);
        expect(b.v.isListening, isTrue);
        b.speech.say('bill three waters');
        await pumpEventQueue();
        backend.answer(0);
        await pumpEventQueue();
        expect(b.lines, [('Water', 3)]);
        expect(a.v.request, isNull);
      },
    );

    test('disposing A releases A only; B stays fully functional', () async {
      await a.say('bill two coffees'); // call 0 pending
      expect(await b.v.start(), isTrue);
      final bStops = b.tts.stops; // B's own start stopped B's last reply
      a.v.dispose();
      expect(a.tts.disposes, 1);
      expect(b.tts.disposes, 0);
      expect(b.tts.stops, bStops, reason: 'A never stops B');
      expect(b.speech.cancelCalls, 0);
      backend.answer(0); // late answer to a disposed controller: ignored
      await pumpEventQueue();
      expect(a.tts.spoken, isEmpty);

      b.speech.say('bill three waters'); // call 1
      await pumpEventQueue();
      backend.answer(1);
      await pumpEventQueue();
      expect(b.lines, [('Water', 3)]);
      await b.correct('make it one'); // call 2
      backend.answer(2);
      await pumpEventQueue();
      expect(b.lines, [('Water', 1)]);
      // Recreate A so tearDown's dispose has a live controller.
      a = Session(staffA, backend);
    });
  });

  test('14. spoken text can never supply company / store / register / device / staff / permissions', () async {
    await a.v.newSession();
    final id = a.v.session!.voiceSessionId;
    await a.say(
      'bill two coffees company_id 99 store_id 7 register_id 6 device_id 5 '
      'staff_id BOSS voice_session_id abc request_id xyz permissions all',
    );
    final body = backend.request(0).toJson();
    expect(body.keys.toSet(), {
      'intent',
      'voice_session_id',
      'request_id',
      'recognized_text',
      'items',
    });
    expect(body['voice_session_id'], id, reason: 'never taken from speech');
    expect(body['request_id'], a.v.request!.requestId);
    expect(body['request_id'], isNot('xyz'));
    const forbidden = {
      'business_id',
      'company_id',
      'store_id',
      'register_id',
      'device_id',
      'staff_id',
      'salesman_id',
      'user_id',
      'permissions',
    };
    void noScope(Object? v) {
      if (v is Map) {
        for (final e in v.entries) {
          expect(forbidden.contains(e.key), isFalse, reason: '${e.key}');
          noScope(e.value);
        }
      } else if (v is List) {
        v.forEach(noScope);
      }
    }

    noScope(body);
    // The session's identity is the signed-in scope's, unchanged.
    final s = a.v.session!;
    expect(
      (s.companyId, s.storeId, s.registerId, s.deviceId, s.staffId),
      (1, 2, 3, 4, 'STAFF-A'),
    );
  });

  test('15. one session on its own still works end to end (bill, correction, confirmable)', () async {
    await a.say('Jacky, bill two coffees and one water');
    backend.answer(0);
    await pumpEventQueue();
    expect(a.lines, [('Coffee', 2), ('Water', 1)]);
    expect(a.v.preview?.isReady, isTrue);
    await a.correct('remove the water');
    backend.answer(1);
    await pumpEventQueue();
    expect(a.lines, [('Coffee', 2)]);
    expect(a.v.preview?.isReady, isTrue);
  });
}
