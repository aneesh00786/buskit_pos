import 'package:buskit_pos/core/utils/server_time.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  group('HeldSaleSummary.fromJson (raw pos_sales row)', () {
    test('reads the useful fields and ignores internal columns', () {
      final s = HeldSaleSummary.fromJson(
        heldRowJson(
          id: 12,
          version: 3,
          saleNumber: 'POS-00000012',
          salesman: 'SALES1',
          total: 56.5,
        ),
      )!;
      expect((s.id, s.version, s.status), (12, 3, 'held'));
      expect(
        (s.saleNumber, s.salesmanId, s.registerId, s.grandTotal),
        ('POS-00000012', 'SALES1', 5, 56.5),
      );
      expect(s.title, 'POS-00000012');
    });

    test('a draft-style row has no sale number and null totals (the list gives no total for held sales)', () {
      final s = HeldSaleSummary.fromJson(heldRowJson(id: 7))!;
      expect(s.saleNumber, isNull);
      expect(s.grandTotal, isNull);
      expect(s.title, 'Sale #7');
    });

    test('MySQL timestamps without a zone are read as UTC', () {
      final s = HeldSaleSummary.fromJson(
        heldRowJson(id: 1, heldAt: '2026-09-21 15:23:52'),
      )!;
      expect(s.heldAt, DateTime.utc(2026, 9, 21, 15, 23, 52));
      expect(s.heldAt!.isUtc, isTrue);
      expect(s.createdAt, DateTime.utc(2026, 9, 21, 15));
    });

    test('ISO timestamps are read as well', () {
      final s = HeldSaleSummary.fromJson(
        heldRowJson(id: 1, heldAt: '2026-09-21T15:23:52.000Z'),
      )!;
      expect(s.heldAt, DateTime.utc(2026, 9, 21, 15, 23, 52));
    });

    test(
      'rows without an id or version are rejected; wrong types do not crash',
      () {
        expect(HeldSaleSummary.fromJson({'version': 2}), isNull);
        expect(HeldSaleSummary.fromJson({'id': 2}), isNull);
        expect(HeldSaleSummary.fromJson('x'), isNull);
        expect(HeldSaleSummary.fromJson(null), isNull);
        final s = HeldSaleSummary.fromJson({
          'id': '5',
          'version': '2',
          'held_at': 12,
          'grand_total': 'abc',
        })!;
        expect((s.id, s.version, s.heldAt, s.grandTotal), (5, 2, null, null));
      },
    );
  });

  group('server time', () {
    test('parse variants', () {
      expect(
        parseServerTime('2026-09-21 15:23:52'),
        DateTime.utc(2026, 9, 21, 15, 23, 52),
      );
      expect(
        parseServerTime('2026-09-21T15:23:52Z'),
        DateTime.utc(2026, 9, 21, 15, 23, 52),
      );
      expect(
        parseServerTime('2026-09-21T15:23:52+02:00'),
        DateTime.utc(2026, 9, 21, 13, 23, 52),
      );
      expect(parseServerTime(''), isNull);
      expect(parseServerTime('not a date'), isNull);
      expect(parseServerTime(null), isNull);
      expect(parseServerTime(5), isNull);
    });

    test('formatTimestamp is compact and zero-padded', () {
      final t = DateTime(2026, 9, 5, 4, 7);
      expect(formatTimestamp(t), '5 Sep 04:07');
    });
  });
}
