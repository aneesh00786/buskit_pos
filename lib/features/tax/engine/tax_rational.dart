/// POS Phase P2.1 — exact rational arithmetic, rounding and largest-remainder
/// allocation for the tax engine. A port of buskit-web
/// `services/pos/tax/taxRational.js`; parity is pinned by the shared vectors
/// (test/fixtures/tax_vectors.json).
///
/// BigInt only: no binary floating point touches an amount or a rate.
/// NOT used by checkout, sales, refunds, reports or offline sync (Phase 1).
library;

class TaxEngineException implements Exception {
  const TaxEngineException(this.code, this.message);

  /// UNKNOWN_CURRENCY | INVALID_AMOUNT | AMOUNT_NOT_REPRESENTABLE |
  /// INVALID_RATE | INVALID_COMPONENTS | INVALID_POLICY |
  /// UNSUPPORTED_COMBINATION | RESIDUE_NOT_ALLOCATABLE | INVARIANT_VIOLATION
  final String code;
  final String message;

  @override
  String toString() => 'TaxEngineException($code): $message';
}

const roundingModes = ['HALF_UP', 'HALF_EVEN', 'DOWN'];

/// An exact fraction in lowest terms with a positive denominator.
class Fraction {
  factory Fraction(BigInt n, [BigInt? d]) {
    var num = n;
    var den = d ?? BigInt.one;
    if (den == BigInt.zero) {
      throw const TaxEngineException('INVARIANT_VIOLATION', 'Division by zero');
    }
    if (den.isNegative) {
      num = -num;
      den = -den;
    }
    final g = num.gcd(den);
    final div = g == BigInt.zero ? BigInt.one : g;
    return Fraction._(num ~/ div, den ~/ div);
  }
  const Fraction._(this.n, this.d);

  final BigInt n;
  final BigInt d;

  static final zero = Fraction(BigInt.zero);
  static final one = Fraction(BigInt.one);

  Fraction operator +(Fraction o) => Fraction(n * o.d + o.n * d, d * o.d);
  Fraction operator *(Fraction o) => Fraction(n * o.n, d * o.d);
  Fraction operator /(Fraction o) => Fraction(n * o.d, d * o.n);

  /// Floor of a non-negative fraction.
  BigInt get floor => n ~/ d;

  int compareTo(Fraction o) => (n * o.d).compareTo(o.n * d);
}

/// Rounds a NON-NEGATIVE fraction to whole minor units.
BigInt roundFraction(Fraction a, String mode) {
  if (a.n.isNegative) {
    throw const TaxEngineException(
      'INVARIANT_VIOLATION',
      'Cannot round a negative amount',
    );
  }
  final q = a.n ~/ a.d;
  final r = a.n - q * a.d;
  final twoR = r * BigInt.two;
  switch (mode) {
    case 'DOWN':
      return q;
    case 'HALF_UP':
      return twoR >= a.d ? q + BigInt.one : q;
    case 'HALF_EVEN':
      if (twoR > a.d) return q + BigInt.one;
      if (twoR < a.d) return q;
      return q.isEven ? q : q + BigInt.one;
    default:
      throw TaxEngineException(
        'INVALID_POLICY',
        'Unknown rounding mode: $mode',
      );
  }
}

/// Splits [total] whole units over exact non-negative [shares]: floors first,
/// then one unit each to the largest remainders, ties to the lowest index.
/// The result sums EXACTLY to [total].
List<BigInt> allocate(BigInt total, List<Fraction> shares) {
  final floors = [for (final s in shares) s.floor];
  var remaining = total - floors.fold(BigInt.zero, (s, x) => s + x);
  if (remaining.isNegative || remaining > BigInt.from(shares.length)) {
    throw const TaxEngineException(
      'INVARIANT_VIOLATION',
      'Allocation total does not match its shares',
    );
  }
  final order = [for (var i = 0; i < shares.length; i++) i]
    ..sort((a, b) {
      final ra = Fraction(shares[a].n - floors[a] * shares[a].d, shares[a].d);
      final rb = Fraction(shares[b].n - floors[b] * shares[b].d, shares[b].d);
      final c = rb.compareTo(ra);
      return c != 0 ? c : a - b;
    });
  final out = List<BigInt>.of(floors);
  for (final i in order) {
    if (remaining == BigInt.zero) break;
    out[i] += BigInt.one;
    remaining -= BigInt.one;
  }
  return out;
}
