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
var listChanged = 0;

CartSale draft({
  int version = 2,
  List<Map<String, dynamic>>? items,
  String status = 'draft',
}) => CartSale.fromJson(
  saleJson(
    id: 7,
    version: version,
    status: status,
    items: items ?? [lineJson(id: 1, quantity: 2, name: 'Tea')],
  ),
)!;

Future<void> seed({CartSale? sale}) async {
  final s = sale ?? draft();
  service.onAdd = (_) async => s;
  service.onGet = (_) async => s;
  await cart.addItem(42, 2);
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
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    service = FakeCartService();
    listChanged = 0;
    cart = CartController(service, onHeldSalesChanged: () => listChanged++);
  });
  tearDown(() => cart.dispose());

  testWidgets('Hold sale appears for a non-empty draft', (tester) async {
    await seed();
    await pump(tester);
    expect(find.text('Hold sale'), findsOneWidget);
  });

  testWidgets(
    'no Hold button for an empty cart, no cart, or a sale that is not a draft',
    (tester) async {
      await pump(tester);
      expect(find.text('Hold sale'), findsNothing);

      await seed(sale: draft(items: []));
      await tester.pumpAndSettle();
      expect(find.text('Hold sale'), findsNothing);

      cart.reset();
      await seed(sale: draft(status: 'held'));
      await pump(tester);
      expect(find.text('Hold sale'), findsNothing);
    },
  );

  testWidgets(
    'tapping Hold sends id + version, clears the cart and confirms after the server accepted',
    (tester) async {
      await seed();
      await pump(tester);
      await tester.tap(find.text('Hold sale'));
      await tester.pumpAndSettle();
      final c = service.holdCalls.single;
      expect((c.saleId, c.expectedVersion), (7, 2));
      expect(find.text('The cart is empty'), findsOneWidget);
      expect(find.textContaining('Sale #7 is on hold'), findsOneWidget);
      expect(listChanged, 1);
    },
  );

  testWidgets('no success message when the hold failed', (tester) async {
    await seed();
    service.onHold = (_) async => throw apiError(500);
    await pump(tester);
    await tester.tap(find.text('Hold sale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('is on hold'), findsNothing);
    expect(find.textContaining('went wrong on the server'), findsOneWidget);
    expect(find.text('Tea'), findsOneWidget, reason: 'the cart is kept');
  });

  testWidgets(
    'while holding: progress shown, Hold and every cart control disabled, second tap ignored',
    (tester) async {
      await seed();
      await pump(tester);
      final gate = Completer<CartSale>();
      service.onHold = (_) => gate.future;
      await tester.tap(find.text('Hold sale'));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Hold sale'),
            )
            .onPressed,
        isNull,
      );
      for (final icon in [Icons.add, Icons.remove, Icons.delete_outline]) {
        for (final b in tester.widgetList<IconButton>(
          find.widgetWithIcon(IconButton, icon),
        )) {
          expect(b.onPressed, isNull, reason: '$icon');
        }
      }
      await tester.tap(find.text('Hold sale'), warnIfMissed: false);
      await tester.pump();
      expect(service.holdCalls, hasLength(1));
      gate.complete(draft(version: 3, status: 'held'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'a version conflict shows the review message and the refreshed cart; the hold is not retried',
    (tester) async {
      await seed();
      service.onHold = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 6},
      );
      await pump(tester);
      service.onGet = (_) async =>
          draft(version: 6, items: [lineJson(id: 1, quantity: 9, name: 'Tea')]);
      await tester.tap(find.text('Hold sale'));
      await tester.pumpAndSettle();
      expect(find.text(CartController.conflictMessage), findsOneWidget);
      expect(find.text('9 × 10.00'), findsOneWidget);
      expect(service.holdCalls, hasLength(1));
      expect(cart.error!.currentVersion, 6);
    },
  );

  testWidgets('network error and 401 are shown with friendly text', (
    tester,
  ) async {
    await seed();
    service.onHold = (_) async => throw const ApiException(
      kind: ApiErrorKind.network,
      message: 'Cannot reach the server. Check your connection and try again.',
    );
    await pump(tester);
    await tester.tap(find.text('Hold sale'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Cannot reach the server'), findsOneWidget);
  });

  testWidgets(
    'a resume failure is not repeated in the cart panel (it belongs to the held-sales view)',
    (tester) async {
      await pump(tester);
      service.onResume = (_) async =>
          throw apiError(409, message: 'Sale is not held');
      await cart.resumeHeldSale(saleId: 9, expectedVersion: 1);
      await tester.pumpAndSettle();
      expect(cart.error, isNotNull);
      expect(find.textContaining('no longer on hold'), findsNothing);
    },
  );

  for (final size in const [
    Size(320, 568),
    Size(380, 800),
    Size(800, 1000),
    Size(1366, 768),
  ]) {
    testWidgets(
      'no overflow with the Hold button at ${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await seed(
          sale: draft(
            items: [
              for (var i = 1; i <= 8; i++)
                lineJson(
                  id: i,
                  name: 'A rather long product name that wraps over lines $i',
                  unitPrice: 123456.789,
                  lineTotal: 1234567.891,
                ),
            ],
          ),
        );
        await pump(tester, width: size.width, height: size.height);
        expect(tester.takeException(), isNull);
        expect(find.text('Hold sale'), findsOneWidget);
      },
    );
  }
}
