// Phase C4: gross / refunds / net and wallet tender, as served by the
// backend (Flutter never computes these totals itself).
import 'package:buskit_pos/features/analytics/models/analytics_summary.dart';
import 'package:buskit_pos/features/analytics/state/analytics_controller.dart';
import 'package:buskit_pos/features/analytics/ui/analytics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_analytics_service.dart';

Map<String, dynamic> c4Json() => {
  ...analyticsSummaryJson(
    transactionCount: 3,
    salesTotal: 600,
    paymentBreakdown: [
      {'method': 'cash', 'count': 2, 'amount': 350},
      {'method': 'card', 'count': 1, 'amount': 200},
      {'method': 'wallet', 'count': 1, 'amount': 50},
    ],
  ),
  'sales': {
    'completed_count': 3,
    'gross_sales': 600,
    'refunds_total': 150,
    'full_refunds_total': 100,
    'full_refund_count': 1,
    'partial_refunds_total': 50,
    'partial_refund_count': 1,
    'net_sales': 450,
    'fully_refunded_sales': 1,
    'partially_refunded_sales': 1,
  },
  'refund_payouts': [
    {'method': 'cash', 'amount': 120},
    {'method': 'wallet', 'amount': 30},
  ],
  'cash_movements': {'deposits': 70, 'deposit_count': 1, 'withdrawals': 30, 'withdrawal_count': 1},
};

Future<void> pump(WidgetTester tester, Map<String, dynamic> json) async {
  final svc = FakeAnalyticsService()..onGetSummary = () async => AnalyticsSummary.fromJson(json)!;
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
}

void main() {
  test('model: sales totals, refund payouts and cash movements parse from the server', () {
    final s = AnalyticsSummary.fromJson(c4Json())!;
    expect(s.sales.grossSales, 600);
    expect(s.sales.refundsTotal, 150);
    expect(s.sales.netSales, 450);
    expect(s.sales.refundCount, 2);
    expect(s.refundPayouts.map((r) => r.method), ['cash', 'wallet']);
    expect(s.cashMovements.deposits, 70);
    expect(s.paymentBreakdown.firstWhere((p) => p.method == 'wallet').amount, 50);
  });

  test('model: an older backend without `sales` falls back to gross with no refunds', () {
    final s = AnalyticsSummary.fromJson(analyticsSummaryJson(transactionCount: 2, salesTotal: 55))!;
    expect(s.sales.grossSales, 55);
    expect(s.sales.netSales, 55);
    expect(s.sales.refundsTotal, 0);
    expect(s.sales.completedCount, 2);
    expect(s.cashMovements.isEmpty, isTrue);
  });

  testWidgets('headline shows net, with gross and refunds distinctly', (tester) async {
    await pump(tester, c4Json());
    expect(find.text("Today's Net Sales"), findsOneWidget);
    expect(find.text('450.00'), findsOneWidget);
    expect(find.text('Gross 600.00 · Refunds -150.00'), findsOneWidget);
  });

  testWidgets('wallet is its own payment method', (tester) async {
    await pump(tester, c4Json());
    expect(find.text('Wallet'), findsNWidgets(2), reason: 'tender + refund payout');
    expect(find.text('Other'), findsNothing, reason: 'wallet is not lumped into Other');
  });

  testWidgets('refunds by method and the cash drawer are shown separately', (tester) async {
    await pump(tester, c4Json());
    expect(find.text('Refunds by Method'), findsOneWidget);
    expect(find.text('-120.00'), findsOneWidget);
    expect(find.text('-30.00'), findsWidgets);
    expect(find.text('Total refunds'), findsOneWidget);
    expect(find.text('Cash Drawer (not sales)'), findsOneWidget);
    expect(find.text('70.00'), findsOneWidget);
  });

  testWidgets('no refunds and no drawer movements: those sections stay hidden', (tester) async {
    await pump(tester, analyticsSummaryJson(transactionCount: 1, salesTotal: 100, paymentBreakdown: [
      {'method': 'cash', 'count': 1, 'amount': 100},
    ]));
    expect(find.text('Refunds by Method'), findsNothing);
    expect(find.text('Cash Drawer (not sales)'), findsNothing);
    expect(find.text('Gross 100.00 · Refunds 0.00'), findsOneWidget);
  });
}
