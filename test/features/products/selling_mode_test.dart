// Selling-mode phase: the server sends each product's POS selling mode
// (PIECE | WEIGHT | REVIEW; missing = PIECE). Only PIECE can be added. The
// unit label ("100 Grm", "KG") never blocks anything — a Grm/ML/KG labelled
// product with no configuration is an ordinary piece.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

late FakeProductService products;
late FakeCartService carts;

Future<void> pumpPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  final list = ProductListController(products, debounce: const Duration(milliseconds: 10), pageSize: 20);
  final cart = CartController(carts);
  addTearDown(list.dispose);
  addTearDown(cart.dispose);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: session),
        ChangeNotifierProvider.value(value: list),
        ChangeNotifierProvider.value(value: cart),
      ],
      child: MaterialApp(theme: ThemeData(useMaterial3: true), home: const ProductsPage()),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, dynamic> withMode(Map<String, dynamic> json, String? mode) => {
  ...json,
  'selling_mode': ?mode,
};

void main() {
  setUp(() {
    products = FakeProductService();
    carts = FakeCartService();
  });

  group('model', () {
    test('missing selling_mode means PIECE (older servers); PIECE is sellable', () {
      final p = ProductItem.fromJson(productJson(id: 1, name: 'Soap', unit: 'Grm'))!;
      expect(p.sellingMode, 'PIECE');
      expect(p.isPosSellable, isTrue);
      expect(p.notSellableMessage, isNull);
      expect(p.unitType, 'Grm', reason: 'the label is kept, only descriptive');
    });

    test('WEIGHT and REVIEW are not sellable, each with its own message; values are case-normalised', () {
      final w = ProductItem.fromJson(withMode(productJson(id: 2, name: 'Apples', unit: 'KG'), 'weight'))!;
      expect(w.sellingMode, 'WEIGHT');
      expect(w.isPosSellable, isFalse);
      expect(w.notSellableMessage, 'This product is sold by weight, which the POS does not support yet.');
      final r = ProductItem.fromJson(withMode(productJson(id: 3, name: 'Badam', unit: 'Grm'), 'REVIEW'))!;
      expect(r.isPosSellable, isFalse);
      expect(r.notSellableMessage, 'This product is not configured for POS sale.');
    });
  });

  test('the server REVIEW code has its own message', () {
    final e = const ApiException(kind: ApiErrorKind.validation, statusCode: 422, message: 'x', errorCode: 'POS_PRODUCT_NOT_CONFIGURED_FOR_SALE');
    expect(describeApiError(e), 'This product is not configured for POS sale. It has not been added to the cart.');
  });

  testWidgets('a Grm-labelled product with no configuration is added as an ordinary piece', (tester) async {
    products.onSearch = (_) async => page([productJson(id: 7, name: 'Dove Bar', unit: 'Grm')]);
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(carts.addCalls, hasLength(1));
    expect(carts.addCalls.single.variationId, 7);
    expect(carts.addCalls.single.quantity, 1);
    expect(find.text('Added 1 × Dove Bar'), findsOneWidget);
  });

  testWidgets('tapping a REVIEW product shows the message and sends nothing', (tester) async {
    products.onSearch = (_) async => page([withMode(productJson(id: 8, name: 'Badam', unit: 'Grm'), 'REVIEW')]);
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('This product is not configured for POS sale.'), findsOneWidget);
    expect(carts.addCalls, isEmpty);
  });

  testWidgets('tapping a WEIGHT product shows the weight message and is never added as a piece', (tester) async {
    products.onSearch = (_) async => page([withMode(productJson(id: 9, name: 'Apples', unit: 'KG'), 'WEIGHT')]);
    await pumpPage(tester);
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(find.text('This product is sold by weight, which the POS does not support yet.'), findsOneWidget);
    expect(carts.addCalls, isEmpty);
  });

  testWidgets('variation sheet: a non-PIECE variant disables Add with its reason; a PIECE variant can be added', (tester) async {
    products.onSearch = (_) async => page([
      withMode(productJson(id: 21, productId: 'N', variationId: 'V-LOOSE', name: 'Nuts', variation: 'Loose', price: 10), 'REVIEW'),
      productJson(id: 22, productId: 'N', variationId: 'V-PACK', name: 'Nuts', variation: '100g pack', price: 12),
    ]);
    await pumpPage(tester);
    await tester.tap(find.text('Select'));
    await tester.pumpAndSettle();
    // First (REVIEW) variant is selected by default.
    expect(find.byKey(const Key('variation-not-sellable')), findsOneWidget);
    final addButton = find.widgetWithText(FilledButton, 'Add to cart');
    expect(tester.widget<FilledButton>(addButton).onPressed, isNull);

    await tester.tap(find.text('100g pack'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('variation-not-sellable')), findsNothing);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(carts.addCalls.single.variationId, 22);
  });
}
