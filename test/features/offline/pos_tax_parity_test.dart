// Offline tax = server tax. Every expected value below was produced by
// running the server's own function (buskit-web services/pos/posTax.js
// computeLine) locally with node — no database, no network:
//   [unitPriceMilli, quantity, percent, inclTax, mode, percent, lineSub, tax, total]
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/pos_tax.dart';
import 'package:flutter_test/flutter_test.dart';

const serverResults = <List<Object?>>[
  [100000, 1, 18, 'incl_tax', 'inclusive', 18, 100000, 15254, 100000],
  [100000, 1, 18, '', 'exclusive', 18, 100000, 18000, 118000],
  [100000, 3, 5, 'incl_tax', 'inclusive', 5, 300000, 14286, 300000],
  [99990, 7, 12, null, 'exclusive', 12, 699930, 83992, 783922],
  [12345, 3, 18, 'incl_tax', 'inclusive', 18, 37035, 5649, 37035],
  [12345, 3, 18, 'excl', 'exclusive', 18, 37035, 6666, 43701],
  [1, 1, 18, 'incl_tax', 'inclusive', 18, 1, 0, 1],
  [1, 1, 18, '', 'exclusive', 18, 1, 0, 1],
  [5, 1, 5, '', 'exclusive', 5, 5, 0, 5],
  [333, 3, 2.5, 'incl_tax', 'inclusive', 2.5, 999, 24, 999],
  [49999, 9, 28, '', 'exclusive', 28, 449991, 125997, 575988],
  [250000, 2, 0, 'incl_tax', 'inclusive', 0, 500000, 0, 500000],
  [250000, 2, 0, '', 'exclusive', 0, 500000, 0, 500000],
  [250000, 2, 18, 'N.A', 'none', 0, 500000, 0, 500000],
  [1000, 1, 1.2000000476837158, '', 'exclusive', 1.2, 1000, 12, 1012],
  [7777, 13, 12.5, 'incl_tax', 'inclusive', 12.5, 101101, 11233, 101101],
  [10, 1, 5, 'incl_tax', 'inclusive', 5, 10, 0, 10],
  [15, 1, 5, '', 'exclusive', 5, 15, 1, 16],
  [1050, 1, 5, 'incl_tax', 'inclusive', 5, 1050, 50, 1050],
  [105, 1, 5, 'incl_tax', 'inclusive', 5, 105, 5, 105],
  [21, 1, 5, '', 'exclusive', 5, 21, 1, 22],
  [1234567, 4, 18, 'incl_tax', 'inclusive', 18, 4938268, 753295, 4938268],
  [1234567, 4, 18, '', 'exclusive', 18, 4938268, 888888, 5827156],
  [3, 1, 50, '', 'exclusive', 50, 3, 2, 5],
  [3, 1, 50, 'incl_tax', 'inclusive', 50, 3, 1, 3],
  [
    9999999,
    9999,
    28,
    '',
    'exclusive',
    28,
    99989990001,
    27997197200,
    127987187201,
  ],
  [
    9999999,
    9999,
    28,
    'incl_tax',
    'inclusive',
    28,
    99989990001,
    21872810313,
    99989990001,
  ],
  [2, 1, 25, '', 'exclusive', 25, 2, 1, 3],
  [6, 1, 25, '', 'exclusive', 25, 6, 2, 8],
  [42, 1, 16.6667, 'incl_tax', 'inclusive', 16.6667, 42, 6, 42],
];

void main() {
  test('offline tax matches the server for every recorded case (inclusive, exclusive, none, zero)', () {
    for (final r in serverResults) {
      final mode = PosTax.modeFromInclTax(r[3] as String?);
      expect(mode, r[4], reason: 'mode for $r');
      final t = PosTax.computeLine(
        unitPriceMilli: r[0] as int,
        quantity: r[1] as int,
        percent: r[2] as num,
        mode: mode,
      );
      expect(t.percent, (r[5] as num).toDouble(), reason: 'percent for $r');
      expect(t.lineSubMilli, r[6], reason: 'line amount for $r');
      expect(t.taxMilli, r[7], reason: 'tax for $r');
      expect(t.totalMilli, r[8], reason: 'total for $r');
    }
  });

  test(
    'rounding matches the server: half-up at exactly .5 milli, down below it',
    () {
      // 15 * 5% = 0.75 -> 1; 3 * 50% = 1.5 -> 2; 2 * 25% = 0.5 -> 1;
      // 105 * 5/105 = 5.0 exactly; 10 * 5/105 = 0.476 -> 0.
      int tax(int price, num pct, String mode) => PosTax.computeLine(
        unitPriceMilli: price,
        quantity: 1,
        percent: pct,
        mode: mode,
      ).taxMilli;
      expect(tax(15, 5, 'exclusive'), 1);
      expect(tax(3, 50, 'exclusive'), 2);
      expect(tax(2, 25, 'exclusive'), 1);
      expect(tax(105, 5, 'inclusive'), 5);
      expect(tax(10, 5, 'inclusive'), 0);
      expect(PosTax.roundMilli(0.5), 1);
      expect(PosTax.roundMilli(0.4999), 0);
      expect(PosTax.normalizePercent(1.2000000476837158), 1.2);
      expect(PosTax.normalizePercent(-3), 0);
      expect(PosTax.normalizePercent(double.nan), 0);
    },
  );

  test(
    'a cached product priced offline gives the same figures as the server',
    () {
      const p = OfflineProduct(
        productVariationId: 1,
        productName: 'Tea',
        sellingMode: 'PIECE',
        sellPriceMilli: 12345,
        taxPercent: 18,
        taxMode: 'inclusive',
      );
      final line = OfflineCheckoutLine.fromProduct(p, 3);
      expect(line.taxAmountMilli, 5649);
      expect(line.lineTotalMilli, 37035);
      final more = line.withQuantity(7);
      final server = PosTax.computeLine(
        unitPriceMilli: 12345,
        quantity: 7,
        percent: 18,
        mode: 'inclusive',
      );
      expect(more.taxAmountMilli, server.taxMilli);
      expect(more.lineTotalMilli, server.totalMilli);
      expect(more.unitPriceMilli, 12345, reason: 'price snapshot kept');
    },
  );
}
