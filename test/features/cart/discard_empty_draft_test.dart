import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

/// A cart whose server-side draft exists but has no items (e.g. after every
/// item was removed).
Future<PageHarness> pumpEmptyDraft(
  WidgetTester tester, {
  double width = 1400,
  double height = 900,
  double textScale = 1,
}) async {
  final h = PageHarness();
  h.carts.onAdd = (_) async => CartSaleFactory.sale();
  h.carts.onGet = (_) async => CartSaleFactory.sale();
  await pumpProductsPage(
    tester,
    h,
    width: width,
    height: height,
    textScale: textScale,
  );
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  if (width < 900) {
    await tester.tap(find.textContaining('Cart ·'));
    await tester.pumpAndSettle();
  }
  expect(h.cart.sale?.items, isEmpty);
  return h;
}

Finder get discard => find.widgetWithText(TextButton, 'Discard order');

void main() {
  group('Discard order (empty draft)', () {
    testWidgets(
      'is offered when an empty draft exists on the server; Hold/Pay/Void are not',
      (tester) async {
        await pumpEmptyDraft(tester);
        expect(discard, findsOneWidget);
        expect(find.text('The cart is empty'), findsOneWidget);
        expect(find.text('Void sale'), findsNothing);
        expect(find.text('Hold sale'), findsNothing);
        expect(find.widgetWithText(FilledButton, 'Pay'), findsNothing);
      },
    );

    testWidgets('is not shown when there is no sale at all', (tester) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      expect(h.cart.sale, isNull);
      expect(discard, findsNothing);
    });

    testWidgets('is not shown for a cart with items (Void sale is)', (
      tester,
    ) async {
      final h = PageHarness();
      h.carts.onAdd = (_) async =>
          CartSaleFactory.sale(items: [lineJson(id: 1)], total: 10);
      h.carts.onGet = (_) async =>
          CartSaleFactory.sale(items: [lineJson(id: 1)], total: 10);
      await pumpProductsPage(tester, h);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      expect(discard, findsNothing);
      expect(find.text('Void sale'), findsOneWidget);
    });

    testWidgets('asks first; "Keep order" leaves the server draft alone', (
      tester,
    ) async {
      final h = await pumpEmptyDraft(tester);
      await tester.tap(discard);
      await tester.pumpAndSettle();
      expect(find.text('Discard this order?'), findsOneWidget);
      await tester.tap(find.text('Keep order'));
      await tester.pumpAndSettle();
      expect(h.carts.cancelCalls, isEmpty);
      expect(discard, findsOneWidget);
    });

    testWidgets(
      'confirming cancels the draft with its version and clears the cart',
      (tester) async {
        final h = await pumpEmptyDraft(tester);
        await tester.tap(discard);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Discard order'));
        await tester.pumpAndSettle();
        expect(
          (
            h.carts.cancelCalls.single.saleId,
            h.carts.cancelCalls.single.expectedVersion,
          ),
          (7, 2),
        );
        expect(h.cart.sale, isNull);
        expect(discard, findsNothing);
        expect(find.text('Order #7 discarded'), findsOneWidget);
      },
    );

    testWidgets('a failure keeps the draft and the button, and says why', (
      tester,
    ) async {
      final h = await pumpEmptyDraft(tester);
      h.carts.onCancel = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'No connection to the server.',
      );
      await tester.tap(discard);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard order'));
      await tester.pumpAndSettle();
      expect(find.text('No connection to the server.'), findsOneWidget);
      expect(h.cart.sale, isNotNull);
      expect(discard, findsOneWidget);
      expect(find.textContaining('discarded'), findsNothing);
      // Trying again works.
      h.carts.onCancel = (c) async =>
          CartSaleFactory.sale(id: c.saleId, status: 'canceled');
      await tester.tap(discard);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Discard order'));
      await tester.pumpAndSettle();
      expect(h.cart.sale, isNull);
    });

    testWidgets(
      'is disabled while the discard is in flight (no double cancel)',
      (tester) async {
        final h = await pumpEmptyDraft(tester);
        final gate = Completer<CartSale>();
        h.carts.onCancel = (_) => gate.future;
        await tester.tap(discard);
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Discard order'));
        await tester.pump();
        expect(tester.widget<TextButton>(discard).onPressed, isNull);
        gate.complete(CartSaleFactory.sale(status: 'canceled'));
        await tester.pumpAndSettle();
        expect(h.carts.cancelCalls, hasLength(1));
      },
    );

    testWidgets(
      'works from the phone cart sheet and at large text without overflow',
      (tester) async {
        final h = await pumpEmptyDraft(
          tester,
          width: 360,
          height: 640,
          textScale: 2,
        );
        expect(discard, findsOneWidget);
        await tester.tap(discard);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('Keep order'));
        await tester.pumpAndSettle();
        expect(h.carts.cancelCalls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  });
}
