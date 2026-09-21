import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  group('CartSale.fromJson', () {
    test('parses a live draft view: lines, tax fields, totals, version', () {
      final s = CartSale.fromJson(
        saleJson(
          id: 9,
          version: 4,
          items: [
            lineJson(
              id: 3,
              variationId: 42,
              quantity: 2,
              name: 'Tea',
              unitPrice: 5000,
              tax: 1200,
              taxPercent: 12,
              lineTotal: 11200,
            ),
          ],
          subtotal: 10000,
          tax: 1200,
          total: 11200,
        ),
      )!;
      expect((s.id, s.version, s.status, s.isDraft), (9, 4, 'draft', true));
      final l = s.items.single;
      expect(l.id, 3, reason: 'the LINE id used for update/remove');
      expect(
        l.productVariationId,
        42,
        reason: 'a different value from the line id',
      );
      expect(
        (l.quantity, l.productName, l.barcode, l.brandName),
        (2, 'Tea', 'BC3', 'Brand'),
      );
      expect(
        (l.unitPrice, l.taxPercent, l.taxAmount, l.taxIncluded, l.lineTotal),
        (5000, 12, 1200, false, 11200),
      );
      expect(
        l.discountAmount,
        isNull,
        reason: 'the live view has no per-line discount',
      );
      expect(
        (
          s.totals.subtotal,
          s.totals.taxTotal,
          s.totals.discountTotal,
          s.totals.grandTotal,
        ),
        (10000, 1200, 0, 11200),
      );
      expect(s.itemCount, 2);
    });

    test('an unavailable line keeps null prices and is flagged', () {
      final l = CartLine.fromJson({
        'id': 1,
        'product_variation_id': 5,
        'quantity': 2,
        'availability_status': 'unavailable',
        'unit_price': null,
        'line_total': null,
      })!;
      expect(l.isUnavailable, isTrue);
      expect((l.unitPrice, l.lineTotal), (null, null));
    });

    test('a per-line discount is read when the server sends one', () {
      expect(
        CartLine.fromJson({
          'id': 1,
          'product_variation_id': 2,
          'quantity': 1,
          'discount_amount': '2.500',
        })!.discountAmount,
        2.5,
      );
    });

    test('non-draft status is exposed', () {
      expect(
        CartSale.fromJson(saleJson(status: 'completed'))!.isDraft,
        isFalse,
      );
      expect(CartSale.fromJson(saleJson(status: 'held'))!.isDraft, isFalse);
    });

    test(
      'lines missing an id, variation or quantity are dropped, not fatal',
      () {
        final s = CartSale.fromJson({
          'id': 1,
          'version': 1,
          'items': [
            {'id': 1, 'product_variation_id': 2},
            {'product_variation_id': 2, 'quantity': 1},
            'garbage',
            lineJson(id: 8),
          ],
        })!;
        expect(s.items.map((i) => i.id), [8]);
      },
    );

    test('missing totals or wrong types produce null figures, not crashes', () {
      final s = CartSale.fromJson({
        'id': 1,
        'version': '3',
        'items': 'nope',
        'totals': 5,
      })!;
      expect(s.version, 3);
      expect(s.items, isEmpty);
      expect(s.totals.grandTotal, isNull);
    });

    test('a payload without an id or version is rejected', () {
      expect(CartSale.fromJson({'items': []}), isNull);
      expect(CartSale.fromJson({'id': 1}), isNull);
      expect(CartSale.fromJson(null), isNull);
      expect(CartSale.fromJson('x'), isNull);
    });
  });
}
