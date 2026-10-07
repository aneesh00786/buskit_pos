// Phase 14E-A — keyboard shortcuts on the sales screen: F2 search, F4 pay
// (only when the Pay button would), F8 new sale (the existing "Clear the
// cart?" confirmation when there are items). Escape is Flutter's: it closes
// dismissible dialogs; the payment screen stays open. Scanner input is
// unaffected.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import '../barcode/barcode_test.dart' show item, scan;
import '../checkout/pay_modal_test.dart' show pumpWithCart;

TextField searchField(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('product-search')));

bool payOpen() =>
    find.widgetWithText(FilledButton, 'Complete Sale').evaluate().isNotEmpty;

Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('F2 focuses the product search', (tester) async {
    final h = PageHarness();
    await pumpProductsPage(tester, h);
    expect(searchField(tester).focusNode!.hasFocus, isFalse);
    await press(tester, LogicalKeyboardKey.f2);
    expect(searchField(tester).focusNode!.hasFocus, isTrue);
    // Typing goes into the field as normal; letters fire no shortcut.
    await tester.enterText(find.byKey(const Key('product-search')), 'tea f');
    await tester.pump();
    expect(searchField(tester).controller!.text, 'tea f');
    expect(payOpen(), isFalse);
    // Let the search debounce run out.
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  });

  testWidgets('F4 does nothing on an empty cart', (tester) async {
    final h = PageHarness();
    await pumpProductsPage(tester, h);
    await press(tester, LogicalKeyboardKey.f4);
    expect(payOpen(), isFalse);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'F4 opens the existing payment screen when the cart has items (also from the search field); Escape does not dismiss payment',
    (tester) async {
      final h = await pumpWithCart(tester);
      await press(tester, LogicalKeyboardKey.f2); // typing in search
      await press(tester, LogicalKeyboardKey.f4);
      expect(payOpen(), isTrue);
      await press(tester, LogicalKeyboardKey.escape);
      expect(
        payOpen(),
        isTrue,
        reason: 'payment is deliberately not dismissible',
      );
      expect(h.carts.completeCalls, isEmpty, reason: 'F4 never pays by itself');
    },
  );

  testWidgets(
    'F8 with items asks the existing confirmation; Escape cancels it (nothing removed); confirming clears the cart',
    (tester) async {
      final h = await pumpWithCart(tester);
      await press(tester, LogicalKeyboardKey.f8);
      expect(find.text('Clear the cart?'), findsOneWidget);
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('Clear the cart?'), findsNothing);
      expect(h.carts.removeCalls, isEmpty);

      await press(tester, LogicalKeyboardKey.f8);
      await tester.tap(find.text('Remove all'));
      await tester.pumpAndSettle();
      expect(h.carts.removeCalls, isNotEmpty);
    },
  );

  testWidgets('F8 on an empty cart does nothing (no dialog, no request)', (
    tester,
  ) async {
    final h = PageHarness();
    await pumpProductsPage(tester, h);
    await press(tester, LogicalKeyboardKey.f8);
    expect(find.text('Clear the cart?'), findsNothing);
    expect(h.carts.removeCalls, isEmpty);
    expect(h.carts.cancelCalls, isEmpty);
  });

  testWidgets(
    'shortcuts do not fire inside a dialog (F4 / F8 while the clear confirmation is open)',
    (tester) async {
      final h = await pumpWithCart(tester);
      await press(tester, LogicalKeyboardKey.f8);
      await press(tester, LogicalKeyboardKey.f4);
      expect(payOpen(), isFalse);
      await press(tester, LogicalKeyboardKey.f8);
      expect(
        find.text('Clear the cart?'),
        findsOneWidget,
        reason: 'still one dialog',
      );
      expect(h.carts.removeCalls, isEmpty);
    },
  );

  testWidgets('the hardware scanner still works with shortcuts in place', (
    tester,
  ) async {
    final h = PageHarness();
    h.products.onBarcode = (_) async => item(42);
    h.carts.onAdd = (_) async => CartSaleFactory.sale(
      items: [lineJson(id: 1, variationId: 42)],
      total: 10,
    );
    await pumpProductsPage(tester, h);
    await press(tester, LogicalKeyboardKey.f2);
    await scan(tester, '4006381333931');
    expect(h.products.barcodeCalls, ['4006381333931']);
    expect(h.carts.addCalls.single.variationId, 42);
  });
}
