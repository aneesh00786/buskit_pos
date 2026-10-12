/// POS Phase P2.1 — pure, data-driven tax engine: multi-component taxes,
/// compound policies, zero-rated / exempt classes, configurable rounding and
/// currency minor units. An exact port of buskit-web
/// `services/pos/tax/taxEngine.js`; both are pinned by the shared vectors in
/// test/fixtures/tax_vectors.json.
///
/// ISOLATED: checkout, the cart, offline checkout and sync, receipts and
/// reports do NOT use this yet — offline tax is still `offline/pos_tax.dart`
/// (unchanged). Inputs are the JSON-shaped maps tax configuration will be
/// delivered as (see the JS file for the field list); nothing has a default
/// and nothing assumes any jurisdiction's rules.
///
/// Guarantee (checked on every result): base + sum(component taxes) == total.
library;

import 'tax_currency.dart';
import 'tax_rational.dart';

const _pricing = ['EXCLUSIVE', 'INCLUSIVE'];
const _classKinds = ['TAXABLE', 'ZERO_RATED', 'EXEMPT', 'OUT_OF_SCOPE'];
const _bases = ['BASE', 'BASE_PLUS_PRIOR'];
const _inclusiveMethods = ['COMPONENT_FROM_GROSS', 'BASE_FIRST'];
const _residueTargets = [
  'BASE',
  'LARGEST_COMPONENT',
  'COMPONENTS_PROPORTIONAL',
];
const _compoundBases = ['ROUNDED_PRIOR', 'UNROUNDED_PRIOR'];
const _roundingLevels = ['LINE', 'INVOICE'];

class TaxComponentAmount {
  const TaxComponentAmount({
    required this.code,
    required this.rate,
    required this.tax,
  });
  final String code;

  /// The rate exactly as configured (a percent string).
  final String rate;
  final String tax;

  Map<String, Object?> toJson() => {'code': code, 'rate': rate, 'tax': tax};
}

class TaxLineResult {
  const TaxLineResult({
    required this.currency,
    required this.base,
    required this.components,
    required this.taxTotal,
    required this.total,
    required this.residue,
    required this.residueAppliedTo,
    required this.minorBase,
    required this.minorTaxes,
    required this.minorTotal,
  });
  final String currency;
  final String base;
  final List<TaxComponentAmount> components;
  final String taxTotal;
  final String total;

  /// BASE_FIRST only: amount - rounded base - rounded taxes before the residue
  /// was applied (signed); "0" otherwise.
  final String residue;
  final String? residueAppliedTo;
  final BigInt minorBase;
  final List<BigInt> minorTaxes;
  final BigInt minorTotal;

  Map<String, Object?> toJson() => {
    'base': base,
    'components': [for (final c in components) c.toJson()],
    'taxTotal': taxTotal,
    'total': total,
    'residue': residue,
    'residueAppliedTo': residueAppliedTo,
  };
}

class TaxInvoiceLine {
  const TaxInvoiceLine({
    required this.base,
    required this.components,
    required this.taxTotal,
    required this.total,
  });
  final String base;
  final List<TaxComponentAmount> components;
  final String taxTotal;
  final String total;

  Map<String, Object?> toJson() => {
    'base': base,
    'components': [for (final c in components) c.toJson()],
    'taxTotal': taxTotal,
    'total': total,
  };
}

class TaxInvoiceResult {
  const TaxInvoiceResult({
    required this.lines,
    required this.componentTotals,
    required this.baseTotal,
    required this.taxTotal,
    required this.total,
  });
  final List<TaxInvoiceLine> lines;
  final List<TaxComponentAmount> componentTotals;
  final String baseTotal;
  final String taxTotal;
  final String total;

  Map<String, Object?> toJson() => {
    'lines': [for (final l in lines) l.toJson()],
    'componentTotals': [for (final c in componentTotals) c.toJson()],
    'baseTotal': baseTotal,
    'taxTotal': taxTotal,
    'total': total,
  };
}

class _Component {
  _Component(this.code, this.rateText, this.rate, this.basis);
  final String code;
  final String rateText;
  final Fraction rate;
  final String basis;
  String get key => '$code|${rate.n}/${rate.d}';
}

BigInt _sum(Iterable<BigInt> xs) => xs.fold(BigInt.zero, (s, x) => s + x);
bool _hasCompound(List<_Component> comps) =>
    comps.any((c) => c.basis == 'BASE_PLUS_PRIOR');

List<_Component> _parseComponents(Object? classKind, Object? components) {
  if (components is! List) {
    throw const TaxEngineException(
      'INVALID_COMPONENTS',
      'Components must be a list',
    );
  }
  final seen = <String>{};
  final out = <_Component>[];
  for (final c in components) {
    final map = c is Map ? c : null;
    final basis = map == null || !map.containsKey('basis')
        ? 'BASE'
        : map['basis'];
    final code = map?['code'];
    if (map == null ||
        code is! String ||
        code.isEmpty ||
        seen.contains(code) ||
        !_bases.contains(basis)) {
      throw const TaxEngineException(
        'INVALID_COMPONENTS',
        'Each component needs a unique code and a valid basis',
      );
    }
    seen.add(code);
    final rate = parseRate(map['rate']);
    out.add(_Component(code, map['rate'] as String, rate, basis as String));
  }
  if (classKind == 'TAXABLE' && out.isEmpty) {
    throw const TaxEngineException(
      'INVALID_COMPONENTS',
      'A taxable item needs at least one component',
    );
  }
  if (classKind == 'ZERO_RATED' &&
      (out.isEmpty || out.any((c) => c.rate.n != BigInt.zero))) {
    throw const TaxEngineException(
      'INVALID_COMPONENTS',
      'A zero-rated item needs components whose rates are all 0',
    );
  }
  if ((classKind == 'EXEMPT' || classKind == 'OUT_OF_SCOPE') &&
      out.isNotEmpty) {
    throw TaxEngineException(
      'INVALID_COMPONENTS',
      'An $classKind item has no tax components',
    );
  }
  if (!_classKinds.contains(classKind)) {
    throw TaxEngineException(
      'INVALID_COMPONENTS',
      'Unknown class kind: $classKind',
    );
  }
  return out;
}

Map<Object?, Object?> _checkPolicy(
  Object? policy,
  Object? pricing,
  List<_Component> comps,
) {
  final p = policy is Map ? policy : const <Object?, Object?>{};
  if (!roundingModes.contains(p['roundingMode'])) {
    throw const TaxEngineException(
      'INVALID_POLICY',
      'roundingMode is required',
    );
  }
  if (!_pricing.contains(pricing))
    throw TaxEngineException('INVALID_POLICY', 'Unknown pricing: $pricing');
  if (pricing == 'INCLUSIVE' &&
      !_inclusiveMethods.contains(p['inclusiveMethod'])) {
    throw const TaxEngineException(
      'INVALID_POLICY',
      'inclusiveMethod is required for inclusive pricing',
    );
  }
  if (pricing == 'INCLUSIVE' &&
      p['inclusiveMethod'] == 'BASE_FIRST' &&
      !_residueTargets.contains(p['residueTarget'])) {
    throw const TaxEngineException(
      'INVALID_POLICY',
      'residueTarget is required for BASE_FIRST',
    );
  }
  if (_hasCompound(comps) && !_compoundBases.contains(p['compoundBasis'])) {
    throw const TaxEngineException(
      'INVALID_POLICY',
      'compoundBasis is required for compound components',
    );
  }
  return p;
}

List<BigInt> _exclusiveTaxes(
  BigInt baseMinor,
  List<_Component> comps,
  Map<Object?, Object?> policy,
) {
  final mode = policy['roundingMode'] as String;
  final taxes = <BigInt>[];
  var priorRounded = BigInt.zero;
  var priorExact = Fraction.zero;
  for (final c in comps) {
    final Fraction basis;
    if (c.basis == 'BASE') {
      basis = Fraction(baseMinor);
    } else if (policy['compoundBasis'] == 'ROUNDED_PRIOR') {
      basis = Fraction(baseMinor + priorRounded);
    } else {
      basis = Fraction(baseMinor) + priorExact;
    }
    final exact = basis * c.rate;
    final t = roundFraction(exact, mode);
    taxes.add(t);
    priorRounded += t;
    priorExact = priorExact + exact;
  }
  return taxes;
}

/// Each component's exact share of the base (c_k) and M = 1 + sum(c_k).
({List<Fraction> cs, Fraction m}) _coefficients(List<_Component> comps) {
  final cs = <Fraction>[];
  for (final c in comps) {
    cs.add(
      c.basis == 'BASE'
          ? c.rate
          : c.rate * cs.fold(Fraction.one, (s, x) => s + x),
    );
  }
  return (cs: cs, m: cs.fold(Fraction.one, (s, x) => s + x));
}

TaxLineResult calculateLine(Map<String, Object?> input) {
  final currency = input['currency'];
  final pricing = input['pricing'];
  final classKind = input['classKind'];
  final amount = parseAmount(input['amount'], currency);
  final comps = _parseComponents(classKind, input['components']);
  final policy = _checkPolicy(input['policy'], pricing, comps);
  final mode = policy['roundingMode'] as String;

  List<BigInt> taxes;
  BigInt base;
  BigInt total;
  var residue = BigInt.zero;
  String? residueAppliedTo;
  if (classKind != 'TAXABLE') {
    taxes = [for (final _ in comps) BigInt.zero];
    base = amount;
    total = amount;
  } else if (pricing == 'EXCLUSIVE') {
    taxes = _exclusiveTaxes(amount, comps, policy);
    base = amount;
    total = amount + _sum(taxes);
  } else if (policy['inclusiveMethod'] == 'COMPONENT_FROM_GROSS') {
    if (_hasCompound(comps) && policy['compoundBasis'] == 'ROUNDED_PRIOR') {
      throw const TaxEngineException(
        'UNSUPPORTED_COMBINATION',
        'COMPONENT_FROM_GROSS works from exact shares; use UNROUNDED_PRIOR or BASE_FIRST',
      );
    }
    final k = _coefficients(comps);
    taxes = [
      for (final c in k.cs) roundFraction(Fraction(amount) * c / k.m, mode),
    ];
    base = amount - _sum(taxes);
    total = amount;
  } else {
    final k = _coefficients(comps);
    final base0 = roundFraction(Fraction(amount) / k.m, mode);
    taxes = _exclusiveTaxes(base0, comps, policy);
    residue = amount - base0 - _sum(taxes);
    base = base0;
    total = amount;
    if (residue != BigInt.zero) {
      final target = policy['residueTarget'];
      final taxSum = _sum(taxes);
      if (target == 'BASE' ||
          (target == 'COMPONENTS_PROPORTIONAL' && taxSum == BigInt.zero)) {
        base = base0 + residue;
        residueAppliedTo = 'BASE';
      } else if (target == 'LARGEST_COMPONENT') {
        var largest = 0;
        for (var j = 1; j < taxes.length; j++) {
          if (taxes[j] > taxes[largest]) largest = j;
        }
        taxes[largest] += residue;
        residueAppliedTo = 'LARGEST_COMPONENT';
      } else {
        final mag = residue.abs();
        final parts = allocate(mag, [
          for (final t in taxes) Fraction(mag * t, taxSum),
        ]);
        taxes = [
          for (var i = 0; i < taxes.length; i++)
            residue.isNegative ? taxes[i] - parts[i] : taxes[i] + parts[i],
        ];
        residueAppliedTo = 'COMPONENTS_PROPORTIONAL';
      }
      if (taxes.any((t) => t.isNegative)) {
        throw const TaxEngineException(
          'RESIDUE_NOT_ALLOCATABLE',
          'The rounding residue would make a tax negative',
        );
      }
    }
    if (base.isNegative) {
      throw const TaxEngineException(
        'RESIDUE_NOT_ALLOCATABLE',
        'The rounding residue would make the base negative',
      );
    }
  }
  if (base + _sum(taxes) != total) {
    throw const TaxEngineException(
      'INVARIANT_VIOLATION',
      'base + taxes != total',
    );
  }

  String fmt(BigInt m) => formatAmount(m, currency);
  return TaxLineResult(
    currency: currency as String,
    base: fmt(base),
    components: [
      for (var i = 0; i < comps.length; i++)
        TaxComponentAmount(
          code: comps[i].code,
          rate: comps[i].rateText,
          tax: fmt(taxes[i]),
        ),
    ],
    taxTotal: fmt(_sum(taxes)),
    total: fmt(total),
    residue: fmt(residue),
    residueAppliedTo: residueAppliedTo,
    minorBase: base,
    minorTaxes: List.unmodifiable(taxes),
    minorTotal: total,
  );
}

class _Row {
  _Row(this.base, this.comps, this.taxes, this.total);
  final BigInt base;
  final List<_Component> comps;
  final List<BigInt> taxes;
  final BigInt total;
}

TaxInvoiceResult calculateInvoice(Map<String, Object?> input) {
  final currency = input['currency'];
  final pricing = input['pricing'];
  final lines = input['lines'];
  final policy = input['policy'] is Map
      ? input['policy'] as Map
      : const <Object?, Object?>{};
  if (!_roundingLevels.contains(policy['roundingLevel'])) {
    throw const TaxEngineException(
      'INVALID_POLICY',
      'roundingLevel is required',
    );
  }
  minorUnits(currency);
  if (lines is! List)
    throw const TaxEngineException(
      'INVALID_COMPONENTS',
      'Lines must be a list',
    );

  final List<_Row> rows;
  if (policy['roundingLevel'] == 'LINE') {
    rows = [
      for (final l in lines.cast<Map>())
        () {
          final r = calculateLine({
            'currency': currency,
            'pricing': pricing,
            'policy': policy,
            'amount': l['amount'],
            'classKind': l['classKind'],
            'components': l['components'],
          });
          return _Row(
            r.minorBase,
            _parseComponents(l['classKind'], l['components']),
            r.minorTaxes,
            r.minorTotal,
          );
        }(),
    ];
  } else {
    final parsed =
        <({BigInt amount, Object? classKind, List<_Component> comps})>[];
    for (final l in lines.cast<Map>()) {
      final amount = parseAmount(l['amount'], currency);
      final comps = _parseComponents(l['classKind'], l['components']);
      _checkPolicy(policy, pricing, comps);
      if (_hasCompound(comps)) {
        throw const TaxEngineException(
          'UNSUPPORTED_COMBINATION',
          'Invoice-level rounding does not support compound components',
        );
      }
      if (pricing == 'INCLUSIVE' &&
          policy['inclusiveMethod'] != 'COMPONENT_FROM_GROSS') {
        throw const TaxEngineException(
          'UNSUPPORTED_COMBINATION',
          'Invoice-level inclusive rounding needs COMPONENT_FROM_GROSS',
        );
      }
      parsed.add((amount: amount, classKind: l['classKind'], comps: comps));
    }
    // Group by (code, exact rate); round each group's exact total once, then
    // split it back over its lines by largest remainder.
    final groups = <String, List<({int li, int ci, Fraction exact})>>{};
    for (var li = 0; li < parsed.length; li++) {
      final line = parsed[li];
      final m = line.comps.fold(Fraction.one, (s, c) => s + c.rate);
      for (var ci = 0; ci < line.comps.length; ci++) {
        final c = line.comps[ci];
        final exact = line.classKind != 'TAXABLE'
            ? Fraction.zero
            : pricing == 'EXCLUSIVE'
            ? Fraction(line.amount) * c.rate
            : Fraction(line.amount) * c.rate / m;
        groups.putIfAbsent(c.key, () => []).add((li: li, ci: ci, exact: exact));
      }
    }
    final taxes = [
      for (final l in parsed) [for (final _ in l.comps) BigInt.zero],
    ];
    for (final members in groups.values) {
      final groupTotal = roundFraction(
        members.fold(Fraction.zero, (s, x) => s + x.exact),
        policy['roundingMode'] as String,
      );
      final parts = allocate(groupTotal, [for (final x in members) x.exact]);
      for (var i = 0; i < members.length; i++) {
        taxes[members[i].li][members[i].ci] = parts[i];
      }
    }
    rows = [
      for (var li = 0; li < parsed.length; li++)
        _Row(
          pricing == 'EXCLUSIVE'
              ? parsed[li].amount
              : parsed[li].amount - _sum(taxes[li]),
          parsed[li].comps,
          taxes[li],
          pricing == 'EXCLUSIVE'
              ? parsed[li].amount + _sum(taxes[li])
              : parsed[li].amount,
        ),
    ];
  }

  String fmt(BigInt m) => formatAmount(m, currency);
  final totals = <String, ({String code, String rate, BigInt tax})>{};
  for (final r in rows) {
    for (var i = 0; i < r.comps.length; i++) {
      final c = r.comps[i];
      final prev = totals[c.key];
      totals[c.key] = (
        code: c.code,
        rate: prev?.rate ?? c.rateText,
        tax: (prev?.tax ?? BigInt.zero) + r.taxes[i],
      );
    }
  }
  final baseTotal = _sum(rows.map((r) => r.base));
  final taxTotal = _sum(rows.map((r) => _sum(r.taxes)));
  final total = _sum(rows.map((r) => r.total));
  if (baseTotal + taxTotal != total) {
    throw const TaxEngineException(
      'INVARIANT_VIOLATION',
      'invoice base + taxes != total',
    );
  }
  return TaxInvoiceResult(
    lines: [
      for (final r in rows)
        TaxInvoiceLine(
          base: fmt(r.base),
          components: [
            for (var i = 0; i < r.comps.length; i++)
              TaxComponentAmount(
                code: r.comps[i].code,
                rate: r.comps[i].rateText,
                tax: fmt(r.taxes[i]),
              ),
          ],
          taxTotal: fmt(_sum(r.taxes)),
          total: fmt(r.total),
        ),
    ],
    componentTotals: [
      for (final t in totals.values)
        TaxComponentAmount(code: t.code, rate: t.rate, tax: fmt(t.tax)),
    ],
    baseTotal: fmt(baseTotal),
    taxTotal: fmt(taxTotal),
    total: fmt(total),
  );
}
