// Phase 18A — scale readings to sale weights: only a stable, positive,
// exactly convertible reading becomes a WEIGHT quantity (kg, 3 decimals);
// everything else is refused, never rounded. Mock adapter and controller:
// changing / stable weights, disconnects, invalid readings, timeouts,
// stale readings, zero / tare.
import 'dart:async';

import 'package:buskit_pos/core/utils/quantity.dart';
import 'package:buskit_pos/features/scale/mock_scale_adapter.dart';
import 'package:buskit_pos/features/scale/scale_adapter.dart';
import 'package:buskit_pos/features/scale/scale_controller.dart';
import 'package:buskit_pos/features/scale/scale_reading.dart';
import 'package:flutter_test/flutter_test.dart';

final _t = DateTime(2026, 10, 10, 12);

ScaleReading r(
  int? milli, {
  ScaleUnit unit = ScaleUnit.kilogram,
  ScaleReadingStatus status = ScaleReadingStatus.stable,
}) => ScaleReading(valueMilli: milli, unit: unit, status: status, at: _t);

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('saleWeightFrom (conversion to a WEIGHT quantity in kg)', () {
    test('stable kg reading -> exact kg milli, same form as manual entry', () {
      final w = saleWeightFrom(r(1250));
      expect(w.isOk, isTrue);
      expect(w.kgMilli, 1250);
      expect(w.quantity, 1.25);
      expect(w.text, '1.250');
      expect(w.quantity, quantityFromMilli(quantityMilliOf('1.250')!));
      expect(saleWeightFrom(r(2000)).quantity, 2);
      expect(saleWeightFrom(r(2000)).quantity, isA<int>());
    });

    test('grams convert exactly to kg (1 g = 0.001 kg); boundaries 0.001 and 9999 kg', () {
      expect(saleWeightFrom(r(250000, unit: ScaleUnit.gram)).text, '0.250');
      expect(saleWeightFrom(r(1000, unit: ScaleUnit.gram)).text, '0.001');
      expect(saleWeightFrom(r(1, unit: ScaleUnit.kilogram)).text, '0.001');
      expect(saleWeightFrom(r(9999000)).isOk, isTrue);
      expect(
        saleWeightFrom(r(9999001)).problem,
        contains('above the POS maximum'),
      );
      expect(saleWeightFrom(r(9999001000, unit: ScaleUnit.gram)).isOk, isFalse);
    });

    test('more than 3 decimal places in kg is refused, never rounded', () {
      // 250.5 g = 0.2505 kg
      final w = saleWeightFrom(r(250500, unit: ScaleUnit.gram));
      expect(w.isOk, isFalse);
      expect(w.problem, contains('more than 3 decimal places'));
      // Text with 4 places in kg cannot even become a reading value.
      final text = ScaleReading.fromText(
        '1.2345',
        unit: ScaleUnit.kilogram,
        stable: true,
        at: _t,
      );
      expect(text.status, ScaleReadingStatus.invalid);
      expect(saleWeightFrom(text).isOk, isFalse);
    });

    test(
      'unstable, zero, negative, missing and non-weight readings are refused',
      () {
        final cases = <ScaleReading?, String>{
          null: 'No reading',
          r(1250, status: ScaleReadingStatus.unstable): 'settle',
          r(0): 'zero',
          r(-5): 'zero',
          r(null): 'invalid',
          r(null, status: ScaleReadingStatus.invalid): 'invalid',
          r(null, status: ScaleReadingStatus.overload): 'overloaded',
          r(null, status: ScaleReadingStatus.underload): 'below zero',
        };
        cases.forEach((reading, why) {
          final w = saleWeightFrom(reading);
          expect(w.isOk, isFalse, reason: why);
          expect(w.quantity, isNull);
          expect(w.problem, contains(why));
        });
      },
    );

    test(
      'pounds and ounces are refused (no exact gram value), not converted',
      () {
        for (final u in [ScaleUnit.pound, ScaleUnit.ounce]) {
          final w = saleWeightFrom(r(1000, unit: u));
          expect(w.isOk, isFalse);
          expect(w.problem, contains('only g and kg are supported'));
        }
      },
    );

    test('fromText parses exact decimals (sign, up to 3 places) and marks garbage invalid', () {
      expect(
        ScaleReading.fromText(
          '1.25',
          unit: ScaleUnit.kilogram,
          stable: true,
          at: _t,
        ).valueMilli,
        1250,
      );
      expect(
        ScaleReading.fromText(
          ' 250 ',
          unit: ScaleUnit.gram,
          stable: false,
          at: _t,
        ).valueMilli,
        250000,
      );
      expect(
        ScaleReading.fromText(
          '-0.004',
          unit: ScaleUnit.kilogram,
          stable: true,
          at: _t,
        ).valueMilli,
        -4,
      );
      expect(
        ScaleReading.fromText(
          '1.250',
          unit: ScaleUnit.kilogram,
          stable: false,
          at: _t,
        ).status,
        ScaleReadingStatus.unstable,
      );
      for (final bad in ['', 'abc', '1,25', '1.2.3', 'NaN', '1e3', '--1']) {
        expect(
          ScaleReading.fromText(
            bad,
            unit: ScaleUnit.kilogram,
            stable: true,
            at: _t,
          ).status,
          ScaleReadingStatus.invalid,
          reason: bad,
        );
      }
      expect(r(1250).displayText, '1.250 kg');
      expect(r(-4).displayText, '-0.004 kg');
    });
  });

  group('MockScaleAdapter + ScaleController', () {
    late MockScaleAdapter mock;
    late ScaleController scale;

    setUp(() {
      mock = MockScaleAdapter();
      scale = ScaleController(mock, staleAfter: const Duration(seconds: 30));
    });
    tearDown(() async {
      scale.dispose();
      await mock.dispose();
    });

    test('the mock is labelled as simulated, never as a real scale', () {
      expect(mock.isSimulated, isTrue);
      expect(scale.isSimulated, isTrue);
      expect(scale.name, 'Simulated scale');
    });

    test(
      'connect, a changing weight, then a stable weight becomes usable',
      () async {
        expect(scale.saleWeight.isOk, isFalse);
        await scale.connect();
        expect(scale.isConnected, isTrue);
        mock.emitWeight(1310, stable: false);
        await settle();
        expect(scale.reading!.isStable, isFalse);
        expect(scale.saleWeight.isOk, isFalse);
        mock.emitWeight(1250);
        await settle();
        expect(scale.saleWeight.text, '1.250');
      },
    );

    test('a disconnect clears the reading and explains it; manual entry is unaffected', () async {
      await scale.connect();
      mock.emitWeight(1250);
      await settle();
      mock.simulateDisconnect();
      await settle();
      expect(scale.isConnected, isFalse);
      expect(scale.reading, isNull);
      expect(scale.saleWeight.isOk, isFalse);
      expect(scale.error, contains('disconnected'));
      // Readings after the disconnect are ignored.
      mock.emitWeight(999);
      await settle();
      expect(scale.reading, isNull);
      // Reconnecting works.
      await scale.connect();
      mock.emitWeight(500);
      await settle();
      expect(scale.saleWeight.text, '0.500');
      expect(scale.error, isNull);
    });

    test(
      'invalid and overload readings are reported but never usable',
      () async {
        await scale.connect();
        mock.emitStatus(ScaleReadingStatus.invalid);
        await settle();
        expect(scale.saleWeight.problem, contains('invalid'));
        mock.emitStatus(ScaleReadingStatus.overload);
        await settle();
        expect(scale.saleWeight.problem, contains('overloaded'));
      },
    );

    test(
      'a failed connect does not throw; it becomes a cashier-safe error',
      () async {
        mock.failConnect = true;
        await scale.connect();
        expect(scale.isConnected, isFalse);
        expect(scale.error, 'Could not connect to the scale.');
      },
    );

    test(
      'a connect that never answers times out (no hang, no throw)',
      () async {
        final slow = MockScaleAdapter(connectDelay: const Duration(seconds: 2));
        final c = ScaleController(
          slow,
          connectTimeout: const Duration(milliseconds: 20),
        );
        await c.connect();
        expect(c.isConnected, isFalse);
        expect(c.error, contains('did not respond'));
        c.dispose();
        await slow.dispose();
      },
    );

    test('a reading that goes stale (no data) is no longer offered', () async {
      final c = ScaleController(
        mock,
        staleAfter: const Duration(milliseconds: 20),
      );
      await c.connect();
      mock.emitWeight(1250);
      await settle();
      expect(c.saleWeight.isOk, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(c.reading, isNull);
      expect(c.saleWeight.isOk, isFalse);
      expect(c.error, contains('No reading from the scale'));
      c.dispose();
    });

    test('tare subtracts the container; zero/tare are refused when the scale cannot do them', () async {
      await scale.connect();
      mock.emitWeight(150); // empty container
      await scale.tare();
      mock.emitWeight(1400);
      await settle();
      expect(scale.saleWeight.text, '1.250');

      final plain = MockScaleAdapter(capabilities: const ScaleCapabilities());
      final c = ScaleController(plain);
      await c.connect();
      await c.tare();
      expect(c.error, contains('does not support'));
      await expectLater(
        plain.zero(),
        throwsA(
          isA<ScaleException>().having((e) => e.code, 'code', 'unsupported'),
        ),
      );
      c.dispose();
      await plain.dispose();
    });

    test('zero / tare while disconnected fail safely', () async {
      await scale.zero();
      expect(scale.error, 'The scale is not connected.');
    });
  });

  test('the developer demo moves, then settles on each weight', () {
    fakeAsyncDemo();
  });
}

/// Runs the demo with real (short) timers and checks it produces both
/// unstable and stable readings.
void fakeAsyncDemo() {
  final mock = MockScaleAdapter();
  final seen = <ScaleReadingStatus>{};
  final sub = mock.readings.listen((r) => seen.add(r.status));
  final done = Completer<void>();
  mock.connect().then((_) {
    mock.startDemo(step: const Duration(milliseconds: 2));
    Future<void>.delayed(const Duration(milliseconds: 60), () async {
      await mock.disconnect();
      await sub.cancel();
      await mock.dispose();
      done.complete();
    });
  });
  expect(
    done.future.then((_) => seen),
    completion(
      containsAll([ScaleReadingStatus.unstable, ScaleReadingStatus.stable]),
    ),
  );
}
