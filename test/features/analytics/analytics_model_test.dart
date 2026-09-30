import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_analytics_service.dart';

void main() {
  group('AnalyticsSummary.fromJson', () {
    test('parses a full response', () {
      final s = AnalyticsSummary.fromJson(
        analyticsSummaryJson(
          transactionCount: 4,
          salesTotal: 512.75,
          paymentBreakdown: [
            {'method': 'cash', 'count': 3, 'amount': 300},
            {'method': 'card', 'count': 1, 'amount': 212.75},
          ],
          topProducts: [
            {
              'product_variation_id': 9,
              'product_name': 'Latte',
              'quantity_sold': 5,
              'revenue': 100,
            },
          ],
          staffPerformance: [
            {
              'salesman_id': 'S1',
              'fullname': 'Jane',
              'transaction_count': 4,
              'sales_total': 512.75,
            },
          ],
        ),
      )!;
      expect((s.todayTransactionCount, s.todaySalesTotal), (4, 512.75));
      expect(s.paymentBreakdown, hasLength(2));
      expect(s.paymentBreakdown.first.method, 'cash');
      expect(s.topProducts.single.productName, 'Latte');
      expect(s.staffPerformance.single.fullname, 'Jane');
    });

    test('missing/empty fields default to zero totals and empty lists', () {
      final s = AnalyticsSummary.fromJson({})!;
      expect(s.todayTransactionCount, 0);
      expect(s.todaySalesTotal, 0);
      expect(s.paymentBreakdown, isEmpty);
      expect(s.topProducts, isEmpty);
      expect(s.staffPerformance, isEmpty);
    });

    test('a non-map response yields null (no crash)', () {
      expect(AnalyticsSummary.fromJson(null), isNull);
      expect(AnalyticsSummary.fromJson('not a map'), isNull);
    });
  });

  group('PaymentBreakdown.fromJson', () {
    test('a missing method yields null', () {
      expect(PaymentBreakdown.fromJson({'count': 1, 'amount': 1}), isNull);
    });
  });

  group('TopProduct.fromJson', () {
    test('a missing product_variation_id yields null', () {
      expect(TopProduct.fromJson({'product_name': 'X'}), isNull);
    });

    test(
      'a missing product_name falls back to null (view supplies "Item N")',
      () {
        final p = TopProduct.fromJson({
          'product_variation_id': 3,
          'quantity_sold': 1,
          'revenue': 1,
        })!;
        expect(p.productName, isNull);
      },
    );
  });

  group('StaffStat.fromJson', () {
    test('a missing salesman_id yields null', () {
      expect(StaffStat.fromJson({'fullname': 'Jane'}), isNull);
    });
  });
}
