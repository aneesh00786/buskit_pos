import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

CartSale draft({
  int version = 2,
  String? customerId = 'CUST-1',
  Map<String, dynamic>? loyalty,
}) {
  final j = saleJson(
    id: 7,
    version: version,
    items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
    subtotal: 1000,
    tax: 100,
    total: 1100,
    customerId: customerId,
    loyalty: loyalty,
  );
  return CartSale.fromJson(j)!;
}

Future<CartController> pumpPanel(
  WidgetTester tester, {
  required FakeCartService service,
  double width = 380,
  double height = 800,
}) async {
  final cart = CartController(service);
  addTearDown(cart.dispose);
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<CartController>.value(
      value: cart,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: height,
            child: const CartPanel(),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return cart;
}

void main() {
  testWidgets(
    'no redemption/tier discount yet: shows a plain "Redeem Loyalty" button',
    (tester) async {
      final service = FakeCartService();
      service.onAdd = (_) async => draft(loyalty: loyaltySaleInfoJson());
      final cart = await pumpPanel(tester, service: service);
      await cart.addItem(1, 2);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextButton, 'Redeem Loyalty'), findsOneWidget);
    },
  );

  testWidgets('no loyalty at all (no customer / no program) shows nothing', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft(customerId: null, loyalty: null);
    final cart = await pumpPanel(tester, service: service);
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'Redeem Loyalty'), findsNothing);
    expect(find.textContaining('pts'), findsNothing);
  });

  testWidgets('a tier discount shows automatically, with no Remove button', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft(
      loyalty: loyaltySaleInfoJson(
        tier: {'id': 2, 'name': 'Gold'},
        tierDiscountAmount: 10,
      ),
    );
    final cart = await pumpPanel(tester, service: service);
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();
    expect(find.textContaining('Gold tier'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Remove'), findsNothing);
    // "Change" also appears (disabled) on the customer row above once a sale
    // exists — only the loyalty row's is enabled.
    expect(
      tester
          .widgetList<TextButton>(find.widgetWithText(TextButton, 'Change'))
          .where((b) => b.onPressed != null),
      hasLength(1),
    );
  });

  testWidgets('a points redemption shows with a Remove button that clears it', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft(
      loyalty: loyaltySaleInfoJson(
        pointsRedeemed: 500,
        pointsRedeemedValue: 50,
      ),
    );
    service.onRemoveLoyalty = (c) async =>
        draft(version: c.expectedVersion + 1, loyalty: loyaltySaleInfoJson());
    final cart = await pumpPanel(tester, service: service);
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();
    expect(find.textContaining('500 pts'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(service.removeLoyaltyCalls.single.saleId, 7);
    expect(find.textContaining('500 pts'), findsNothing);
  });

  testWidgets('an ineligible pending redemption is shown as a warning', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft(
      loyalty: loyaltySaleInfoJson(
        pointsRedeemed: 500,
        eligible: false,
        reasonCode: 'LOYALTY_INSUFFICIENT_POINTS',
        message: 'Insufficient points balance.',
      ),
    );
    final cart = await pumpPanel(tester, service: service);
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();
    expect(find.text('Insufficient points balance.'), findsOneWidget);
  });
}
