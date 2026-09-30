import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';
import 'package:buskit_pos/features/analytics/state/analytics_controller.dart';
import 'package:buskit_pos/features/analytics/ui/analytics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_analytics_service.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

Future<AnalyticsController> pumpAnalytics(
  WidgetTester tester, {
  FakeAnalyticsService? service,
}) async {
  final controller = AnalyticsController(service ?? FakeAnalyticsService());
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalyticsController>.value(
      value: controller,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: AnalyticsView())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('shows the header and loads real figures from the server', (
    tester,
  ) async {
    final svc = FakeAnalyticsService();
    svc.onGetSummary = () async => AnalyticsSummary.fromJson(
      analyticsSummaryJson(transactionCount: 2, salesTotal: 55),
    )!;
    await pumpAnalytics(tester, service: svc);
    expect(find.text('Analytics'), findsOneWidget);
    expect(find.text('55.00'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets(
    'an empty store shows honest "no sales yet" messages, not invented figures',
    (tester) async {
      await pumpAnalytics(tester);
      expect(find.text('No completed sales today yet.'), findsNWidgets(2));
      expect(
        find.text('No completed sales in the last 7 days.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('Inventory Alerts always stays a labelled placeholder', (
    tester,
  ) async {
    await pumpAnalytics(tester);
    expect(find.text('Inventory Alerts'), findsOneWidget);
    expect(find.text('Not available'), findsOneWidget);
  });

  testWidgets('a load failure shows an error with retry; retry recovers', (
    tester,
  ) async {
    final svc = FakeAnalyticsService();
    svc.onGetSummary = () async => throw netDown;
    await pumpAnalytics(tester, service: svc);
    expect(find.textContaining('Cannot reach'), findsOneWidget);
    svc.onGetSummary = () async => zeroAnalyticsSummary;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('No completed sales today yet.'), findsNWidgets(2));
  });

  testWidgets('payment methods and top products render with real amounts', (
    tester,
  ) async {
    final svc = FakeAnalyticsService();
    svc.onGetSummary = () async => AnalyticsSummary.fromJson(
      analyticsSummaryJson(
        paymentBreakdown: [
          {'method': 'cash', 'count': 2, 'amount': 40},
        ],
        topProducts: [
          {
            'product_variation_id': 1,
            'product_name': 'Latte',
            'quantity_sold': 3,
            'revenue': 30,
          },
        ],
      ),
    )!;
    await pumpAnalytics(tester, service: svc);
    expect(find.text('Cash'), findsOneWidget);
    expect(find.text('40.00'), findsOneWidget);
    expect(find.text('Latte'), findsOneWidget);
    expect(find.text('3 sold'), findsOneWidget);
  });
}
