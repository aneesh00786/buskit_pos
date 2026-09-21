import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

late FakeCartService service;
late CartController cart;

CartSale sale({
  int version = 2,
  String status = 'draft',
  List<Map<String, dynamic>>? items,
  double discount = 0,
}) {
  final lines =
      items ??
      [
        lineJson(
          id: 1,
          variationId: 42,
          quantity: 2,
          name: 'Tea',
          unitPrice: 5000,
          tax: 1200,
          taxIncluded: false,
          lineTotal: 11200,
        ),
        lineJson(
          id: 2,
          variationId: 43,
          quantity: 1,
          name: 'Salt',
          unitPrice: 3.5,
          tax: 0.18,
          taxIncluded: true,
          taxPercent: 5,
          lineTotal: 3.5,
        ),
      ];
  final j = saleJson(
    id: 7,
    version: version,
    status: status,
    items: lines,
    subtotal: 10003.5,
    tax: 1200.18,
    total: 11203.5,
  );
  (j['totals'] as Map)['discount_total'] = discount;
  return CartSale.fromJson(j)!;
}

/// Puts [initial] into the controller through the real add path.
Future<void> seed({CartSale? initial, String? label}) async {
  final s = initial ?? sale();
  service.onAdd = (_) async => s;
  service.onGet = (_) async => s;
  await cart.addItem(42, 2, label: label);
}

Future<void> pump(
  WidgetTester tester, {
  double width = 380,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: cart,
      child: MaterialApp(
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
  await tester.pump();
}

void main() {
  setUp(() {
    service = FakeCartService();
    cart = CartController(service);
  });
  tearDown(() => cart.dispose());

  group('states', () {
    testWidgets('empty cart: message, and no request is made', (tester) async {
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('The cart is empty'), findsOneWidget);
      expect(service.getCalls, 0);
    });

    testWidgets(
      'opening the cart reloads it from the server and shows a progress bar meanwhile',
      (tester) async {
        await seed();
        final gate = Completer<CartSale>();
        service.onGet = (_) => gate.future;
        await pump(tester);
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        gate.complete(
          sale(version: 3, items: [lineJson(id: 1, quantity: 6, name: 'Tea')]),
        );
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(service.getCalls, 1);
        expect(cart.sale!.version, 3);
      },
    );

    testWidgets(
      'a retryable load error shows a banner with Retry that reloads',
      (tester) async {
        await seed();
        service.onGet = (_) async =>
            throw apiError(500, message: 'internal /srv/x.js');
        await pump(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsOneWidget);
        expect(find.textContaining('/srv/x.js'), findsNothing);
        expect(
          find.text('Tea'),
          findsOneWidget,
          reason: 'the cart stays visible',
        );

        service.onGet = (_) async => sale(version: 4);
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsNothing);
        expect(cart.sale!.version, 4);
      },
    );

    testWidgets('a non-retryable load error has no Retry button', (
      tester,
    ) async {
      await seed();
      service.onGet = (_) async => throw apiError(
        403,
        message: 'This sale belongs to a different shift',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('different shift'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('a draft that became empty shows the empty state', (
      tester,
    ) async {
      await seed(initial: sale(items: []));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('The cart is empty'), findsOneWidget);
    });

    testWidgets(
      'a cart that is no longer open is read-only with a New cart action',
      (tester) async {
        await seed(initial: sale(status: 'completed'));
        await pump(tester);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('no longer open (completed)'),
          findsOneWidget,
        );
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.delete_outline).first,
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.text('New cart'));
        await tester.pumpAndSettle();
        expect(find.text('The cart is empty'), findsOneWidget);
      },
    );
  });

  group('display (server values only)', () {
    testWidgets(
      'name, variation label, quantity × price, tax, and line total are shown as received',
      (tester) async {
        await seed(label: '250g · pack');
        await pump(tester);
        await tester.pumpAndSettle();
        expect(find.text('Tea'), findsOneWidget);
        expect(find.text('250g · pack'), findsOneWidget);
        expect(find.text('2 × 5000.00'), findsOneWidget);
        expect(find.text('+ tax 1200.00 (12%)'), findsOneWidget);
        expect(find.text('11200.00'), findsWidgets);
        expect(find.text('incl. tax 0.18 (5%)'), findsOneWidget);
      },
    );

    testWidgets('subtotal, tax, discount and total come from the response', (
      tester,
    ) async {
      await seed(initial: sale(discount: 2.5));
      await pump(tester);
      await tester.pumpAndSettle();
      expect(find.text('10003.50'), findsOneWidget);
      expect(find.text('1200.18'), findsOneWidget);
      expect(find.text('Discount'), findsOneWidget);
      expect(find.text('2.50'), findsOneWidget);
      expect(find.text('11203.50'), findsOneWidget);
    });

    testWidgets(
      'an unavailable line says so and cannot be stepped, but can be removed',
      (tester) async {
        await seed(
          initial: sale(
            items: [
              lineJson(id: 1, name: 'Ghost', availability: 'unavailable'),
            ],
          ),
        );
        await pump(tester);
        await tester.pumpAndSettle();
        expect(find.text('No longer available'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.delete_outline),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets('lines are announced with an accessible label', (tester) async {
      await seed();
      await pump(tester);
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel(RegExp(r'Tea, quantity 2, line total 11200')),
        findsOneWidget,
      );
      expect(find.byTooltip('Remove Tea'), findsOneWidget);
    });
  });

  group('update quantity', () {
    testWidgets(
      '+ sends the line id, the new quantity and the current version',
      (tester) async {
        await seed();
        service.onUpdate = (c) async => sale(
          version: 3,
          items: [
            lineJson(id: 1, quantity: c.quantity, name: 'Tea'),
            lineJson(id: 2, name: 'Salt'),
          ],
        );
        await pump(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Increase quantity').first);
        await tester.pumpAndSettle();
        final c = service.updateCalls.single;
        expect(
          (c.saleId, c.itemId, c.quantity, c.expectedVersion),
          (7, 1, 3, 2),
        );
        expect(cart.sale!.version, 3);
        expect(
          find.text('3 × 10.00'),
          findsOneWidget,
          reason: 'the refreshed line from the server response',
        );
      },
    );

    testWidgets(
      '− decreases; it is disabled at quantity 1 (use Remove instead)',
      (tester) async {
        await seed();
        service.onUpdate = (c) async => sale(
          version: 3,
          items: [
            lineJson(id: 1, quantity: c.quantity, name: 'Tea'),
            lineJson(id: 2, name: 'Salt'),
          ],
        );
        await pump(tester);
        await tester.pumpAndSettle();
        final minus = find.widgetWithIcon(IconButton, Icons.remove);
        expect(
          tester.widget<IconButton>(minus.at(1)).onPressed,
          isNull,
          reason: 'Salt is at quantity 1',
        );
        await tester.tap(find.byTooltip('Decrease quantity').first);
        await tester.pumpAndSettle();
        expect(service.updateCalls.single.quantity, 1);
      },
    );

    testWidgets(
      'typing an exact quantity validates whole numbers 1–9999 locally, then sends it',
      (tester) async {
        await seed();
        service.onUpdate = (c) async => sale(
          version: 3,
          items: [
            lineJson(id: 1, quantity: c.quantity, name: 'Tea'),
            lineJson(id: 2, name: 'Salt'),
          ],
        );
        await pump(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.text('2'));
        await tester.pumpAndSettle();
        expect(find.text('Set quantity'), findsOneWidget);

        await tester.enterText(find.byType(TextField), '0');
        await tester.tap(find.text('Update'));
        await tester.pump();
        expect(
          find.textContaining('whole number from 1 to 9999'),
          findsOneWidget,
        );
        expect(service.updateCalls, isEmpty);

        await tester.enterText(find.byType(TextField), '10000');
        await tester.tap(find.text('Update'));
        await tester.pump();
        expect(
          find.textContaining('whole number from 1 to 9999'),
          findsOneWidget,
        );
        expect(service.updateCalls, isEmpty);

        await tester.enterText(find.byType(TextField), '7');
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(service.updateCalls.single.quantity, 7);
        expect(find.text('Set quantity'), findsNothing);
      },
    );

    testWidgets('decimal and non-numeric characters cannot be typed', (
      tester,
    ) async {
      await seed();
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '1.5abc');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '15',
      );
    });

    testWidgets('cancelling the quantity dialog sends nothing', (tester) async {
      await seed();
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.updateCalls, isEmpty);
    });
  });

  group('remove', () {
    testWidgets('asks for confirmation; Cancel sends nothing', (tester) async {
      await seed();
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove Tea'));
      await tester.pumpAndSettle();
      expect(find.text('Remove Tea from the cart?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(service.removeCalls, isEmpty);
      expect(find.text('Tea'), findsOneWidget);
    });

    testWidgets(
      'confirming sends the line id and current version and shows the refreshed cart',
      (tester) async {
        await seed();
        service.onRemove = (c) async =>
            sale(version: 3, items: [lineJson(id: 2, name: 'Salt')]);
        await pump(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Remove Tea'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        final c = service.removeCalls.single;
        expect((c.saleId, c.itemId, c.expectedVersion), (7, 1, 2));
        expect(find.text('Tea'), findsNothing);
        expect(find.text('Salt'), findsOneWidget);
      },
    );

    testWidgets(
      'an already-removed line: friendly message, cart refreshed, no retry',
      (tester) async {
        await seed();
        service.onRemove = (_) async =>
            throw apiError(404, message: 'Line item not found');
        await pump(tester);
        await tester.pumpAndSettle();
        // The line disappears only after the cart was opened (removed on another device).
        service.onGet = (_) async =>
            sale(version: 3, items: [lineJson(id: 2, name: 'Salt')]);
        await tester.tap(find.byTooltip('Remove Tea'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Remove'));
        await tester.pumpAndSettle();
        expect(find.text(CartController.itemGoneMessage), findsOneWidget);
        expect(service.removeCalls, hasLength(1));
        expect(find.text('Tea'), findsNothing);
      },
    );
  });

  group('in-flight and errors', () {
    testWidgets(
      'while a mutation runs: progress shown, every stepper/remove disabled, taps ignored',
      (tester) async {
        await seed();
        await pump(tester);
        await tester.pumpAndSettle();
        final gate = Completer<CartSale>();
        service.onUpdate = (_) => gate.future;
        await tester.tap(find.byTooltip('Increase quantity').first);
        await tester.pump();

        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        for (final icon in [Icons.add, Icons.remove, Icons.delete_outline]) {
          for (final b in tester.widgetList<IconButton>(
            find.widgetWithIcon(IconButton, icon),
          )) {
            expect(b.onPressed, isNull, reason: '$icon must be disabled');
          }
        }
        await tester.tap(
          find.byTooltip('Increase quantity').first,
          warnIfMissed: false,
        );
        await tester.pump();
        expect(service.updateCalls, hasLength(1));

        gate.complete(sale(version: 3));
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.add).first,
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'a version conflict shows the review message and the refreshed cart',
      (tester) async {
        await seed();
        service.onUpdate = (_) async => throw apiError(
          409,
          message: 'Sale has been modified since you last read it',
          data: {'current_version': 5},
        );
        service.onGet = (_) async => sale(
          version: 5,
          items: [lineJson(id: 1, quantity: 9, name: 'Tea')],
        );
        await pump(tester);
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Increase quantity').first);
        await tester.pumpAndSettle();
        expect(find.text(CartController.conflictMessage), findsOneWidget);
        expect(find.text('9 × 10.00'), findsOneWidget);
        expect(service.updateCalls, hasLength(1), reason: 'not retried');
        expect(cart.error!.currentVersion, 5);
      },
    );

    testWidgets('the banner can be dismissed', (tester) async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        422,
        message: 'quantity must be an integer between 1 and 9999',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase quantity').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('quantity must be'), findsOneWidget);
      await tester.tap(find.byTooltip('Dismiss'));
      await tester.pumpAndSettle();
      expect(find.textContaining('quantity must be'), findsNothing);
    });

    testWidgets('network and timeout errors are shown with friendly text', (
      tester,
    ) async {
      await seed();
      service.onUpdate = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase quantity').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);

      service.onUpdate = (_) async => throw const ApiException(
        kind: ApiErrorKind.timeout,
        message: 'The server took too long to respond. Please try again.',
      );
      await tester.tap(find.byTooltip('Increase quantity').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('took too long'), findsOneWidget);
    });

    testWidgets('a 500 never shows the server text', (tester) async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        500,
        message: 'ER_LOCK_DEADLOCK at posSaleService.js:250',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase quantity').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('ER_LOCK'), findsNothing);
      expect(find.textContaining('went wrong on the server'), findsOneWidget);
    });

    testWidgets('POS_WEIGHT_UNIT_NOT_SUPPORTED is explained clearly', (
      tester,
    ) async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        422,
        message: 'raw',
        code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Increase quantity').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('sold by weight'), findsOneWidget);
      expect(find.textContaining('POS_WEIGHT'), findsNothing);
    });

    testWidgets('add-to-cart failures are NOT repeated in the cart panel', (
      tester,
    ) async {
      await seed();
      service.onAdd = (_) async => throw apiError(
        422,
        message: 'boom',
        code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
      );
      await pump(tester);
      await tester.pumpAndSettle();
      await cart.addItem(6, 1);
      await tester.pumpAndSettle();
      expect(cart.error, isNotNull);
      expect(find.textContaining('sold by weight'), findsNothing);
    });
  });

  group('responsive layout', () {
    for (final size in const [
      Size(320, 568),
      Size(380, 800),
      Size(800, 1000),
      Size(1366, 768),
    ]) {
      testWidgets(
        'no overflow at ${size.width.toInt()}x${size.height.toInt()} with long names, errors and many lines',
        (tester) async {
          final items = [
            for (var i = 1; i <= 8; i++)
              lineJson(
                id: i,
                variationId: 40 + i,
                quantity: 12345 % 9999,
                name:
                    'A very long product name that should wrap onto several lines number $i',
                unitPrice: 123456.789,
                tax: 9999.999,
                lineTotal: 1234567.891,
              ),
          ];
          await seed(
            initial: sale(items: items, discount: 12.5),
            label: 'Extra large economy family size · carton of forty-eight',
          );
          service.onUpdate = (_) async =>
              throw apiError(409, data: {'current_version': 9});
          service.onGet = (_) async => sale(version: 9, items: items);
          await pump(tester, width: size.width, height: size.height);
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Increase quantity').first);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(CartController.conflictMessage), findsOneWidget);
        },
      );
    }

    testWidgets('touch targets: stepper and remove buttons are at least 48dp', (
      tester,
    ) async {
      await seed();
      await pump(tester);
      await tester.pumpAndSettle();
      for (final f in [
        find.byTooltip('Increase quantity').first,
        find.byTooltip('Decrease quantity').first,
        find.byTooltip('Remove Tea'),
      ]) {
        final s = tester.getSize(f);
        expect(s.width, greaterThanOrEqualTo(48));
        expect(s.height, greaterThanOrEqualTo(48));
      }
    });
  });
}
