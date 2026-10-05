// C4.x analytics follow-ups in the app: refund-adjusted top products and
// staff totals (server figures, gross fallback for older servers), the
// store time zone shown with the period, and a date-range picker that sends
// from/to to the server. Flutter never computes these totals itself.
import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';
import 'package:buskit_pos/features/analytics/state/analytics_controller.dart';
import 'package:buskit_pos/features/analytics/ui/analytics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_analytics_service.dart';

Map<String, dynamic> c4xJson({String from = '2026-10-05', String to = '2026-10-05'}) => {
  ...analyticsSummaryJson(transactionCount: 3, salesTotal: 600),
  'period': {'from': from, 'to': to, 'timezone': 'Australia/Melbourne', 'basis': 'sales by completion date; refunds by refund date'},
  'top_products_period': {'from': '2026-09-29', 'to': '2026-10-05'},
  'top_products': [
    {
      'product_variation_id': 4,
      'product_name': 'Iced Latte',
      'quantity_sold': 3,
      'revenue': 600,
      'refunded_quantity': 0,
      'refunded_amount': 0,
      'net_quantity': 3,
      'net_revenue': 600,
    },
    {
      'product_variation_id': 5,
      'product_name': 'Croissant',
      'quantity_sold': 5,
      'revenue': 500,
      'refunded_quantity': 4,
      'refunded_amount': 400,
      'net_quantity': 1,
      'net_revenue': 100,
    },
  ],
  'staff_performance': [
    {'salesman_id': 'S1', 'fullname': 'Asha', 'transaction_count': 2, 'sales_total': 500, 'refunded_total': 100, 'net_sales_total': 400},
    {'salesman_id': 'S2', 'fullname': 'Ben', 'transaction_count': 1, 'sales_total': 100, 'refunded_total': 0, 'net_sales_total': 100},
  ],
};

Future<(FakeAnalyticsService, AnalyticsController)> pump(WidgetTester tester, Map<String, dynamic> Function() json) async {
  final svc = FakeAnalyticsService()..onGetSummary = () async => AnalyticsSummary.fromJson(json())!;
  final controller = AnalyticsController(svc);
  addTearDown(controller.dispose);
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AnalyticsController>.value(
      value: controller,
      child: const MaterialApp(home: Scaffold(body: AnalyticsView())),
    ),
  );
  await tester.pumpAndSettle();
  return (svc, controller);
}

void main() {
  test('model: net figures, period, time zone and top-products period parse from the server', () {
    final s = AnalyticsSummary.fromJson(c4xJson())!;
    expect(s.periodFrom, '2026-10-05');
    expect(s.timezone, 'Australia/Melbourne');
    expect(s.topProductsFrom, '2026-09-29');
    final croissant = s.topProducts.firstWhere((p) => p.productVariationId == 5);
    expect(croissant.quantitySold, 5);
    expect(croissant.refundedQuantity, 4);
    expect(croissant.displayQuantity, 1);
    expect(croissant.displayRevenue, 100);
    final asha = s.staffPerformance.first;
    expect(asha.salesTotal, 500);
    expect(asha.refundedTotal, 100);
    expect(asha.displayTotal, 400);
  });

  test('model: an older server without net fields falls back to the gross figures', () {
    final s = AnalyticsSummary.fromJson(analyticsSummaryJson(
      topProducts: [
        {'product_variation_id': 7, 'product_name': 'Tea', 'quantity_sold': 2, 'revenue': 40},
      ],
      staffPerformance: [
        {'salesman_id': 'S9', 'fullname': 'Old', 'transaction_count': 1, 'sales_total': 40},
      ],
    ))!;
    expect(s.topProducts.single.displayQuantity, 2);
    expect(s.topProducts.single.displayRevenue, 40);
    expect(s.staffPerformance.single.displayTotal, 40);
    expect(s.timezone, isNull);
  });

  testWidgets('view: top products and staff show the server net, with gross/refunds noted', (tester) async {
    await pump(tester, c4xJson);
    expect(find.text('1 sold'), findsOneWidget, reason: 'Croissant net quantity');
    expect(find.text('100.00 · 4 refunded of 5'), findsOneWidget);
    expect(find.text('3 sold'), findsOneWidget);
    expect(find.text('600.00'), findsWidgets);
    expect(find.text('400.00'), findsOneWidget, reason: "Asha's net");
    expect(find.text('2 transactions · gross 500.00, refunds −100.00'), findsOneWidget);
    expect(find.text('1 transaction'), findsOneWidget, reason: 'no refund note when nothing was refunded');
  });

  testWidgets('range bar shows the store time zone; picking dates sends from/to and relabels; Today clears it', (tester) async {
    var json = c4xJson();
    final (svc, controller) = await pump(tester, () => json);
    expect(svc.lastFrom, isNull, reason: 'default is the store today');
    expect(tester.widget<Text>(find.byKey(const Key('analytics-range-label'))).data, 'Today · Australia/Melbourne');
    expect(find.text("Today's Net Sales"), findsOneWidget);
    expect(find.text('Top Selling Products (7 days)'), findsOneWidget);
    expect(find.byKey(const Key('analytics-range-today')), findsNothing);

    // Choose a range through the controller's picker path (the picker itself
    // is Flutter's; what matters is what the app sends and shows).
    json = c4xJson(from: '2026-10-01', to: '2026-10-03');
    await controller.setRange('2026-10-01', '2026-10-03');
    await tester.pumpAndSettle();
    expect(svc.lastFrom, '2026-10-01');
    expect(svc.lastTo, '2026-10-03');
    expect(tester.widget<Text>(find.byKey(const Key('analytics-range-label'))).data, '2026-10-01 – 2026-10-03 · Australia/Melbourne');
    expect(find.text('Net Sales'), findsOneWidget);
    expect(find.text('Top Selling Products (selected period)'), findsOneWidget);
    expect(find.text('Staff Performance (selected period)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('analytics-range-today')));
    await tester.pumpAndSettle();
    expect(svc.lastFrom, isNull);
    expect(svc.lastTo, isNull);
    expect(find.text("Today's Net Sales"), findsOneWidget);
  });

  testWidgets('the Dates button opens a date-range picker; confirming sends that range', (tester) async {
    final (svc, controller) = await pump(tester, c4xJson);
    await tester.tap(find.byKey(const Key('analytics-range-pick')));
    await tester.pumpAndSettle();
    expect(find.text('Select dates'), findsOneWidget);
    // Accept the picker's initial range (today .. today on this device).
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final now = DateTime.now();
    final today = '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    expect(controller.hasCustomRange, isTrue);
    expect(svc.lastFrom, today);
    expect(svc.lastTo, today);
  });

  testWidgets('a single-day range shows just that date', (tester) async {
    final (_, controller) = await pump(tester, c4xJson);
    await controller.setRange('2026-10-02', '2026-10-02');
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('analytics-range-label'))).data, '2026-10-02 · Australia/Melbourne');
  });
}
