import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

/// A 112.00 sale with a customer and 10.00 of pending wallet redemption —
/// wallet is a payment-tender substitute, not a discount (see the plan's
/// Context): the sale total stays 112.00, but only 102.00 needs to be
/// covered by cash/card/other tenders.
CartSale saleWithWallet({double walletRedeemed = 10}) => CartSaleFactory.sale(
  items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
  total: 112,
  customerId: 'CUST-1',
  loyalty: loyaltySaleInfoJson(walletRedeemed: walletRedeemed),
);

Future<PageHarness> pumpWithWalletSale(WidgetTester tester) async {
  final h = PageHarness();
  h.carts.onAdd = (_) async => saleWithWallet();
  h.carts.onGet = (_) async => saleWithWallet();
  await pumpProductsPage(tester, h, width: 1400, height: 900);
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets(
    'a pending wallet redemption reduces the amount due, not the sale total',
    (tester) async {
      await pumpWithWalletSale(tester);
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();

      expect(find.text('Amount due'), findsOneWidget);
      // 112.00 total - 10.00 wallet = 102.00 due via cash/card/other.
      expect(find.text('102.00'), findsOneWidget);
      expect(find.text('Wallet applied'), findsOneWidget);
      expect(find.text('-10.00'), findsOneWidget);
    },
  );

  testWidgets(
    'the success view shows points earned, cashback earned and wallet redeemed',
    (tester) async {
      final h = await pumpWithWalletSale(tester);
      h.carts.onComplete = (c) async => CompletedSale.fromJson(
        completedJson(
          payments: c.payments,
          total: 112,
          customerId: 'CUST-1',
          loyalty: loyaltySaleInfoJson(
            walletRedeemed: 10,
            pointsEarned: 102,
            cashbackEarned: 5.1,
          ),
        ),
      )!;
      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Amount tendered'),
        '102',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
      await tester.pumpAndSettle();

      expect(find.text('Loyalty'), findsOneWidget);
      expect(find.text('Wallet redeemed'), findsOneWidget);
      expect(find.text('-10.00'), findsOneWidget);
      expect(find.text('Points earned'), findsOneWidget);
      expect(find.text('+102'), findsOneWidget);
      expect(find.text('Cashback earned'), findsOneWidget);
      expect(find.text('+5.10'), findsOneWidget);
    },
  );

  testWidgets('no loyalty on the completed sale shows no Loyalty section', (
    tester,
  ) async {
    final h = PageHarness();
    h.carts.onAdd = (_) async => CartSaleFactory.sale(
      items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
      total: 112,
    );
    h.carts.onGet = (_) async => CartSaleFactory.sale(
      items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
      total: 112,
    );
    await pumpProductsPage(tester, h, width: 1400, height: 900);
    await tester.tap(find.text('Add').first);
    await tester.pumpAndSettle();
    h.carts.onComplete = (c) async => CompletedSale.fromJson(
      completedJson(payments: c.payments, total: 112),
    )!;
    await tester.tap(find.text('Pay'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Amount tendered'),
      '112',
    );
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
    await tester.pumpAndSettle();
    expect(find.text('Loyalty'), findsNothing);
  });
}
