// Phase 16B — content stays inside the device safe area. Large simulated
// system insets (status bar / notch / camera cut-out on top, navigation bar /
// gesture area / home indicator below) and real geometry checks: what the
// cashier must see and tap has to lie fully inside the safe rectangle — not
// merely "a SafeArea exists".
import 'package:buskit_pos/features/cart/ui/cart_panel.dart';
import 'package:buskit_pos/features/shell/ui/pos_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_page.dart';
import '../checkout/pay_modal_test.dart'
    show completeBtn, openPay, pumpWithCart;

const top = 64.0; // a tall notch / Dynamic Island status area
const bottom = 48.0; // navigation bar / gesture area / home indicator
const side = 44.0; // landscape camera cut-out

void insets(
  WidgetTester tester, {
  double t = top,
  double b = bottom,
  double l = 0,
  double r = 0,
}) {
  final p = FakeViewPadding(top: t, bottom: b, left: l, right: r);
  tester.view.padding = p;
  tester.view.viewPadding = p;
  addTearDown(tester.view.resetPadding);
  addTearDown(tester.view.resetViewPadding);
}

/// [finder]'s first widget lies inside the safe rectangle of a [size] screen.
void expectInsideSafeArea(
  WidgetTester tester,
  Finder finder,
  Size size, {
  double t = top,
  double b = bottom,
  double l = 0,
  double r = 0,
  String? reason,
}) {
  expect(finder, findsWidgets, reason: reason);
  final rect = tester.getRect(finder.first);
  final safe = Rect.fromLTRB(l, t, size.width - r, size.height - b);
  expect(
    rect.top,
    greaterThanOrEqualTo(safe.top - 0.01),
    reason: '${reason ?? finder} top $rect vs $safe',
  );
  expect(
    rect.bottom,
    lessThanOrEqualTo(safe.bottom + 0.01),
    reason: '${reason ?? finder} bottom $rect vs $safe',
  );
  expect(
    rect.left,
    greaterThanOrEqualTo(safe.left - 0.01),
    reason: '${reason ?? finder} left $rect vs $safe',
  );
  expect(
    rect.right,
    lessThanOrEqualTo(safe.right + 0.01),
    reason: '${reason ?? finder} right $rect vs $safe',
  );
}

void main() {
  group('wide shell (tablet / landscape)', () {
    testWidgets(
      '1 / 2 / 4. header, search, cart and its checkout button sit below the top inset and above the bottom inset',
      (tester) async {
        insets(tester);
        final h = await pumpWithCart(tester, width: 1400, height: 900);
        expect(tester.takeException(), isNull);
        const size = Size(1400, 900);
        expectInsideSafeArea(
          tester,
          find.byType(PosHeader),
          size,
          reason: 'header',
        );
        expectInsideSafeArea(
          tester,
          find.byKey(const Key('product-search')),
          size,
          reason: 'search',
        );
        expectInsideSafeArea(
          tester,
          find.byType(CartPanel),
          size,
          reason: 'cart panel',
        );
        expectInsideSafeArea(
          tester,
          find.text('Pay'),
          size,
          reason: 'Pay button',
        );
        expect(h.carts.addCalls, isNotEmpty);
      },
    );

    testWidgets(
      'landscape camera cut-out on the right: the cart panel stays clear of it',
      (tester) async {
        insets(tester, t: 24, b: 21, r: side);
        await pumpWithCart(tester, width: 1400, height: 900);
        expect(tester.takeException(), isNull);
        expectInsideSafeArea(
          tester,
          find.byType(CartPanel),
          const Size(1400, 900),
          t: 24,
          b: 21,
          r: side,
          reason: 'cart panel',
        );
        expectInsideSafeArea(
          tester,
          find.text('Pay'),
          const Size(1400, 900),
          t: 24,
          b: 21,
          r: side,
          reason: 'Pay',
        );
      },
    );
  });

  group('compact shell (phone)', () {
    testWidgets(
      '1 / 2. app bar title below the notch; the cart bar button above the home indicator',
      (tester) async {
        insets(tester);
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 390, height: 844);
        expect(tester.takeException(), isNull);
        const size = Size(390, 844);
        expectInsideSafeArea(
          tester,
          find.text('Products'),
          size,
          reason: 'app bar title',
        );
        expectInsideSafeArea(
          tester,
          find.byIcon(Icons.shopping_cart_outlined),
          size,
          reason: 'cart bar button',
        );
      },
    );

    testWidgets(
      '3. small phone with large insets: no overflow, controls inside the safe area',
      (tester) async {
        insets(tester);
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 320, height: 568);
        expect(tester.takeException(), isNull);
        expectInsideSafeArea(
          tester,
          find.byIcon(Icons.shopping_cart_outlined),
          const Size(320, 568),
          reason: 'cart bar button',
        );
      },
    );

    testWidgets(
      '4 / 7. the cart bottom sheet keeps its content and actions above the bottom inset',
      (tester) async {
        insets(tester);
        await pumpWithCart(tester, width: 390, height: 844);
        expect(tester.takeException(), isNull);
        // pumpWithCart opens the cart sheet on a phone.
        const size = Size(390, 844);
        expectInsideSafeArea(
          tester,
          find.byType(CartPanel),
          size,
          reason: 'cart sheet',
        );
        expectInsideSafeArea(
          tester,
          find.text('Pay'),
          size,
          reason: 'Pay in the sheet',
        );
      },
    );

    testWidgets(
      '5. checkout: the payment sheet and its Complete Sale button stay inside the safe area',
      (tester) async {
        insets(tester);
        await pumpWithCart(tester, width: 390, height: 844);
        await openPay(tester);
        expect(tester.takeException(), isNull);
        const size = Size(390, 844);
        await tester.ensureVisible(completeBtn);
        await tester.pumpAndSettle();
        expectInsideSafeArea(
          tester,
          completeBtn,
          size,
          reason: 'Complete Sale',
        );
      },
    );
  });

  group('dialogs and keyboard', () {
    testWidgets(
      '6. a dialog stays inside the safe area even when it is taller than the screen allows',
      (tester) async {
        insets(tester);
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => AlertDialog(
                        title: const Text('Dialog title'),
                        content: SingleChildScrollView(
                          child: Column(
                            children: [
                              for (var i = 0; i < 40; i++) Text('Row $i'),
                            ],
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () {},
                            child: const Text('Dialog action'),
                          ),
                        ],
                      ),
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expectInsideSafeArea(
          tester,
          find.text('Dialog title'),
          const Size(390, 844),
          reason: 'dialog title',
        );
        expectInsideSafeArea(
          tester,
          find.text('Dialog action'),
          const Size(390, 844),
          reason: 'dialog action',
        );
      },
    );

    testWidgets(
      '8. keyboard up in checkout: the focused amount field stays visible; layout recovers after it closes',
      (tester) async {
        insets(tester);
        await pumpWithCart(tester, width: 390, height: 844);
        await openPay(tester);
        final field = find.widgetWithText(TextField, 'Amount tendered');
        expect(field, findsOneWidget);
        await tester.tap(field);
        await tester.pump();
        // The keyboard covers the bottom 320 px (it includes the home-indicator area).
        tester.view.viewInsets = const FakeViewPadding(bottom: 320);
        tester.view.padding = const FakeViewPadding(top: top);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(field);
        expect(
          rect.bottom,
          lessThanOrEqualTo(844 - 320 + 0.01),
          reason: 'field above the keyboard: $rect',
        );
        expect(rect.top, greaterThanOrEqualTo(top - 0.01));
        // Keyboard closes: the Complete Sale button is back inside the safe area.
        tester.view.resetViewInsets();
        tester.view.padding = const FakeViewPadding(top: top, bottom: bottom);
        await tester.pumpAndSettle();
        await tester.ensureVisible(completeBtn);
        await tester.pumpAndSettle();
        expectInsideSafeArea(
          tester,
          completeBtn,
          const Size(390, 844),
          reason: 'Complete Sale after keyboard',
        );
      },
    );
  });
}
