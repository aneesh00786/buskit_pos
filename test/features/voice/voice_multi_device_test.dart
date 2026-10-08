// Phase 15B — Jacky multi-device / multi-user acceptance (AUTOMATED
// simulation, not physical-device UAT). Three devices of ONE business, each
// with its own signed-in scope (staff + device), VoiceController,
// VoiceSession, recognizer, TTS and cart. One shared backend (the business's
// catalogue and prices) answers only when the test releases a call, so
// concurrency and completion order are deterministic (completers, no
// sleeps). Read-only Quick Bill previews only: no sale, payment, stock,
// order or cart line is ever created.
import 'dart:async';

import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/voice/data/voice_platform.dart';
import 'package:buskit_pos/features/voice/data/voice_preview_service.dart';
import 'package:buskit_pos/features/voice/models/quick_bill_preview.dart';
import 'package:buskit_pos/features/voice/state/voice_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import 'voice_controller_test.dart' show FakeMicrophone, FakeRecognizer, uuid;
import 'voice_tts_test.dart' show MockVoiceTtsService;

// ------------------------------------------------------------ the business

/// The ONE business's catalogue (shared by every device):
/// query -> (variation id, name, variant, unit price, tax %).
const catalogue = {
  'coffee': (9900, 'Coffee', 'Regular', 4.5, 5),
  'water': (9901, 'Water', '1 L', 18.0, 0),
  'juice': (9902, 'Juice', 'Orange', 3.25, 5),
};

double r3(num v) => double.parse(v.toStringAsFixed(3));

/// What the server would answer for [body]: prices from the shared
/// catalogue, the request's own ids echoed (unless overridden).
QuickBillPreview serverAnswer(
  Map<String, dynamic> body, {
  String? voiceSessionId,
  String? requestId,
}) {
  final items = <Map<String, dynamic>>[];
  final issues = <Map<String, dynamic>>[];
  var sub = 0.0, tax = 0.0;
  for (final (i, raw) in (body['items'] as List).indexed) {
    final it = raw as Map<String, dynamic>;
    final query = it['product_query'] as String;
    final p = catalogue[query];
    if (p == null) {
      issues.add({
        'item_index': i,
        'code': 'PRODUCT_NOT_FOUND',
        'message': "Could not find a matching product for '$query'.",
        'product_query': query,
        'candidates': const [],
      });
      continue;
    }
    final q = it['quantity'] as num;
    final lineSub = r3(p.$4 * q);
    final lineTax = r3(lineSub * p.$5 / 100);
    sub += lineSub;
    tax += lineTax;
    items.add({
      'item_index': i,
      'status': 'RESOLVED',
      'product_variation_id': p.$1,
      'product_name': p.$2,
      'variant_name': p.$3,
      'selling_mode': 'PIECE',
      'quantity': q,
      'unit': it['unit'],
      'unit_price': p.$4,
      'tax_percent': p.$5,
      'tax_included': false,
      'line_subtotal': lineSub,
      'tax': lineTax,
      'line_total': r3(lineSub + lineTax),
    });
  }
  final ready = issues.isEmpty;
  return QuickBillPreview.fromJson({
    'status': ready ? 'READY' : 'NEEDS_CLARIFICATION',
    'voice_session_id': voiceSessionId ?? body['voice_session_id'],
    'request_id': requestId ?? body['request_id'],
    'recognized_text': body['recognized_text'],
    'items': items,
    'issues': issues,
    'subtotal': ready ? r3(sub) : null,
    'tax': ready ? r3(tax) : null,
    'total': ready ? r3(sub + tax) : null,
  })!;
}

class Call {
  Call(this.scope, this.request);

  /// The AUTHENTICATED scope the call was made with (on the real server:
  /// the staff token) — never anything from the body.
  final PosTokenScope scope;
  final QuickBillRequest request;
  final done = Completer<QuickBillPreview>();
  Map<String, dynamic> get body => request.toJson();
}

/// The business's backend, shared by all devices. Nothing completes until
/// the test says so.
class BusinessBackend {
  final calls = <Call>[];

  /// The client a device signed in as [scope] uses.
  VoicePreviewService forDevice(PosTokenScope scope) =>
      _DeviceClient(this, scope);

  Call last(Device d) => calls.lastWhere((c) => c.scope == d.scope);

  /// The server's answer to [c] (its own ids).
  void answer(Call c) => c.done.complete(serverAnswer(c.body));

  /// Delivers [answerFor]'s answer (ids and all) to [c] — a misrouted /
  /// cross-session response.
  void misroute(Call c, Call answerFor) =>
      c.done.complete(serverAnswer(answerFor.body));
}

class _DeviceClient implements VoicePreviewService {
  _DeviceClient(this.backend, this.scope);
  final BusinessBackend backend;
  final PosTokenScope scope;

  @override
  Future<QuickBillPreview> previewQuickBill(QuickBillRequest request) {
    final c = Call(scope, request);
    backend.calls.add(c);
    return c.done.future;
  }
}

// ------------------------------------------------------------- the devices

const business = 1;
const store = 2;

PosTokenScope signedIn(String staff, int device, int register) => PosTokenScope(
  companyId: business,
  storeId: store,
  registerId: register,
  deviceId: device,
  salesmanId: staff,
);

final scopeA = signedIn('USER-A', 101, 11);
final scopeB = signedIn('USER-B', 102, 12);
final scopeC = signedIn('USER-C', 103, 13);

/// One physical device: its own signed-in user, voice controller,
/// microphone (recognizer), TTS and POS cart.
class Device {
  Device(this.name, this.scope, BusinessBackend backend) {
    cart = CartController(cartServer);
    v = VoiceController(
      permission: FakeMicrophone()..current = VoicePermission.granted,
      recognizer: speech,
      scope: () => scope,
      previewService: backend.forDevice(scope),
      cart: cart,
      tts: tts,
    );
  }
  final String name;
  final PosTokenScope scope;
  final speech = FakeRecognizer();
  final tts = MockVoiceTtsService();
  final cartServer = FakeCartService();
  late final CartController cart;
  late final VoiceController v;
  bool _disposed = false;

  Future<void> say(String text) async {
    expect(await v.start(), isTrue, reason: name);
    speech.say(text);
    await pumpEventQueue();
  }

  /// Starts listening for a spoken correction (does not speak yet).
  Future<void> startCorrection() async =>
      expect(await v.startCorrection(), isTrue, reason: name);

  Future<void> correct(String text) async {
    await startCorrection();
    speech.say(text);
    await pumpEventQueue();
  }

  List<(String, num)> get lines => [
    for (final l in v.preview?.items ?? const <QuickBillLine>[])
      (l.productName, l.quantity),
  ];

  /// Nothing reached the POS: no cart line, sale or payment.
  void expectNoTransaction() {
    expect(cartServer.addCalls, isEmpty, reason: name);
    expect(cartServer.completeCalls, isEmpty, reason: name);
    expect(cart.completedSale, isNull, reason: name);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    v.dispose();
    cart.dispose();
  }
}

void main() {
  late BusinessBackend backend;
  late Device a, b, c;

  setUp(() {
    backend = BusinessBackend();
    a = Device('A', scopeA, backend);
    b = Device('B', scopeB, backend);
    c = Device('C', scopeC, backend);
  });
  tearDown(() {
    for (final d in [a, b, c]) {
      d.expectNoTransaction();
      d.dispose();
    }
  });

  /// All three bills spoken; all three requests pending at once.
  Future<void> threeBills() async {
    await a.say('Jacky, bill two coffees');
    await b.say('Jacky, bill three waters');
    await c.say('Jacky, bill one juice');
    expect(backend.calls, hasLength(3));
    for (final d in [a, b, c]) {
      expect(d.v.previewState, VoicePreviewState.loading, reason: d.name);
    }
  }

  void expectBills() {
    expect(a.lines, [('Coffee', 2)]);
    expect(b.lines, [('Water', 3)]);
    expect(c.lines, [('Juice', 1)]);
  }

  Future<void> release(Device d) async {
    backend.answer(backend.last(d));
    await pumpEventQueue();
  }

  test(
    '1 – 3 / 8. same business, different users, devices, sessions and requests',
    () async {
      await threeBills();
      final devices = [a, b, c];
      final sessions = [for (final d in devices) d.v.session!];
      expect(
        {for (final s in sessions) s.companyId},
        {business},
        reason: 'SAME business',
      );
      expect({for (final s in sessions) s.storeId}, {store});
      expect(
        {for (final s in sessions) s.staffId},
        {'USER-A', 'USER-B', 'USER-C'},
      );
      expect({for (final s in sessions) s.deviceId}, {101, 102, 103});
      expect({for (final s in sessions) s.registerId}, {11, 12, 13});
      final ids = {for (final s in sessions) s.voiceSessionId};
      expect(ids, hasLength(3));
      expect(ids.every(uuid.hasMatch), isTrue);
      expect({for (final d in devices) d.v.request!.requestId}, hasLength(3));
      for (final (i, d) in devices.indexed) {
        expect(identical(d.v.session, sessions[(i + 1) % 3]), isFalse);
        expect(d.v.session!.belongsTo(d.scope), isTrue);
        // Each call was made with that device's signed-in scope.
        expect(backend.calls[i].scope, d.scope);
        expect(
          backend.calls[i].request.voiceSessionId,
          d.v.session!.voiceSessionId,
        );
      }
    },
  );

  group('4 / 5. three simultaneous requests, completed out of order', () {
    test('C, A, B — then B, C, A', () async {
      await threeBills();
      await release(c);
      expect(c.lines, [('Juice', 1)]);
      expect(a.v.preview, isNull);
      expect(b.v.preview, isNull);
      await release(a);
      expect(a.lines, [('Coffee', 2)]);
      expect(b.v.preview, isNull);
      await release(b);
      expectBills();

      // Second round: all three speak again (new requests, same sessions).
      final sessions = [
        for (final d in [a, b, c]) d.v.session!.voiceSessionId,
      ];
      for (final d in [a, b, c]) {
        expect(await d.v.speakAgain(), isTrue);
      }
      a.speech.say('bill one water');
      b.speech.say('bill two juices');
      c.speech.say('bill three coffees');
      await pumpEventQueue();
      expect(backend.calls, hasLength(6));
      await release(b);
      expect(b.lines, [('Juice', 2)]);
      expect(a.v.preview, isNull);
      expect(c.v.preview, isNull);
      await release(c);
      expect(c.lines, [('Coffee', 3)]);
      await release(a);
      expect(a.lines, [('Water', 1)]);
      expect(b.lines, [('Juice', 2)]);
      expect(
        [
          for (final d in [a, b, c]) d.v.session!.voiceSessionId,
        ],
        sessions,
        reason: 'same sessions throughout',
      );
      for (final d in [a, b, c]) {
        expect(d.v.preview!.voiceSessionId, d.v.session!.voiceSessionId);
        expect(d.v.preview!.requestId, d.v.request!.requestId);
      }
    });
  });

  group('6. cross-session responses are rejected', () {
    Future<void> attack(Device victim, Device owner) async {
      final spoken = victim.tts.spoken.length;
      backend.misroute(backend.last(victim), backend.last(owner));
      await pumpEventQueue();
      expect(victim.v.preview, isNull, reason: '${victim.name} keeps nothing');
      expect(victim.lines, isEmpty);
      expect(victim.v.previewState, VoicePreviewState.failed);
      expect(victim.v.previewError, contains('did not match'));
      expect(victim.tts.spoken, hasLength(spoken), reason: 'not spoken');
      expect(await victim.v.confirmBill(), isFalse);
      victim.expectNoTransaction();
    }

    test('A gets B\'s answer; B gets A\'s; C gets A\'s — all rejected, owners unaffected', () async {
      await threeBills();
      final a1 = backend.last(a), b1 = backend.last(b);
      await attack(a, b);
      expect(
        b.v.previewState,
        VoicePreviewState.loading,
        reason: 'B untouched',
      );
      await attack(b, a);
      await attack(c, a);
      // The genuine owners' state was never involved (all three waited).
      expect(a1.done.isCompleted && b1.done.isCompleted, isTrue);
      for (final d in [a, b, c]) {
        expect(d.lines, isEmpty, reason: d.name);
      }
      // Each recovers by speaking again (new request id, own session).
      final texts = {
        a: 'bill two coffees',
        b: 'bill three waters',
        c: 'bill one juice',
      };
      for (final d in [a, b, c]) {
        final failed = backend.last(d).request.requestId;
        expect(await d.v.speakAgain(), isTrue);
        d.speech.say(texts[d]!);
        await pumpEventQueue();
        expect(backend.last(d).request.requestId, isNot(failed));
        expect(
          backend.last(d).request.voiceSessionId,
          d.v.session!.voiceSessionId,
        );
        await release(d);
      }
      expectBills();
    });

    test('right request id but another device\'s session id is rejected (A↔B, C←A)', () async {
      await threeBills();
      for (final (victim, owner) in [(a, b), (b, a), (c, a)]) {
        final call = backend.last(victim);
        call.done.complete(
          serverAnswer(
            call.body,
            voiceSessionId: owner.v.session!.voiceSessionId,
          ),
        );
        await pumpEventQueue();
        expect(victim.v.preview, isNull, reason: victim.name);
        expect(victim.v.previewState, VoicePreviewState.failed);
        expect(victim.tts.spoken, isEmpty, reason: victim.name);
        expect(owner.v.preview, isNull, reason: 'owner never touched');
      }
    });

    test('an answer for A\'s own OLDER request (right session, wrong request) is rejected', () async {
      await threeBills();
      final a1 = backend.last(a);
      expect(await a.v.speakAgain(), isTrue);
      a.speech.say('bill one water'); // A2
      await pumpEventQueue();
      final a2 = backend.last(a);
      expect(a2, isNot(same(a1)));
      backend.misroute(a2, a1); // A1's answer arrives on A2's call
      await pumpEventQueue();
      expect(a.v.preview, isNull);
      expect(a.v.previewState, VoicePreviewState.failed);
      expect(a.tts.spoken, isEmpty);
    });
  });

  test(
    '5 / 7. cross-user corrections: each changes only its own bill',
    () async {
      await threeBills();
      for (final d in [c, b, a]) {
        await release(d);
      }
      expectBills();
      final before = {
        for (final d in [a, b, c]) d.name: d.v.request!.requestId,
      };

      // All three listening for a correction at the same time.
      for (final d in [a, b, c]) {
        await d.startCorrection();
      }
      a.speech.say('make it three');
      b.speech.say('remove water');
      c.speech.say('make it two');
      await pumpEventQueue();
      // B removed its only line (nothing to price); A and C ask the server.
      expect(b.v.preview, isNull);
      expect(b.v.previewError, contains('removed'));
      expect(backend.calls, hasLength(5));
      await release(c);
      expect(c.lines, [('Juice', 2)]);
      expect(a.v.preview, isNull, reason: 'A still waiting');
      await release(a);
      expect(a.lines, [('Coffee', 3)]);
      expect(b.lines, isEmpty, reason: 'B stays removed');
      for (final d in [a, c]) {
        expect(d.v.request!.requestId, isNot(before[d.name]), reason: d.name);
        expect(
          backend.last(d).request.voiceSessionId,
          d.v.session!.voiceSessionId,
        );
      }
    },
  );

  test(
    '8 / 9. a stale A1 cannot overwrite A2 while B and C carry on',
    () async {
      await threeBills();
      final a1 = backend.last(a);
      expect(await a.v.speakAgain(), isTrue);
      a.speech.say('bill one juice'); // A2
      await pumpEventQueue();
      final a2 = backend.last(a);
      await release(b);
      backend.answer(a2);
      await pumpEventQueue();
      expect(a.lines, [('Juice', 1)]);
      final aSpoken = a.tts.spoken.length;
      backend.answer(a1); // stale, last
      await pumpEventQueue();
      expect(a.lines, [('Juice', 1)]);
      expect(a.v.preview!.requestId, a2.request.requestId);
      expect(a.tts.spoken, hasLength(aSpoken));
      await release(c);
      expect(b.lines, [('Water', 3)]);
      expect(c.lines, [('Juice', 1)]);
      expect(b.tts.spoken, hasLength(1));
      expect(c.tts.spoken, hasLength(1));
    },
  );

  test('10 / 11. lifecycle: A cancels and starts a new session; B and C continue; nothing leaks', () async {
    b.tts.hold = true;
    await threeBills(); // 1–3: A, B, C start
    final oldA = a.v.session!.voiceSessionId;
    final a1 = backend.last(a);
    await release(b);
    expect(b.v.isSpeaking, isTrue);

    final bStops = b.tts.stops; // B's own start stopped B's earlier reply
    a.v.cancelBill(); // 4
    expect(b.v.isSpeaking, isTrue, reason: 'A\'s cancel never stops B');
    expect(b.tts.stops, bStops);
    expect(c.v.previewState, VoicePreviewState.loading, reason: 'C unaffected');
    backend.answer(a1);
    await pumpEventQueue();
    expect(a.v.preview, isNull, reason: 'cancelled answer dropped');
    expect(a.tts.spoken, isEmpty);

    b.tts.playing!.complete(); // 5. B continues
    b.tts.hold = false;
    await pumpEventQueue();
    await b.correct('make it four');
    await release(b);
    expect(b.lines, [('Water', 4)]);

    await release(c); // 6. C continues
    expect(c.lines, [('Juice', 1)]);

    await a.v.newSession(); // 7
    expect(a.v.session!.voiceSessionId, isNot(oldA));
    expect(a.v.request, isNull);
    expect(a.v.intent, isNull);
    expect(a.v.text, isEmpty);
    expect(a.v.preview, isNull);
    expect(a.v.previewState, VoicePreviewState.none);
    expect(
      await a.v.startCorrection(),
      isFalse,
      reason: 'no old bill to correct',
    );
    await a.say('bill two coffees');
    expect(backend.last(a).request.voiceSessionId, a.v.session!.voiceSessionId);
    await release(a);
    expect(a.lines, [('Coffee', 2)]);

    // 8 / 9. B kept its session; C completes its own correction.
    expect(
      b.v.session!.voiceSessionId,
      backend.calls[1].request.voiceSessionId,
    );
    await c.correct('make it two');
    await release(c);
    expect(c.lines, [('Juice', 2)]);
    expect(b.lines, [('Water', 4)]);
    expect(a.lines, [('Coffee', 2)]);
  });

  test('11. a new session on a device with a loaded bill keeps nothing of it; B and C keep theirs', () async {
    await threeBills();
    for (final d in [a, b, c]) {
      await release(d);
    }
    final old = a.v.session!.voiceSessionId;
    await a.v.newSession();
    expect(a.v.session!.voiceSessionId, isNot(old));
    expect(a.v.request, isNull);
    expect(a.v.intent, isNull);
    expect(a.v.text, isEmpty);
    expect(a.v.preview, isNull);
    expect(a.v.previewState, VoicePreviewState.none);
    expect(await a.v.startCorrection(), isFalse, reason: 'old bill gone');
    expect(await a.v.confirmBill(), isFalse);
    expect(b.lines, [('Water', 3)]);
    expect(c.lines, [('Juice', 1)]);
  });

  test(
    '11. a new session stops the old session\'s reply (no carry-over)',
    () async {
      a.tts.hold = true;
      await a.say('bill two coffees');
      await release(a);
      expect(a.v.isSpeaking, isTrue);
      await a.v.newSession();
      expect(a.v.isSpeaking, isFalse);
      expect(a.tts.playing!.isCompleted, isTrue, reason: 'stopped');
    },
  );

  test(
    '12. TTS is per device: each answer speaks only on its own device',
    () async {
      await threeBills();
      await release(c);
      expect(c.tts.spoken, hasLength(1));
      expect(a.tts.spoken, isEmpty);
      expect(b.tts.spoken, isEmpty);
      await release(a);
      expect(a.tts.spoken, hasLength(1));
      expect(b.tts.spoken, isEmpty);
      await release(b);
      for (final d in [a, b, c]) {
        final total = d.v.preview!.total!;
        expect(
          d.tts.spoken.single,
          contains(total.toStringAsFixed(2)),
          reason: d.name,
        );
      }
      // A cancel on A stops only A's TTS.
      final stops = [b.tts.stops, c.tts.stops];
      a.v.cancelBill();
      expect([b.tts.stops, c.tts.stops], stops);
    },
  );

  test('13. spoken text can never supply business / store / register / device / user / permissions', () async {
    await a.say(
      'bill two coffees company_id 7 business_id 7 store_id 9 register_id 3 '
      'device_id 102 staff_id USER-B user_id USER-C permissions all '
      'voice_session_id hijack request_id hijack',
    );
    final call = backend.last(a);
    expect(call.scope, scopeA, reason: 'authenticated scope, not speech');
    expect(call.body.keys.toSet(), {
      'intent',
      'voice_session_id',
      'request_id',
      'recognized_text',
      'items',
    });
    expect(call.body['voice_session_id'], a.v.session!.voiceSessionId);
    expect(call.body['request_id'], a.v.request!.requestId);
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
          expect(forbidden, isNot(contains(e.key)));
          noScope(e.value);
        }
      } else if (v is List) {
        v.forEach(noScope);
      }
    }

    noScope(call.body);
    final s = a.v.session!;
    expect(
      (s.companyId, s.storeId, s.registerId, s.deviceId, s.staffId),
      (business, store, 11, 101, 'USER-A'),
    );
  });

  test('14. the business catalogue is shared: the same product and price on every device', () async {
    for (final d in [a, b, c]) {
      await d.say('bill two coffees');
    }
    for (final d in [b, a, c]) {
      await release(d);
    }
    for (final d in [a, b, c]) {
      final line = d.v.preview!.items.single;
      expect(
        (
          line.productVariationId,
          line.productName,
          line.unitPrice,
          d.v.preview!.total,
        ),
        (9900, 'Coffee', 4.5, 9.45),
        reason: d.name,
      );
      // … in each device's own conversation.
      expect(d.v.preview!.voiceSessionId, d.v.session!.voiceSessionId);
    }
  });

  test('15. ACCEPTANCE: three devices, one business — bills and corrections stay with their user', () async {
    // Device A/User A, Device B/User B, Device C/User C speak; all three
    // requests are pending at the same time.
    await threeBills();
    expect(backend.calls.where((c) => !c.done.isCompleted), hasLength(3));
    // Completed in an arbitrary order.
    for (final d in [b, c, a]) {
      await release(d);
    }
    expectBills();

    // Corrections, all listening at once; two prices pending together.
    for (final d in [a, b, c]) {
      await d.startCorrection();
    }
    c.speech.say('make it two');
    a.speech.say('make it three');
    b.speech.say('remove water');
    await pumpEventQueue();
    expect(backend.calls.where((c) => !c.done.isCompleted), hasLength(2));
    await release(a);
    await release(c);

    expect(a.lines, [('Coffee', 3)]);
    expect(b.lines, isEmpty);
    expect(c.lines, [('Juice', 2)]);
    for (final (d, staff) in [(a, 'USER-A'), (c, 'USER-C')]) {
      expect(d.v.preview!.voiceSessionId, d.v.session!.voiceSessionId);
      expect(d.v.preview!.requestId, d.v.request!.requestId);
      expect(d.v.session!.staffId, staff);
      expect(backend.last(d).scope, d.scope);
    }
    expect(b.v.session!.staffId, 'USER-B');
    // tearDown: no cart line, sale or payment on any device.
  });
}
