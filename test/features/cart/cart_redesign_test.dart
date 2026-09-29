import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/core/theme/pos_tokens.dart';
import 'package:buskit_pos/core/ui/product_image.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

CartSale draft({
  int version = 2,
  List<Map<String, dynamic>>? items,
  double discount = 0,
  String status = 'draft',
}) {
  final j = saleJson(
    id: 7,
    version: version,
    status: status,
    items:
        items ??
        [
          lineJson(id: 1, quantity: 2, name: 'Tea'),
          lineJson(id: 2, variationId: 43, name: 'Salt'),
          lineJson(id: 3, variationId: 44, name: 'Rice'),
        ],
    subtotal: 30,
    tax: 3.6,
    total: 33.6,
  );
  (j['totals'] as Map)['discount_total'] = discount;
  return CartSale.fromJson(j)!;
}

late FakeCartService service;
late CartController cart;

/// A fake server that removes the requested line and bumps the version.
void serverRemovesLines(List<int> ids) {
  var version = 2;
  final remaining = List.of(ids);
  service.onAdd = (_) async => draft(
    version: version,
    items: [for (final id in remaining) lineJson(id: id, name: 'Item $id')],
  );
  service.onGet = (_) async => draft(
    version: version,
    items: [for (final id in remaining) lineJson(id: id, name: 'Item $id')],
  );
  service.onRemove = (c) async {
    remaining.remove(c.itemId);
    version = c.expectedVersion + 1;
    return draft(
      version: version,
      items: [for (final id in remaining) lineJson(id: id, name: 'Item $id')],
    );
  };
}

Future<void> pumpPanel(
  WidgetTester tester, {
  double width = 380,
  double height = 800,
  ThemeData? theme,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: cart,
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
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
}

void main() {
  setUp(() {
    service = FakeCartService();
    cart = CartController(service);
  });
  tearDown(() => cart.dispose());

  group('clearAll (controller)', () {
    test('removes every line with the version chained from each response, then leaves an open, empty draft', () async {
      serverRemovesLines([1, 2, 3]);
      await cart.addItem(1, 1);
      expect(await cart.clearAll(), isTrue);
      expect(
        service.removeCalls.map((c) => (c.saleId, c.itemId, c.expectedVersion)),
        [(7, 1, 2), (7, 2, 3), (7, 3, 4)],
      );
      expect(cart.sale!.items, isEmpty);
      expect(
        cart.sale!.isDraft,
        isTrue,
        reason: 'the sale is left open, not canceled',
      );
      expect(cart.sale!.version, 5);
      expect(cart.error, isNull);
      expect(cart.isMutating, isFalse);
    });

    test(
      'nothing to clear: no request (empty cart, no cart, or not a draft)',
      () async {
        expect(await cart.clearAll(), isFalse);
        service.onAdd = (_) async => draft(items: []);
        await cart.addItem(1, 1);
        expect(await cart.clearAll(), isFalse);
        cart.reset();
        service.onAdd = (_) async => draft(status: 'held');
        await cart.addItem(1, 1);
        expect(await cart.clearAll(), isFalse);
        expect(service.removeCalls, isEmpty);
      },
    );

    test('double-tapping sends each removal once', () async {
      serverRemovesLines([1, 2]);
      await cart.addItem(1, 1);
      final a = cart.clearAll();
      final b = cart.clearAll();
      expect(await Future.wait([a, b]), [true, false]);
      expect(service.removeCalls, hasLength(2));
    });

    test('every other cart action is ignored while clearing', () async {
      serverRemovesLines([1, 2]);
      await cart.addItem(1, 1);
      final gate = Completer<CartSale>();
      service.onRemove = (_) => gate.future;
      final a = cart.clearAll();
      expect(await cart.addItem(9, 1), isFalse);
      expect(await cart.updateQuantity(1, 5), isFalse);
      expect(await cart.holdCurrent(), isFalse);
      gate.complete(draft(version: 3, items: []));
      await a;
      expect(service.updateCalls, isEmpty);
      expect(service.holdCalls, isEmpty);
    });

    test('stops at the first failure: earlier removals stay removed, later lines are untouched, no retry', () async {
      serverRemovesLines([1, 2, 3]);
      await cart.addItem(1, 1);
      var n = 0;
      final removeOk = service.onRemove;
      service.onRemove = (c) async {
        if (++n == 2) {
          throw const ApiException(
            kind: ApiErrorKind.network,
            message:
                'Cannot reach the server. Check your connection and try again.',
          );
        }
        return removeOk(c);
      };
      expect(await cart.clearAll(), isFalse);
      expect(
        service.removeCalls,
        hasLength(2),
        reason: 'stopped after the failing call; nothing retried',
      );
      expect(cart.sale!.items.map((l) => l.id), [2, 3]);
      expect(cart.error!.isRetryable, isTrue);
      expect(cart.errorOperation, CartOperation.remove);
      expect(cart.isMutating, isFalse);
    });

    test('a version conflict mid-way refreshes the cart, keeps current_version, and is not retried', () async {
      serverRemovesLines([1, 2, 3]);
      await cart.addItem(1, 1);
      var n = 0;
      final removeOk = service.onRemove;
      service.onRemove = (c) async {
        if (++n == 2) {
          throw apiError(
            409,
            message: 'Sale has been modified since you last read it',
            data: {'current_version': 9},
          );
        }
        return removeOk(c);
      };
      service.onGet = (id) async => draft(
        version: 9,
        items: [
          lineJson(id: 2, name: 'Item 2'),
          lineJson(id: 3, name: 'Item 3'),
          lineJson(id: 4, name: 'Added elsewhere'),
        ],
      );
      expect(await cart.clearAll(), isFalse);
      expect(service.removeCalls, hasLength(2));
      expect(service.getCalls, 1);
      expect(cart.sale!.version, 9);
      expect(cart.sale!.items.map((l) => l.id), [
        2,
        3,
        4,
      ], reason: 'the cashier reviews what the server now has');
      expect(cart.error!.currentVersion, 9);
      expect(cart.error!.message, CartController.conflictMessage);
    });

    test('a 401 signs the session out once and stops', () async {
      var out = 0;
      cart.dispose();
      cart = CartController(service, onUnauthorized: () => out++);
      serverRemovesLines([1, 2]);
      await cart.addItem(1, 1);
      service.onRemove = (_) async => throw apiError(401);
      await cart.clearAll();
      expect(out, 1);
      expect(service.removeCalls, hasLength(1));
    });

    test('a line that was already removed elsewhere (404) refreshes instead of retrying', () async {
      serverRemovesLines([1, 2]);
      await cart.addItem(1, 1);
      service.onRemove = (_) async =>
          throw apiError(404, message: 'Line item not found');
      service.onGet = (id) async =>
          draft(version: 4, items: [lineJson(id: 2, name: 'Item 2')]);
      await cart.clearAll();
      expect(service.removeCalls, hasLength(1));
      expect(cart.error!.message, CartController.itemGoneMessage);
      expect(cart.sale!.items.map((l) => l.id), [2]);
    });
  });

  group('Current Sale panel', () {
    Future<void> seed({CartSale? sale, String? imageUrl}) async {
      final s = sale ?? draft();
      service.onAdd = (_) async => s;
      service.onGet = (_) async => s;
      await cart.addItem(42, 2, label: '250g · pack', imageUrl: imageUrl);
    }

    testWidgets(
      'header, item-count chip, customer placeholder, totals and Hold + Pay',
      (tester) async {
        await seed();
        await pumpPanel(tester);
        expect(find.text('Current Sale'), findsOneWidget);
        expect(find.text('4 items'), findsOneWidget, reason: '2 + 1 + 1 units');
        expect(find.text('Guest checkout'), findsOneWidget);
        expect(find.text('Subtotal'), findsOneWidget);
        expect(find.text('Tax'), findsOneWidget);
        expect(find.text('Total'), findsOneWidget);
        expect(find.text('30.00'), findsOneWidget);
        expect(find.text('3.60'), findsOneWidget);
        expect(find.text('Hold sale'), findsOneWidget);
        expect(find.text('Pay'), findsOneWidget);
      },
    );

    testWidgets('a single unit reads "1 item"', (tester) async {
      await seed(sale: draft(items: [lineJson(id: 1, quantity: 1)]));
      await pumpPanel(tester);
      expect(find.text('1 item'), findsOneWidget);
    });

    testWidgets(
      'once the sale exists the customer is read-only and says how to change it',
      (tester) async {
        await seed();
        await pumpPanel(tester);
        final change = tester.widget<TextButton>(
          find.widgetWithText(TextButton, 'Change'),
        );
        expect(change.onPressed, isNull);
        expect(
          find.byTooltip(
            'The customer is set when the sale starts. Void the sale to change it.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets('Pay is enabled for an open draft with items and green', (
      tester,
    ) async {
      await seed();
      await pumpPanel(tester);
      final pay = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Pay'),
      );
      expect(pay.onPressed, isNotNull);
      expect(pay.style!.backgroundColor!.resolve({}), PosTokens.light.success);
    });

    testWidgets(
      'lines carry a thumbnail placeholder; a remembered image URL is used',
      (tester) async {
        await seed(imageUrl: 'https://img.invalid/tea.png');
        await pumpPanel(tester);
        expect(find.byType(ProductImage), findsNWidgets(3));
        expect(cart.imageFor(42), 'https://img.invalid/tea.png');
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'the server discount total is shown as sent; no placeholder is invented',
      (tester) async {
        await seed(sale: draft(discount: 2.5));
        await pumpPanel(tester);
        expect(find.text('Discount'), findsOneWidget);
        expect(find.text('-2.50'), findsOneWidget);
      },
    );

    testWidgets('empty cart: empty state, no Hold/Pay/Clear', (tester) async {
      await pumpPanel(tester);
      expect(find.text('The cart is empty'), findsOneWidget);
      expect(find.text('Hold sale'), findsNothing);
      expect(find.text('Pay'), findsNothing);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Clear all'))
            .onPressed,
        isNull,
      );
    });

    testWidgets(
      'short panels keep a compact customer row (it must stay choosable) and the item list',
      (tester) async {
        await seed();
        await pumpPanel(tester, height: 560);
        expect(find.text('Guest checkout'), findsOneWidget);
        expect(find.text('Tea'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders in dark mode', (tester) async {
      await seed();
      await pumpPanel(tester, theme: AppTheme.dark());
      expect(tester.takeException(), isNull);
      expect(find.text('Current Sale'), findsOneWidget);
    });
  });

  group('Clear all (panel)', () {
    Future<void> seedServer() async {
      serverRemovesLines([1, 2, 3]);
      await cart.addItem(1, 1);
    }

    testWidgets(
      'asks for confirmation; Cancel sends nothing and keeps every line',
      (tester) async {
        await seedServer();
        await pumpPanel(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
        await tester.pumpAndSettle();
        expect(find.text('Clear the cart?'), findsOneWidget);
        expect(find.textContaining('Remove all 3 items'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(service.removeCalls, isEmpty);
        expect(cart.sale!.items, hasLength(3));
      },
    );

    testWidgets(
      'confirming removes every line through the existing endpoint, in order, and shows the empty cart',
      (tester) async {
        await seedServer();
        await pumpPanel(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove all'));
        await tester.pumpAndSettle();
        expect(service.removeCalls.map((c) => c.itemId), [1, 2, 3]);
        expect(service.removeCalls.map((c) => c.expectedVersion), [2, 3, 4]);
        expect(find.text('The cart is empty'), findsOneWidget);
      },
    );

    testWidgets(
      'a failure part-way shows the error and what is left; Clear all is available again',
      (tester) async {
        await seedServer();
        var n = 0;
        final ok = service.onRemove;
        service.onRemove = (c) async {
          if (++n == 2) throw apiError(500);
          return ok(c);
        };
        await pumpPanel(tester);
        await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove all'));
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsOneWidget);
        expect(find.text('Item 1'), findsNothing);
        expect(find.text('Item 2'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Clear all'))
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('a conflict shows the review message and the refreshed cart', (
      tester,
    ) async {
      await seedServer();
      service.onRemove = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 9},
      );
      await pumpPanel(tester);
      service.onGet = (_) async => draft(
        version: 9,
        items: [
          lineJson(id: 1, name: 'Item 1'),
          lineJson(id: 8, name: 'Added elsewhere'),
        ],
      );
      await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove all'));
      await tester.pumpAndSettle();
      expect(find.text(CartController.conflictMessage), findsOneWidget);
      expect(find.text('Added elsewhere'), findsOneWidget);
      expect(service.removeCalls, hasLength(1));
    });

    testWidgets(
      'while clearing, progress is shown and every control is disabled',
      (tester) async {
        await seedServer();
        await pumpPanel(tester);
        final gate = Completer<CartSale>();
        service.onRemove = (_) => gate.future;
        await tester.tap(find.widgetWithText(TextButton, 'Clear all'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove all'));
        await tester.pump();
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Clear all'))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Hold sale'),
              )
              .onPressed,
          isNull,
        );
        gate.complete(draft(version: 3, items: []));
        await tester.pumpAndSettle();
      },
    );
  });

  group('Hold on the page (compact)', () {
    testWidgets(
      'the cart sheet opened from the bottom bar holds the sale and the bar resets',
      (tester) async {
        final h = PageHarness();
        h.carts.onAdd = (_) async => CartSaleFactory.sale(
          items: [lineJson(id: 1, quantity: 2, lineTotal: 21.2)],
          total: 21.2,
        );
        await pumpProductsPage(tester, h, width: 400, height: 800);
        await tester.tap(find.text('Add'));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('Cart ·'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Hold sale'));
        await tester.pumpAndSettle();
        final c = h.carts.holdCalls.single;
        expect((c.saleId, c.expectedVersion), (7, 2));
        expect(find.textContaining('is on hold'), findsOneWidget);
        expect(h.cart.sale, isNull);
      },
    );
  });
}
