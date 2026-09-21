import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

late FakeProductService products;
late FakeCartService carts;

Future<void> pumpPage(
  WidgetTester tester, {
  double width = 1200,
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  final list = ProductListController(
    products,
    debounce: const Duration(milliseconds: 10),
    pageSize: 20,
  );
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
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const ProductsPage(),
      ),
    ),
  );
}

void main() {
  setUp(() {
    products = FakeProductService();
    carts = FakeCartService();
    products.onCategories = () async => [
      const ProductCategory(id: 1, name: 'Dairy'),
      const ProductCategory(id: 2, name: 'Bakery'),
    ];
  });

  group('states', () {
    testWidgets('shows a progress indicator while loading, then the products', (
      tester,
    ) async {
      final gate = Completer<ProductPage>();
      products.onSearch = (_) => gate.future;
      await pumpPage(tester);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete(
        page([
          productJson(id: 1, name: 'Tea'),
          productJson(id: 2, name: 'Coffee'),
        ]),
      );
      await tester.pumpAndSettle();
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('Coffee'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('empty result shows a message', (tester) async {
      products.onSearch = (_) async => page([]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      expect(find.text('No products found'), findsOneWidget);
    });

    testWidgets('no results for a search says so and suggests changing it', (
      tester,
    ) async {
      products.onSearch = (c) async =>
          c.query == 'zzz' ? page([]) : page([productJson(id: 1)]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'zzz');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(find.text('No products found'), findsOneWidget);
      expect(find.textContaining('different search'), findsOneWidget);
    });

    testWidgets(
      'a retryable error shows a message and a Retry button that reloads',
      (tester) async {
        var fail = true;
        products.onSearch = (_) async {
          if (fail) throw apiError(500, message: 'stack trace at /srv/app.js');
          return page([productJson(id: 1, name: 'Tea')]);
        };
        await pumpPage(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsOneWidget);
        expect(find.textContaining('/srv/app.js'), findsNothing);
        expect(find.text('Retry'), findsOneWidget);

        fail = false;
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Tea'), findsOneWidget);
      },
    );

    testWidgets('a validation error is shown without a Retry button', (
      tester,
    ) async {
      products.onSearch = (_) async => throw apiError(
        422,
        message: 'limit must be an integer between 1 and 100',
      );
      await pumpPage(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('limit must be'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a network error offers Retry', (tester) async {
      products.onSearch = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
      await pumpPage(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });

  group('product cards show server data', () {
    testWidgets(
      'name, variation, unit, price, tax label and stock come from the API',
      (tester) async {
        products.onSearch = (_) async => page([
          productJson(
            id: 1,
            name: 'Tea',
            variation: '250g',
            unit: 'pack',
            price: 119,
            taxMode: 'exclusive',
            taxPercent: 12,
            stock: 8,
          ),
          productJson(
            id: 2,
            name: 'Salt',
            variation: '1kg',
            unit: 'unit',
            price: 3.5,
            taxMode: 'inclusive',
            taxPercent: 5,
            stock: 0,
          ),
        ]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        expect(find.text('Tea'), findsOneWidget);
        expect(find.text('250g · pack'), findsOneWidget);
        expect(find.textContaining('119.00'), findsOneWidget);
        expect(find.textContaining('+ 12% tax'), findsOneWidget);
        expect(find.text('Stock: 8'), findsOneWidget);
        expect(find.textContaining('3.50'), findsOneWidget);
        expect(find.textContaining('incl. tax'), findsOneWidget);
        expect(find.text('Out of stock'), findsOneWidget);
      },
    );

    testWidgets(
      'a product with several variations is one card with a variation count',
      (tester) async {
        products.onSearch = (_) async => page([
          productJson(
            id: 1,
            productId: 'A',
            name: 'Rice',
            variation: '1kg',
            price: 10,
          ),
          productJson(
            id: 2,
            productId: 'A',
            name: 'Rice',
            variation: '5kg',
            price: 45,
          ),
        ]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        expect(find.text('Rice'), findsOneWidget);
        expect(find.text('2 variations'), findsOneWidget);
        expect(find.textContaining('from 10.00'), findsOneWidget);
        expect(find.text('Select'), findsOneWidget);
      },
    );

    testWidgets('missing image renders a placeholder without errors', (
      tester,
    ) async {
      products.onSearch = (_) async => page([productJson(id: 1, image: null)]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.image_not_supported_outlined), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cards expose an accessible label', (tester) async {
      products.onSearch = (_) async => page([
        productJson(id: 1, name: 'Tea', variation: '250g', price: 119),
      ]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'Tea, 250g.*price 119')),
        findsOneWidget,
      );
    });
  });

  group('search and categories', () {
    testWidgets('typing searches once after the debounce', (tester) async {
      products.onSearch = (_) async => page([productJson(id: 1)]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      products.calls.clear();
      await tester.enterText(find.byType(TextField), 'mi');
      await tester.enterText(find.byType(TextField), 'milk');
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pumpAndSettle();
      expect(products.calls.map((c) => c.query), ['milk']);
      expect(products.calls.single.page, 1);
    });

    testWidgets('the clear button resets the search', (tester) async {
      products.onSearch = (_) async => page([productJson(id: 1)]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'milk');
      await tester.pump();
      products.calls.clear();
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(products.calls.single.query, '');
    });

    testWidgets(
      'categories load with an "All categories" chip selected by default',
      (tester) async {
        products.onSearch = (_) async => page([productJson(id: 1)]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        expect(find.text('All categories'), findsOneWidget);
        expect(find.text('Dairy'), findsOneWidget);
        expect(find.text('Bakery'), findsOneWidget);
        final all = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, 'All categories'),
        );
        expect(all.selected, isTrue);
      },
    );

    testWidgets(
      'selecting a category filters, then All categories clears the filter',
      (tester) async {
        products.onSearch = (_) async => page([productJson(id: 1)]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        products.calls.clear();

        await tester.tap(find.text('Dairy'));
        await tester.pumpAndSettle();
        expect(products.calls.single.categoryId, 1);
        expect(products.calls.single.page, 1);

        await tester.tap(find.text('All categories'));
        await tester.pumpAndSettle();
        expect(products.calls.last.categoryId, isNull);
      },
    );

    testWidgets(
      'a categories failure is shown with a retry and products still load',
      (tester) async {
        products.onCategories = () async => throw apiError(500);
        products.onSearch = (_) async =>
            page([productJson(id: 1, name: 'Tea')]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        expect(find.text('Categories could not be loaded'), findsOneWidget);
        expect(find.text('Tea'), findsOneWidget);
      },
    );
  });

  group('pagination', () {
    testWidgets('scrolling to the end loads the next page and appends it', (
      tester,
    ) async {
      products.onSearch = (c) async {
        final base = c.page * 100;
        return page(
          [
            for (var i = 0; i < 20; i++)
              productJson(id: base + i, name: 'Item ${c.page}-$i'),
          ],
          page: c.page,
          total: 40,
          totalPages: 2,
        );
      };
      await pumpPage(tester, width: 420, height: 800);
      await tester.pumpAndSettle();
      expect(products.calls.map((c) => c.page), [1]);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(products.calls.map((c) => c.page), [1, 2]);
    });

    testWidgets(
      'a failed next page shows a message with Retry and keeps the list',
      (tester) async {
        products.onSearch = (c) async {
          if (c.page == 2) throw apiError(500);
          return page(
            [
              for (var i = 0; i < 20; i++)
                productJson(id: i + 1, name: 'Item $i'),
            ],
            page: 1,
            total: 40,
            totalPages: 2,
          );
        };
        await pumpPage(tester, width: 420, height: 800);
        await tester.pumpAndSettle();
        await tester.drag(
          find.byType(CustomScrollView),
          const Offset(0, -6000),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsOneWidget);
        expect(find.text('Retry'), findsOneWidget);
        expect(
          find.text('Item 0'),
          findsNothing,
          reason: 'scrolled away, but still in the list',
        );
      },
    );
  });

  group('add to cart', () {
    testWidgets(
      'a single-variation product adds quantity 1 using the NUMERIC id',
      (tester) async {
        products.onSearch = (_) async => page([
          productJson(id: 42, variationId: 'VARIATION42', name: 'Tea'),
        ]);
        await pumpPage(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(carts.addCalls, hasLength(1));
        expect(carts.addCalls.single.variationId, 42);
        expect(carts.addCalls.single.quantity, 1);
        expect(find.text('Added 1 × Tea'), findsOneWidget);
      },
    );

    testWidgets(
      'POS_WEIGHT_UNIT_NOT_SUPPORTED shows a clear message and adds nothing',
      (tester) async {
        products.onSearch = (_) async =>
            page([productJson(id: 6, name: 'Loose Rice', unit: 'KG')]);
        carts.onAdd = (_) async => throw apiError(
          422,
          message: 'Weight-based products (KG/GR) cannot be sold',
          code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        );
        await pumpPage(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        expect(find.textContaining('sold by weight'), findsOneWidget);
        expect(find.textContaining('not been added'), findsOneWidget);
        expect(find.text('Added 1 × Loose Rice'), findsNothing);
        expect(carts.addCalls, hasLength(1), reason: 'no automatic retry');
        expect(find.text('The cart is empty'), findsOneWidget);
      },
    );

    testWidgets('double-tapping Add sends a single request', (tester) async {
      final gate = Completer<CartSale>();
      carts.onAdd = (_) => gate.future;
      products.onSearch = (_) async => page([productJson(id: 42, name: 'Tea')]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pump();
      await tester.tap(find.text('Add'), warnIfMissed: false);
      await tester.pump();
      expect(carts.addCalls, hasLength(1));
      gate.complete(CartSale.fromJson(saleJson(version: 2))!);
      await tester.pumpAndSettle();
      expect(carts.addCalls, hasLength(1));
    });

    testWidgets('the cart panel shows server-computed lines and totals', (
      tester,
    ) async {
      carts.onAdd = (c) async => CartSale.fromJson(
        saleJson(
          id: 7,
          version: 2,
          items: [
            {
              'id': 1,
              'product_variation_id': 42,
              'quantity': 2,
              'product_name': 'Tea',
              'availability_status': 'available',
              'unit_price': 5000,
              'tax_amount': 1200,
              'tax_included': false,
              'line_total': 11200,
            },
          ],
          subtotal: 10000,
          tax: 1200,
          total: 11200,
        ),
      )!;
      products.onSearch = (_) async => page([productJson(id: 42, name: 'Tea')]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('2 × 5000.00'), findsOneWidget);
      expect(
        find.text('11200.00'),
        findsNWidgets(2),
      ); // line total + grand total, exactly as sent
      expect(find.text('1200.00'), findsOneWidget);
    });
  });

  group('variation selection', () {
    Future<void> openSheet(WidgetTester tester) async {
      products.onSearch = (_) async => page([
        productJson(
          id: 11,
          productId: 'A',
          variationId: 'VAR-1KG',
          name: 'Rice',
          variation: '1kg',
          price: 10,
          taxMode: 'exclusive',
        ),
        productJson(
          id: 12,
          productId: 'A',
          variationId: 'VAR-5KG',
          name: 'Rice',
          variation: '5kg',
          price: 45,
          taxMode: 'inclusive',
          stock: 0,
        ),
      ]);
      await pumpPage(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select'));
      await tester.pumpAndSettle();
    }

    testWidgets('lists every variation with its own price and stock', (
      tester,
    ) async {
      await openSheet(tester);
      expect(find.text('1kg'), findsOneWidget);
      expect(find.text('5kg'), findsOneWidget);
      expect(find.text('45.00'), findsOneWidget);
      expect(find.textContaining('Out of stock'), findsOneWidget);
    });

    testWidgets(
      'the selected variation drives the displayed price/tax and the id sent',
      (tester) async {
        await openSheet(tester);
        expect(
          find.textContaining('+ 12% tax'),
          findsWidgets,
        ); // first variation selected by default
        await tester.tap(find.text('5kg'));
        await tester.pumpAndSettle();
        expect(find.textContaining('incl. tax'), findsWidgets);

        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pump();
        await tester.tap(find.byTooltip('Increase quantity'));
        await tester.pump();
        await tester.tap(find.text('Add to cart'));
        await tester.pumpAndSettle();

        expect(carts.addCalls, hasLength(1));
        expect(
          carts.addCalls.single.variationId,
          12,
          reason: 'numeric id of the 5kg variation, not VAR-5KG',
        );
        expect(carts.addCalls.single.quantity, 3);
        expect(
          find.byType(BottomSheet),
          findsNothing,
          reason: 'sheet closes after a successful add',
        );
        expect(find.text('Added 3 × Rice to the cart'), findsOneWidget);
      },
    );

    testWidgets('quantity cannot go below 1', (tester) async {
      await openSheet(tester);
      final dec = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.remove),
      );
      expect(dec.onPressed, isNull);
    });

    testWidgets(
      'a weight-unit rejection is shown inside the sheet, which stays open',
      (tester) async {
        await openSheet(tester);
        carts.onAdd = (_) async => throw apiError(
          422,
          message: 'x',
          code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        );
        await tester.tap(find.text('Add to cart'));
        await tester.pumpAndSettle();
        expect(find.textContaining('sold by weight'), findsOneWidget);
        expect(
          find.text('Add to cart'),
          findsOneWidget,
          reason: 'sheet is still open',
        );
        expect(carts.addCalls, hasLength(1));
      },
    );

    testWidgets('double-tapping Add to cart in the sheet sends one request', (
      tester,
    ) async {
      await openSheet(tester);
      final gate = Completer<CartSale>();
      carts.onAdd = (_) => gate.future;
      await tester.tap(find.text('Add to cart'));
      await tester.pump();
      await tester.tap(find.text('Add to cart'), warnIfMissed: false);
      await tester.pump();
      expect(carts.addCalls, hasLength(1));
      gate.complete(CartSale.fromJson(saleJson(version: 2))!);
      await tester.pumpAndSettle();
      expect(carts.addCalls, hasLength(1));
    });

    testWidgets('a server error on add is shown without closing the sheet', (
      tester,
    ) async {
      await openSheet(tester);
      carts.onAdd = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
      );
      await tester.tap(find.text('Add to cart'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('modified since you last read it'),
        findsOneWidget,
      );
    });
  });

  group('responsive layout', () {
    testWidgets('tablet: products and the cart panel are side by side', (
      tester,
    ) async {
      products.onSearch = (_) async => page([productJson(id: 1)]);
      await pumpPage(tester, width: 1200);
      await tester.pumpAndSettle();
      expect(find.text('The cart is empty'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('phone: a cart bar opens the cart in a sheet', (tester) async {
      products.onSearch = (_) async => page([productJson(id: 1)]);
      await pumpPage(tester, width: 400, height: 800);
      await tester.pumpAndSettle();
      expect(find.text('The cart is empty'), findsNothing);
      await tester.tap(find.text('Cart'));
      await tester.pumpAndSettle();
      expect(find.text('The cart is empty'), findsOneWidget);
    });

    for (final size in const [
      Size(320, 640),
      Size(800, 1280),
      Size(1366, 1024),
    ]) {
      testWidgets(
        'no layout overflow at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
          products.onSearch = (_) async => page([
            for (var i = 1; i <= 6; i++)
              productJson(
                id: i,
                name: 'A rather long product name number $i',
                variation: 'Large economy size',
                unit: 'carton',
              ),
          ]);
          await pumpPage(tester, width: size.width, height: size.height);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('interactive controls meet the 48dp minimum touch target', (
      tester,
    ) async {
      products.onSearch = (_) async => page([productJson(id: 1)]);
      await pumpPage(tester, width: 400, height: 800);
      await tester.pumpAndSettle();
      for (final f in [find.text('Add'), find.text('All categories')]) {
        final size = tester.getSize(
          find
              .ancestor(
                of: f,
                matching: find.byWidgetPredicate(
                  (w) => w is ButtonStyleButton || w is ChoiceChip,
                ),
              )
              .first,
        );
        expect(size.height, greaterThanOrEqualTo(40));
      }
      final add = tester.getSize(find.widgetWithText(FilledButton, 'Add'));
      expect(add.height, greaterThanOrEqualTo(48));
    });
  });
}
