import 'package:buskit_pos/features/customers/models/customer.dart';
import 'package:buskit_pos/features/customers/models/customer_purchase.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_customer_service.dart';

void main() {
  group('Customer.fromJson', () {
    test('parses a full row', () {
      final c = Customer.fromJson(
        customerJson(
          id: 7,
          customerId: 'CUSTO7',
          fullname: 'Jane Doe',
          mobileno: '0400111222',
          email: 'jane@example.com',
          status: 1,
        ),
      )!;
      expect(
        (c.id, c.customerId, c.fullname, c.mobileno, c.email, c.status),
        (7, 'CUSTO7', 'Jane Doe', '0400111222', 'jane@example.com', 1),
      );
    });

    test('mobileno/email/status are optional', () {
      final c = Customer.fromJson(customerJson(mobileno: null, email: null))!;
      expect(c.mobileno, isNull);
      expect(c.email, isNull);
    });

    test('missing id, customer_id or fullname yields null (no crash on a malformed row)', () {
      final row = customerJson();
      expect(Customer.fromJson({...row, 'id': null}), isNull);
      expect(Customer.fromJson({...row, 'customer_id': null}), isNull);
      expect(Customer.fromJson({...row, 'fullname': null}), isNull);
      expect(Customer.fromJson(null), isNull);
      expect(Customer.fromJson('not a map'), isNull);
    });
  });

  group(
    'CustomerPurchase / CustomerPurchaseSummary / CustomerPurchasePage',
    () {
      test('parses a purchase row', () {
        final p = CustomerPurchase.fromJson({
          'id': 5,
          'sale_number': 'POS-5',
          'grand_total': 112.5,
          'completed_at': '2026-09-29 10:00:00',
        })!;
        expect((p.id, p.displayNumber, p.grandTotal), (5, 'POS-5', 112.5));
        expect(p.completedAt, isNotNull);
      });

      test('a missing sale_number falls back to "#id"', () {
        final p = CustomerPurchase.fromJson({'id': 9})!;
        expect(p.displayNumber, '#9');
      });

      test('summary defaults sensibly when fields are missing', () {
        final s = CustomerPurchaseSummary.fromJson(null);
        expect(s.transactionCount, 0);
        expect(s.totalPurchases, 0.0);
        expect(s.lastPurchaseAt, isNull);
      });

      test('page parses items + summary + pagination together', () {
        final page = CustomerPurchasePage.fromJson({
          'summary': {
            'transaction_count': 2,
            'total_purchases': 45500.0,
            'last_purchase_at': '2026-09-29 10:00:00',
          },
          'items': [
            {'id': 1, 'grand_total': 100},
            {'id': 2, 'grand_total': 200},
          ],
          'pagination': {'page': 1, 'limit': 20, 'total': 2, 'total_pages': 1},
        });
        expect(page.summary.transactionCount, 2);
        expect(page.items.length, 2);
        expect(page.hasMore, isFalse);
      });
    },
  );
}
