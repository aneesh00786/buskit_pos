import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:buskit_pos/features/promotions/data/promotion_service.dart';
import 'package:buskit_pos/features/promotions/models/promotion.dart';
import 'package:buskit_pos/features/promotions/state/promotion_list_controller.dart';
import 'package:buskit_pos/features/promotions/ui/promotions_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fake_promotion_service.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

PromotionPage page(List<Map<String, dynamic>> rows) {
  final items = rows.map(Promotion.fromJson).whereType<Promotion>().toList();
  return PromotionPage(
    items: items,
    pagination: Pagination(
      page: 1,
      limit: 20,
      total: items.length,
      totalPages: 1,
    ),
  );
}

Future<PromotionListController> pumpPromotions(
  WidgetTester tester, {
  FakePromotionService? service,
  double width = 1000,
  double height = 700,
}) async {
  final svc = service ?? FakePromotionService();
  final controller = PromotionListController(svc);
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<PromotionListController>.value(
      value: controller,
      child: const MaterialApp(
        home: Scaffold(body: SizedBox.expand(child: PromotionsView())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('list states', () {
    testWidgets('loading, then the list', (tester) async {
      final svc = FakePromotionService();
      svc.onList = (_) async =>
          page([promotionJson(id: 1, title: 'Test 10% Off')]);
      await pumpPromotions(tester, service: svc);
      expect(find.text('Test 10% Off'), findsOneWidget);
      expect(find.text('10% off'), findsOneWidget);
    });

    testWidgets('an empty catalogue shows the empty state', (tester) async {
      await pumpPromotions(tester);
      expect(find.text('No promotions available'), findsOneWidget);
    });

    testWidgets('an error with retry, then a successful retry shows the list', (
      tester,
    ) async {
      final svc = FakePromotionService();
      svc.onList = (_) async => throw netDown;
      await pumpPromotions(tester, service: svc);
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      svc.onList = (_) async => page([promotionJson(title: 'Recovered')]);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Recovered'), findsOneWidget);
    });

    testWidgets('there is no create/edit/delete anywhere on this screen', (
      tester,
    ) async {
      final svc = FakePromotionService();
      svc.onList = (_) async => page([promotionJson()]);
      await pumpPromotions(tester, service: svc);
      for (final label in ['Create', 'Edit', 'Delete', 'New Promotion']) {
        expect(find.textContaining(label), findsNothing, reason: label);
      }
    });
  });

  group('detail', () {
    testWidgets(
      'tapping a promotion shows its discount, minimum and validity',
      (tester) async {
        final svc = FakePromotionService();
        svc.onList = (_) async => page([
          promotionJson(
            title: 'Test 10% Off',
            description: 'Sitewide savings',
            minOrderValue: 1000,
            maxDiscount: 500,
            endDate: '2026-09-30 00:00:00',
          ),
        ]);
        await pumpPromotions(tester, service: svc, width: 400);
        await tester.tap(find.text('Test 10% Off'));
        await tester.pumpAndSettle();
        expect(find.text('Promotion details'), findsOneWidget);
        expect(find.text('Sitewide savings'), findsOneWidget);
        expect(find.text('1000.00'), findsOneWidget);
        expect(find.text('500.00'), findsOneWidget);
      },
    );

    testWidgets('no expiry is shown plainly, not as a blank field', (
      tester,
    ) async {
      final svc = FakePromotionService();
      svc.onList = (_) async => page([promotionJson(title: 'Always On')]);
      await pumpPromotions(tester, service: svc, width: 400);
      await tester.tap(find.text('Always On'));
      await tester.pumpAndSettle();
      expect(find.text('No expiry'), findsOneWidget);
    });

    testWidgets('a phone-width back arrow returns to the list', (tester) async {
      final svc = FakePromotionService();
      svc.onList = (_) async => page([promotionJson(title: 'Test 10% Off')]);
      await pumpPromotions(tester, service: svc, width: 400);
      await tester.tap(find.text('Test 10% Off'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to promotions'));
      await tester.pumpAndSettle();
      expect(find.text('Promotions'), findsOneWidget);
      expect(find.text('Test 10% Off'), findsOneWidget);
    });

    testWidgets(
      'wide: list and detail side by side; selecting keeps the list visible',
      (tester) async {
        final svc = FakePromotionService();
        svc.onList = (_) async => page([promotionJson(title: 'Test 10% Off')]);
        await pumpPromotions(tester, service: svc, width: 900, height: 700);
        expect(find.text('Select a promotion'), findsOneWidget);
        await tester.tap(find.text('Test 10% Off'));
        await tester.pumpAndSettle();
        expect(
          find.text('Test 10% Off'),
          findsWidgets,
          reason: 'still visible in the list pane',
        );
        expect(find.byTooltip('Back to promotions'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
