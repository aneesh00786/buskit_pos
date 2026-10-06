// Phase 13A — voice foundation: microphone permission on first use, the
// listening lifecycle, speech-to-text delivery and the voice session /
// request ids. Fakes stand in for the microphone permission and the speech
// recognizer: no microphone, no platform channel, no POS call.
import 'dart:async';

import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:buskit_pos/features/voice/ui/voice_test_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

class FakeMicrophone implements MicrophonePermission {
  VoicePermission current = VoicePermission.denied;
  VoicePermission onRequest = VoicePermission.granted;
  int statusCalls = 0;
  int requestCalls = 0;
  int settingsCalls = 0;
  Completer<void>? gate;

  @override
  Future<VoicePermission> status() async {
    statusCalls++;
    return current;
  }

  @override
  Future<VoicePermission> request() async {
    requestCalls++;
    if (gate != null) await gate!.future;
    current = onRequest;
    return current;
  }

  @override
  Future<bool> openSettings() async {
    settingsCalls++;
    return true;
  }
}

class FakeRecognizer implements SpeechRecognizer {
  bool available = true;
  Object? listenError;
  int initCalls = 0;
  int listenCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  void Function(String text, bool isFinal)? _onResult;
  void Function(String error)? _onError;
  void Function(String status)? _onStatus;

  @override
  Future<bool> initialize({
    required void Function(String error) onError,
    required void Function(String status) onStatus,
  }) async {
    initCalls++;
    _onError = onError;
    _onStatus = onStatus;
    return available;
  }

  @override
  Future<void> listen({
    required void Function(String text, bool isFinal) onResult,
  }) async {
    listenCalls++;
    if (listenError != null) throw listenError!;
    _onResult = onResult;
  }

  @override
  Future<void> stop() async => stopCalls++;

  @override
  Future<void> cancel() async => cancelCalls++;

  void say(String text, {bool isFinal = true}) => _onResult!(text, isFinal);
  void fail(String error) => _onError!(error);
  void status(String s) => _onStatus!(s);
}

const staffA = PosTokenScope(
  companyId: 1,
  storeId: 2,
  registerId: 3,
  deviceId: 4,
  salesmanId: 'STAFF-A',
);
const staffB = PosTokenScope(
  companyId: 1,
  storeId: 2,
  registerId: 3,
  deviceId: 4,
  salesmanId: 'STAFF-B',
);
final uuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

void main() {
  late FakeMicrophone mic;
  late FakeRecognizer speech;
  late PosTokenScope? scope;
  late VoiceController voice;
  late List<VoiceState> states;

  setUp(() {
    mic = FakeMicrophone();
    speech = FakeRecognizer();
    scope = staffA;
    voice = VoiceController(
      permission: mic,
      recognizer: speech,
      scope: () => scope,
    );
    states = [];
    voice.addListener(() => states.add(voice.state));
  });
  tearDown(() => voice.dispose());

  group('permission', () {
    test('nothing is asked until voice is used (no permission / recognizer call at creation)', () {
      expect((mic.statusCalls, mic.requestCalls, speech.initCalls), (0, 0, 0));
      expect(voice.state, VoiceState.idle);
    });

    test('first use asks once (requestingPermission); denied -> error with a clear message, nothing recorded', () async {
      mic.onRequest = VoicePermission.denied;
      expect(await voice.start(), isFalse);
      expect(states, [VoiceState.requestingPermission, VoiceState.error]);
      expect(voice.error, 'Microphone access is needed to use voice.');
      expect(mic.requestCalls, 1);
      expect((speech.initCalls, speech.listenCalls), (0, 0));
      expect(voice.needsSettings, isFalse);
    });

    test('permanently denied: no prompt is shown again, the user is pointed to the device settings', () async {
      mic.current = VoicePermission.permanentlyDenied;
      expect(await voice.start(), isFalse);
      expect(mic.requestCalls, 0);
      expect(voice.state, VoiceState.error);
      expect(voice.error, contains('Turn it on in the device settings'));
      expect(voice.needsSettings, isTrue);
      expect(await voice.openSettings(), isTrue);
      expect(mic.settingsCalls, 1);
    });

    test(
      'already granted: no prompt; unavailable microphone -> its own message',
      () async {
        mic.current = VoicePermission.granted;
        expect(await voice.start(), isTrue);
        expect(mic.requestCalls, 0);
        await voice.cancel();
        mic.current = VoicePermission.unavailable;
        expect(await voice.start(), isFalse);
        expect(voice.error, 'The microphone is not available on this device.');
      },
    );
  });

  group('lifecycle', () {
    test('start -> listening (partials shown) -> stop -> processing -> final text -> recognized', () async {
      expect(await voice.start(), isTrue);
      expect(voice.state, VoiceState.listening);
      expect(speech.listenCalls, 1);
      speech.say('bill two', isFinal: false);
      expect(voice.text, 'bill two');
      expect(voice.state, VoiceState.listening);
      await voice.stop();
      expect(voice.state, VoiceState.processing);
      expect(speech.stopCalls, 1);
      speech.say('bill two coffees');
      expect(voice.state, VoiceState.recognized);
      expect(voice.text, 'bill two coffees');
      expect(voice.request!.recognizedAt, isNotNull);
      expect(
        states,
        containsAllInOrder([
          VoiceState.requestingPermission,
          VoiceState.listening,
          VoiceState.processing,
          VoiceState.recognized,
        ]),
      );
    });

    test('duplicate start (concurrent or while listening) and duplicate stop are ignored; one recognizer session', () async {
      mic.gate = Completer<void>();
      final a = voice.start();
      final b = voice.start();
      mic.gate!.complete();
      expect(await Future.wait([a, b]), [true, false]);
      expect(await voice.start(), isFalse, reason: 'already listening');
      expect(speech.listenCalls, 1);
      await voice.stop();
      await voice.stop();
      expect(speech.stopCalls, 1);
      expect(speech.initCalls, 1);
    });

    test('cancel discards the request and returns to idle; late results are ignored', () async {
      await voice.start();
      speech.say('bill', isFinal: false);
      await voice.cancel();
      expect(voice.state, VoiceState.idle);
      expect(speech.cancelCalls, 1);
      expect(voice.request, isNull);
      expect(voice.text, '');
      speech.say('bill two coffees');
      expect(voice.state, VoiceState.idle, reason: 'late result after cancel');
    });

    test('dispose while listening releases the recognizer', () async {
      final v = VoiceController(
        permission: mic..current = VoicePermission.granted,
        recognizer: speech,
        scope: () => scope,
      );
      await v.start();
      v.dispose();
      expect(speech.cancelCalls, 1);
    });
  });

  group('session and request ids', () {
    test('a new session gets a new voiceSessionId; every request a new requestId within its session', () async {
      mic.current = VoicePermission.granted;
      await voice.start();
      final s1 = voice.session!.voiceSessionId;
      final r1 = voice.request!.requestId;
      speech.say('one');
      await voice.start();
      final r2 = voice.request!.requestId;
      expect(
        voice.session!.voiceSessionId,
        s1,
        reason: 'same staff: same session',
      );
      expect(r2, isNot(r1));
      expect(voice.request!.voiceSessionId, s1);
      speech.say('two');
      await voice.newSession();
      expect(voice.session!.voiceSessionId, isNot(s1));
      expect(voice.request, isNull);
      for (final id in [s1, r1, r2, voice.session!.voiceSessionId]) {
        expect(uuid.hasMatch(id), isTrue, reason: id);
      }
    });

    test('context comes from the signed-in POS session (never invented); none signed in -> null ids', () async {
      mic.current = VoicePermission.granted;
      await voice.start();
      final s = voice.session!;
      expect(
        (s.companyId, s.storeId, s.registerId, s.deviceId, s.staffId),
        (1, 2, 3, 4, 'STAFF-A'),
      );
      await voice.cancel();
      scope = null;
      await voice.start();
      final n = voice.session!;
      expect((n.companyId, n.deviceId, n.staffId), (null, null, null));
    });

    test('isolation: another staff member on the device never continues the previous session; controllers never share one', () async {
      mic.current = VoicePermission.granted;
      await voice.start();
      final a = voice.session!;
      speech.say('for A');
      scope = staffB;
      await voice.start();
      final b = voice.session!;
      expect(b.voiceSessionId, isNot(a.voiceSessionId));
      expect(b.staffId, 'STAFF-B');
      expect(voice.text, '', reason: "B does not see A's text");
      expect(a.staffId, 'STAFF-A', reason: "A's session is untouched");
      final other = VoiceController(
        permission: mic,
        recognizer: FakeRecognizer(),
        scope: () => staffB,
      );
      addTearDown(other.dispose);
      await other.start();
      expect(other.session!.voiceSessionId, isNot(b.voiceSessionId));
    });
  });

  group('errors', () {
    test('recognizer unavailable, listen failure, recognizer error and silence all end in a clear error state', () async {
      mic.current = VoicePermission.granted;
      speech.available = false;
      expect(await voice.start(), isFalse);
      expect(
        voice.error,
        'Speech recognition is not available on this device.',
      );

      speech.available = true;
      final v2 = VoiceController(
        permission: mic,
        recognizer: speech..listenError = StateError('mic busy'),
        scope: () => scope,
      );
      addTearDown(v2.dispose);
      expect(await v2.start(), isFalse);
      expect(v2.error, 'Voice could not start. Try again.');

      speech.listenError = null;
      final v3 = VoiceController(
        permission: mic,
        recognizer: speech,
        scope: () => scope,
      );
      addTearDown(v3.dispose);
      await v3.start();
      speech.fail('error_network');
      expect(
        (v3.state, v3.error),
        (VoiceState.error, 'Speech recognition failed. Try again.'),
      );

      expect(await v3.start(), isTrue, reason: 'can try again after an error');
      speech.say('');
      expect(
        (v3.state, v3.error),
        (VoiceState.error, 'Nothing was heard. Try again.'),
      );

      await v3.start();
      speech.status('done');
      expect(v3.error, 'Nothing was heard. Try again.');
    });
  });

  testWidgets(
    'test screen: Start Voice -> Stop while listening -> recognized text with the session and request ids',
    (tester) async {
      mic.current = VoicePermission.granted;
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
      expect(find.text('Idle'), findsOneWidget);
      expect(find.byKey(const Key('voice-stop')), findsNothing);
      await tester.tap(find.byKey(const Key('voice-start')));
      await tester.pump();
      expect(find.text('Listening…'), findsOneWidget);
      expect(find.byKey(const Key('voice-stop')), findsOneWidget);
      expect(find.byKey(const Key('voice-start')), findsNothing);
      await tester.tap(find.byKey(const Key('voice-stop')));
      await tester.pump();
      speech.say('bill two coffees');
      await tester.pump();
      expect(find.text('Recognized'), findsOneWidget);
      expect(find.text('"bill two coffees"'), findsOneWidget);
      expect(find.text(voice.session!.voiceSessionId), findsOneWidget);
      expect(find.text(voice.request!.requestId), findsOneWidget);
      expect(find.text('STAFF-A / 4 / 1'), findsOneWidget);
    },
  );

  testWidgets(
    'test screen: permanently denied shows the message and an Open settings action',
    (tester) async {
      mic.current = VoicePermission.permanentlyDenied;
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
      expect(find.byKey(const Key('voice-error')), findsOneWidget);
      await tester.tap(find.byKey(const Key('voice-open-settings')));
      await tester.pump();
      expect(mic.settingsCalls, 1);
    },
  );
}
