import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

CartSale draft({
  int version = 2,
  double discount = 0,
  Map<String, dynamic>? promotion,
}) {
  final j = saleJson(
    id: 7,
    version: version,
    items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
    subtotal: 1000,
    tax: (1000 - discount) * 0.1,
    discount: discount,
    total: (1000 - discount) * 1.1,
    promotion: promotion,
  );
  return CartSale.fromJson(j)!;
}

/// A [PosApiClient] whose `GET /sales/:id/promotions` always returns
/// [eligible] — used by the "Add/Change Promotion" picker sheet.
PosApiClient eligiblePromotionsClient(List<Map<String, dynamic>> eligible) =>
    PosApiClient(
      baseUrl: 'http://test',
      httpClient: MockClient((r) async {
        if (r.method == 'GET' && r.url.path.endsWith('/promotions')) {
          return http.Response(
            jsonEncode({
              'status': true,
              'data': {'items': eligible},
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({'status': false, 'message': 'no route'}),
          404,
        );
      }),
    );

Future<CartController> pumpPanel(
  WidgetTester tester, {
  required FakeCartService service,
  required PosApiClient client,
  double width = 380,
  double height = 800,
}) async {
  final cart = CartController(service);
  addTearDown(cart.dispose);
  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  addTearDown(session.dispose);
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<CartController>.value(value: cart),
        ChangeNotifierProvider<SessionController>.value(value: session),
        Provider<PosApiClient>.value(value: client),
      ],
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
  testWidgets('Add Promotion opens the picker; tapping one applies it', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft();
    service.onGet = (_) async => draft();
    service.onApplyPromotion = (c) async => draft(
      version: c.expectedVersion + 1,
      discount: 100,
      promotion: appliedPromotionJson(
        title: 'Test 10% Off',
        discountAmount: 100,
      ),
    );
    final client = eligiblePromotionsClient([
      appliedPromotionJson(title: 'Test 10% Off', discountAmount: 100),
    ]);
    final cart = await pumpPanel(tester, service: service, client: client);
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add Promotion'));
    await tester.pumpAndSettle();
    expect(find.text('Eligible Promotions'), findsOneWidget);
    expect(find.text('Test 10% Off'), findsOneWidget);
    expect(find.textContaining('Saves'), findsOneWidget);

    await tester.tap(find.text('Test 10% Off'));
    await tester.pumpAndSettle();

    expect(
      find.text('Eligible Promotions'),
      findsNothing,
      reason: 'sheet closed',
    );
    expect(service.applyPromotionCalls.single.saleId, 7);
    expect(find.text('Discount'), findsOneWidget);
    expect(find.text('-100.00'), findsOneWidget);
  });

  testWidgets(
    'an ineligible applied promotion is shown as a warning with Change/Remove',
    (tester) async {
      final service = FakeCartService();
      service.onAdd = (_) async => draft(
        promotion: appliedPromotionJson(
          title: 'Test 10% Off',
          eligible: false,
          reasonCode: 'PROMOTION_NO_ELIGIBLE_ITEMS',
          message: 'No items in this sale are eligible for this promotion.',
          discountAmount: 0,
        ),
      );
      final cart = await pumpPanel(
        tester,
        service: service,
        client: eligiblePromotionsClient(const []),
      );
      await cart.addItem(1, 2);
      await tester.pumpAndSettle();

      expect(find.text('Test 10% Off'), findsOneWidget);
      expect(
        find.text('No items in this sale are eligible for this promotion.'),
        findsOneWidget,
      );
      // "Change" also appears on the customer row above — the promotion one is
      // the enabled TextButton (the customer row's is disabled once a sale
      // exists), and the only "Remove" in the panel.
      expect(
        tester
            .widgetList<TextButton>(find.widgetWithText(TextButton, 'Change'))
            .where((b) => b.onPressed != null),
        hasLength(1),
      );
      expect(find.widgetWithText(TextButton, 'Remove'), findsOneWidget);
      expect(
        find.text('Discount'),
        findsNothing,
        reason: 'not eligible — nothing actually discounted',
      );
    },
  );

  testWidgets('Remove clears the promotion', (tester) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft(
      discount: 100,
      promotion: appliedPromotionJson(
        title: 'Test 10% Off',
        discountAmount: 100,
      ),
    );
    service.onRemovePromotion = (c) async =>
        draft(version: c.expectedVersion + 1);
    final cart = await pumpPanel(
      tester,
      service: service,
      client: eligiblePromotionsClient(const []),
    );
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();
    expect(find.text('Test 10% Off'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(service.removePromotionCalls.single.saleId, 7);
    expect(find.text('Test 10% Off'), findsNothing);
    expect(find.widgetWithText(TextButton, 'Add Promotion'), findsOneWidget);
  });

  testWidgets('an empty eligible list explains there is nothing to apply', (
    tester,
  ) async {
    final service = FakeCartService();
    service.onAdd = (_) async => draft();
    final cart = await pumpPanel(
      tester,
      service: service,
      client: eligiblePromotionsClient(const []),
    );
    await cart.addItem(1, 2);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Add Promotion'));
    await tester.pumpAndSettle();
    expect(
      find.text('No promotions are eligible for this sale right now.'),
      findsOneWidget,
    );
  });
}
