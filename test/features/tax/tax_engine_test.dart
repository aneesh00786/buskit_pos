// POS Phase P2.1 — the Dart tax engine and legacy adapter against the SAME
// shared vectors as buskit-web (test/pos/fixtures/tax_vectors.json; identical
// copy pinned by SHA-256 here and there).
//  - lines / invoices: expected values from an independent rational oracle;
//  - legacy: expected values from running the unchanged server computeLine —
//    the Dart adapter (delegating to offline/pos_tax.dart) must equal them.
// The examples are calculations, not verified legal rules for any jurisdiction.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/features/offline/pos_tax.dart';
import 'package:buskit_pos/features/tax/engine/legacy_tax_adapter.dart';
import 'package:buskit_pos/features/tax/engine/tax_currency.dart';
import 'package:buskit_pos/features/tax/engine/tax_engine.dart';
import 'package:buskit_pos/features/tax/engine/tax_rational.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/sha256.dart';

const vectorsPath = 'test/fixtures/tax_vectors.json';
// The same constant is pinned in buskit-web test/pos/posTaxLegacyParity.test.js.
const taxVectorsSha256 = '363454b6a6ac1bf80ce9da88d0ae1819d1f1d40236378b3ff597096322721bda';

final vectors = jsonDecode(File(vectorsPath).readAsStringSync()) as Map<String, dynamic>;
List<Map<String, dynamic>> section(String name) =>
    (vectors[name] as List).cast<Map<String, dynamic>>();

/// A deep, unmodifiable copy: proves the engine never mutates its input.
Object? frozen(Object? v) {
  if (v is Map) return Map<String, Object?>.unmodifiable(v.map((k, x) => MapEntry(k as String, frozen(x))));
  if (v is List) return List<Object?>.unmodifiable(v.map(frozen));
  return v;
}

Map<String, Object?> inputOf(Map<String, dynamic> c) => frozen(c['input']) as Map<String, Object?>;

void expectCase(Map<String, dynamic> c, Map<String, Object?> Function(Map<String, Object?>) run) {
  final label = '${c['id']}: ${c['description']}';
  if (c['errorCode'] != null) {
    expect(
      () => run(inputOf(c)),
      throwsA(isA<TaxEngineException>().having((e) => e.code, 'code', c['errorCode'])),
      reason: label,
    );
    return;
  }
  expect(run(inputOf(c)), c['expected'], reason: label);
}

void main() {
  test('the test SHA-256 matches the FIPS 180-4 test vectors', () {
    expect(sha256Hex(utf8.encode('abc')), 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256Hex(const []), 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(
      sha256Hex(utf8.encode('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')),
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
    );
  });

  test('the shared vector file is the pinned copy (identical in both repositories)', () {
    expect(sha256Hex(File(vectorsPath).readAsBytesSync()), taxVectorsSha256);
  });

  group('engine (shared vectors)', () {
    test('line vectors: exclusive, inclusive, multi-component, compound, zero-rated / exempt, INR / JPY / KWD, rounding modes, errors', () {
      expect(section('lines'), hasLength(55));
      for (final c in section('lines')) {
        expectCase(c, (i) => calculateLine(i).toJson());
      }
    });

    test('invoice vectors: LINE vs INVOICE rounding level, grouping, largest-remainder allocation', () {
      expect(section('invoices'), hasLength(9));
      for (final c in section('invoices')) {
        expectCase(c, (i) => calculateInvoice(i).toJson());
      }
    });

    test('every result keeps base + taxes == total (inclusive total == amount; exclusive base == amount)', () {
      for (final c in section('lines').where((x) => x['expected'] != null)) {
        final input = c['input'] as Map<String, dynamic>;
        final r = calculateLine(input);
        final taxes = r.minorTaxes.fold(BigInt.zero, (s, x) => s + x);
        expect(r.minorBase + taxes, r.minorTotal, reason: c['id'] as String);
        final amount = parseAmount(input['amount'], input['currency']);
        expect(input['pricing'] == 'INCLUSIVE' ? r.minorTotal : r.minorBase, amount, reason: c['id'] as String);
      }
      for (final c in section('invoices').where((x) => x['expected'] != null)) {
        final input = c['input'] as Map<String, dynamic>;
        final cur = input['currency'];
        final r = calculateInvoice(input);
        BigInt amt(String s) => parseAmount(s, cur);
        expect(r.lines.fold(BigInt.zero, (s, l) => s + amt(l.total)), amt(r.total), reason: c['id'] as String);
        expect(r.componentTotals.fold(BigInt.zero, (s, t) => s + amt(t.tax)), amt(r.taxTotal), reason: c['id'] as String);
        for (final l in r.lines) {
          expect(amt(l.base) + l.components.fold(BigInt.zero, (s, x) => s + amt(x.tax)), amt(l.total));
        }
      }
    });

    test('deterministic: repeated calculations are identical', () {
      for (final c in [...section('lines'), ...section('invoices')].where((x) => x['expected'] != null)) {
        final input = inputOf(c);
        Object? run() => input.containsKey('lines') ? calculateInvoice(input).toJson() : calculateLine(input).toJson();
        final first = jsonEncode(run());
        for (var i = 0; i < 3; i++) {
          expect(jsonEncode(run()), first, reason: c['id'] as String);
        }
      }
    });

    test('rounding primitives: HALF_UP / HALF_EVEN / DOWN at and around halves; allocation sums exactly', () {
      Fraction f(int n, int d) => Fraction(BigInt.from(n), BigInt.from(d));
      final cases = <(Fraction, Map<String, int>)>[
        (f(5, 2), {'HALF_UP': 3, 'HALF_EVEN': 2, 'DOWN': 2}),
        (f(7, 2), {'HALF_UP': 4, 'HALF_EVEN': 4, 'DOWN': 3}),
        (f(1, 2), {'HALF_UP': 1, 'HALF_EVEN': 0, 'DOWN': 0}),
        (f(249, 100), {'HALF_UP': 2, 'HALF_EVEN': 2, 'DOWN': 2}),
        (f(251, 100), {'HALF_UP': 3, 'HALF_EVEN': 3, 'DOWN': 2}),
        (f(0, 1), {'HALF_UP': 0, 'HALF_EVEN': 0, 'DOWN': 0}),
      ];
      for (final (x, want) in cases) {
        want.forEach((mode, v) => expect(roundFraction(x, mode), BigInt.from(v), reason: '${x.n}/${x.d} $mode'));
      }
      expect(() => roundFraction(f(-1, 2), 'HALF_UP'), throwsA(isA<TaxEngineException>()));
      expect(allocate(BigInt.from(10), [f(10, 3), f(10, 3), f(10, 3)]), [BigInt.from(4), BigInt.from(3), BigInt.from(3)]);
      expect(allocate(BigInt.one, [f(3, 10), f(7, 10)]), [BigInt.zero, BigInt.one]);
    });

    test('no binary floating point: doubles are refused for amounts and rates', () {
      Map<String, Object?> line(Object? amount, Object? rate) => {
        'currency': 'INR',
        'pricing': 'EXCLUSIVE',
        'classKind': 'TAXABLE',
        'amount': amount,
        'components': [
          {'code': 'T', 'rate': rate},
        ],
        'policy': {'roundingMode': 'HALF_UP'},
      };
      expect(() => calculateLine(line(0.1, '5')), throwsA(isA<TaxEngineException>().having((e) => e.code, 'code', 'INVALID_AMOUNT')));
      expect(() => calculateLine(line('0.10', 5)), throwsA(isA<TaxEngineException>().having((e) => e.code, 'code', 'INVALID_RATE')));
      expect(calculateLine(line('0.30', '10')).taxTotal, '0.03');
    });
  });

  group('legacy adapter (delegates to offline/pos_tax.dart)', () {
    void checkLegacy(Map<String, dynamic> c) {
      final percent = c['percent'] as num;
      final r = calculateLegacyLine(
        unitPriceMilli: c['unitPriceMilli'] as int,
        quantity: c['quantity'] as int,
        percent: percent,
        inclTax: c['inclTax'] as String?,
      );
      final e = c['expected'] as Map<String, dynamic>;
      final label = '${c['id'] ?? c}';
      expect(r.mode, e['mode'], reason: label);
      expect(r.percent, e['percent'], reason: label);
      expect(r.lineSubMilli, e['lineSubMilli'], reason: label);
      expect(r.taxMilli, e['taxMilli'], reason: label);
      expect(r.totalMilli, e['totalMilli'], reason: label);
      expect(r.baseMilli + r.taxMilli, r.totalMilli, reason: label);
      final live = PosTax.computeLine(
        unitPriceMilli: c['unitPriceMilli'] as int,
        quantity: c['quantity'] as int,
        percent: percent,
        mode: PosTax.modeFromInclTax(c['inclTax'] as String?),
      );
      expect((r.taxMilli, r.totalMilli, r.mode), (live.taxMilli, live.totalMilli, live.mode), reason: label);
    }

    test('fixed vectors (server results): the Dart adapter equals the server for every case it accepts', () {
      final legacy = vectors['legacy'] as Map<String, dynamic>;
      final cases = (legacy['fixed'] as List).cast<Map<String, dynamic>>().where((c) => c['jsOnly'] != true).toList();
      expect(cases, hasLength(33));
      cases.forEach(checkLegacy);
    });

    test('300 seeded random server results: the Dart adapter matches every one', () {
      final random = (vectors['legacy'] as Map<String, dynamic>)['random'] as Map<String, dynamic>;
      final cases = (random['cases'] as List).cast<Map<String, dynamic>>();
      expect(cases, hasLength(300));
      cases.forEach(checkLegacy);
    });

    test('components: one combined TAX component, none for N.A; amounts stay in thousandths (no currency rounding)', () {
      final incl = calculateLegacyLine(unitPriceMilli: 100000, quantity: 1, percent: 18, inclTax: 'incl_tax');
      expect(incl.components.single.code, 'TAX');
      expect(incl.components.single.taxMilli, 15254);
      expect(incl.baseMilli, 84746);
      expect(calculateLegacyLine(unitPriceMilli: 250000, quantity: 2, percent: 18, inclTax: 'N.A').components, isEmpty);
      expect(calculateLegacyLine(unitPriceMilli: 12345, quantity: 3, percent: 18, inclTax: '').totalMilli, 43701);
    });
  });

  test('isolation: nothing outside lib/features/tax imports the new engine', () {
    final offenders = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.startsWith('lib/features/tax/')) continue;
      final src = f.readAsStringSync();
      if (RegExp(r'''import\s+['"][^'"]*(features/tax/|tax/engine/)''').hasMatch(src)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });
}
