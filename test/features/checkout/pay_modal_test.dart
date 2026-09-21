import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

final uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

CartSale sale112({String name = 'Tea', double total = 112}) =>
    CartSaleFactory.sale(
      items: [
        lineJson(id: 1, quantity: 2, name: name),
        lineJson(id: 2, variationId: 43, name: 'Salt'),
      ],
      total: total,
    );

/// The real ProductsPage with a filled cart; returns the harness.
Future<PageHarness> pumpWithCart(
  WidgetTester tester, {
  double width = 1400,
  double height = 900,
  double total = 112,
  String name = 'Tea',
  ThemeData? theme,
  double textScale = 1,
}) async {
  final h = PageHarness();
  h.carts.onAdd = (_) async => sale112(name: name, total: total);
  h.carts.onGet = (_) async => sale112(name: name, total: total);
  await pumpProductsPage(
    tester,
    h,
    width: width,
    height: height,
    theme: theme,
    textScale: textScale,
  );
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  if (width < 900) {
    await tester.tap(find.textContaining('Cart ·'));
    await tester.pumpAndSettle();
  }
  return h;
}

Future<void> openPay(WidgetTester tester) async {
  await tester.tap(find.text('Pay'));
  await tester.pumpAndSettle();
}

/// Finds [f] only inside the payment dialog (the cart panel behind it repeats many labels).
Finder inModal(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

Finder get completeBtn => find.widgetWithText(FilledButton, 'Complete Sale');
bool completeEnabled(WidgetTester t) =>
    t.widget<FilledButton>(completeBtn).onPressed != null;
Future<void> typeInto(WidgetTester t, String label, String text) async {
  await t.enterText(find.widgetWithText(TextField, label), text);
  await t.pump();
}

void main() {
  group('opening the payment screen', () {
    testWidgets(
      'Pay opens a dialog on tablets with the server total as the amount due',
      (tester) async {
        await pumpWithCart(tester);
        await openPay(tester);
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.text('Take payment'), findsOneWidget);
        expect(find.text('Amount due'), findsOneWidget);
        expect(find.text('112.00'), findsWidgets);
        expect(completeEnabled(tester), isFalse);
      },
    );

    testWidgets('on phones it is a tall bottom sheet', (tester) async {
      await pumpWithCart(tester, width: 400, height: 800);
      await openPay(tester);
      expect(
        find.byType(BottomSheet),
        findsNWidgets(2),
        reason: 'the cart sheet and the payment sheet above it',
      );
      expect(find.text('Take payment'), findsOneWidget);
    });

    testWidgets('Cancel closes it without any request', (tester) async {
      final h = await pumpWithCart(tester);
      await openPay(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Take payment'), findsNothing);
      expect(h.carts.completeCalls, isEmpty);
      expect(h.cart.sale, isNotNull);
    });

    testWidgets('tapping outside does not dismiss it', (tester) async {
      await pumpWithCart(tester);
      await openPay(tester);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.text('Take payment'), findsOneWidget);
    });
  });

  group('cash', () {
    testWidgets(
      'live change/shortfall; Complete Sale is enabled only when the tender covers the total',
      (tester) async {
        await pumpWithCart(tester);
        await openPay(tester);
        expect(inModal(find.text('Change due')), findsOneWidget);
        expect(find.text('Short by'), findsNothing);

        await typeInto(tester, 'Amount tendered', '100');
        expect(find.text('Short by'), findsOneWidget);
        expect(inModal(find.text('12.00')), findsOneWidget);
        expect(completeEnabled(tester), isFalse);
        expect(
          find.text('Amount tendered is less than the total.'),
          findsOneWidget,
        );

        await typeInto(tester, 'Amount tendered', '120');
        expect(inModal(find.text('Change due')), findsOneWidget);
        expect(inModal(find.text('8.00')), findsOneWidget);
        expect(completeEnabled(tester), isTrue);

        await typeInto(tester, 'Amount tendered', '112');
        expect(inModal(find.text('0.00')), findsOneWidget);
        expect(completeEnabled(tester), isTrue);
      },
    );

    testWidgets(
      'only quick-cash amounts that cover the total are offered; Exact fills the total',
      (tester) async {
        await pumpWithCart(tester);
        await openPay(tester);
        expect(find.widgetWithText(OutlinedButton, 'Exact'), findsOneWidget);
        for (final small in ['10', '20', '50', '100']) {
          expect(
            find.widgetWithText(OutlinedButton, small),
            findsNothing,
            reason: small,
          );
        }
        await tester.tap(find.text('Exact'));
        await tester.pump();
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Amount tendered'),
              )
              .controller!
              .text,
          '112.00',
        );
        expect(completeEnabled(tester), isTrue);
      },
    );

    testWidgets(
      'small totals offer 10/20/50/100; a quick amount sets the tender and shows the change',
      (tester) async {
        await pumpWithCart(tester, total: 8.5);
        await openPay(tester);
        for (final v in ['Exact', '10', '20', '50', '100']) {
          expect(
            find.widgetWithText(OutlinedButton, v),
            findsOneWidget,
            reason: v,
          );
        }
        await tester.tap(find.widgetWithText(OutlinedButton, '20'));
        await tester.pump();
        expect(find.text('11.50'), findsOneWidget);
        expect(completeEnabled(tester), isTrue);
      },
    );

    testWidgets('typing is filtered as you go: digits and at most 3 decimals', (
      tester,
    ) async {
      await pumpWithCart(tester);
      await openPay(tester);
      final field = find.widgetWithText(TextField, 'Amount tendered');
      for (final ch in '12a3.4567'.split('')) {
        final next = tester.widget<TextField>(field).controller!.text + ch;
        await tester.enterText(field, next);
        await tester.pump();
      }
      expect(tester.widget<TextField>(field).controller!.text, '123.456');
    });

    testWidgets(
      'Complete Sale sends the cash payment with a UUID v4 key and shows the receipt',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();

        final c = h.carts.completeCalls.single;
        expect((c.saleId, c.expectedVersion), (7, 2));
        expect(c.key, matches(uuidV4));
        expect(c.payments.single.toJson(), {
          'method': 'cash',
          'amount': 112,
          'tendered_amount': 120,
        });

        expect(find.text('Sale complete'), findsOneWidget);
        expect(find.text('POS-00000007'), findsOneWidget);
        expect(find.text('Date / time'), findsOneWidget);
        expect(inModal(find.text('Guest checkout')), findsOneWidget);
        expect(
          inModal(find.text('Tea')),
          findsWidgets,
          reason: 'the name comes from the cart snapshot',
        );
        expect(inModal(find.text('Cash')), findsOneWidget);
        expect(inModal(find.text('  Tendered')), findsOneWidget);
        expect(inModal(find.text('  Change')), findsOneWidget);
        expect(inModal(find.text('8.00')), findsWidgets);
        expect(inModal(find.text('Change due')), findsOneWidget);
      },
    );

    testWidgets(
      'receipt actions are clearly placeholders; New Sale clears everything and closes',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();

        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Print Receipt'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Email / SMS'),
              )
              .onPressed,
          isNull,
        );
        expect(
          find.byTooltip('Receipts are coming in the next phase'),
          findsNWidgets(2),
        );

        await tester.tap(find.text('New Sale'));
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsNothing);
        expect(h.cart.completedSale, isNull);
        expect(h.cart.sale, isNull);
        expect(find.text('The cart is empty'), findsOneWidget);
      },
    );

    testWidgets('a fresh checkout never re-shows the previous receipt', (
      tester,
    ) async {
      final h = await pumpWithCart(tester);
      await openPay(tester);
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('New Sale'));
      await tester.pumpAndSettle();
      h.carts.onCreate = () async => CartSale.fromJson(saleJson(id: 8))!;
      h.carts.onAdd = (c) async => CartSale.fromJson(
        saleJson(id: 8, version: 2, items: [lineJson(id: 3)], total: 20),
      )!;
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      await openPay(tester);
      expect(find.text('Take payment'), findsOneWidget);
      expect(find.text('Sale complete'), findsNothing);
    });
  });

  group('split tender', () {
    Future<void> openSplit(WidgetTester tester) async {
      await openPay(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Split'));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'cash for part; the remainder goes to Card; both lines sum to the total',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openSplit(tester);
        expect(completeEnabled(tester), isFalse);
        await typeInto(tester, 'Cash amount', '50');
        expect(inModal(find.text('Card pays')), findsOneWidget);
        expect(inModal(find.text('62.00')), findsOneWidget);
        expect(completeEnabled(tester), isTrue);

        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        final lines = h.carts.completeCalls.single.payments
            .map((p) => p.toJson())
            .toList();
        expect(lines, [
          {'method': 'cash', 'amount': 50, 'tendered_amount': 50},
          {'method': 'card', 'amount': 62},
        ]);
        expect((lines[0]['amount'] as num) + (lines[1]['amount'] as num), 112);
      },
    );

    testWidgets(
      'cash received above the amount gives change; the secondary can be Other with a reference',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openSplit(tester);
        await typeInto(tester, 'Cash amount', '40');
        await typeInto(
          tester,
          'Cash received (optional, if more than the amount)',
          '50',
        );
        await tester.tap(
          find.descendant(
            of: find.byType(SegmentedButton<TenderMethod>),
            matching: find.text('Other'),
          ),
        );
        await tester.pumpAndSettle();
        await typeInto(tester, 'Reference (optional)', 'VOUCHER-7');
        expect(inModal(find.text('Other pays')), findsOneWidget);
        expect(inModal(find.text('72.00')), findsOneWidget);
        expect(
          inModal(find.text('10.00')),
          findsOneWidget,
          reason: 'change due on the cash line',
        );

        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        final lines = h.carts.completeCalls.single.payments
            .map((p) => p.toJson())
            .toList();
        expect(lines[0], {
          'method': 'cash',
          'amount': 40,
          'tendered_amount': 50,
        });
        expect(lines[1], {
          'method': 'other',
          'amount': 72,
          'reference': 'VOUCHER-7',
        });
      },
    );

    testWidgets('invalid splits keep Complete Sale disabled with a reason', (
      tester,
    ) async {
      await pumpWithCart(tester);
      await openSplit(tester);
      await typeInto(tester, 'Cash amount', '112');
      expect(completeEnabled(tester), isFalse);
      expect(
        find.text('For a split, the cash amount must be less than the total.'),
        findsOneWidget,
      );
      await typeInto(tester, 'Cash amount', '50');
      await typeInto(
        tester,
        'Cash received (optional, if more than the amount)',
        '30',
      );
      expect(completeEnabled(tester), isFalse);
      expect(
        find.text('Cash received is less than the cash amount.'),
        findsOneWidget,
      );
    });

    testWidgets('the receipt lists every payment of a split sale', (
      tester,
    ) async {
      final h = await pumpWithCart(tester);
      await openSplit(tester);
      await typeInto(tester, 'Cash amount', '50');
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls, hasLength(1));
      expect(inModal(find.text('Cash')), findsOneWidget);
      expect(inModal(find.text('Card')), findsOneWidget);
      expect(inModal(find.text('62.00')), findsWidgets);
    });
  });

  group('card / other (recorded only)', () {
    testWidgets(
      'says no terminal is connected; sends the full total with the reference and no tendered amount',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openPay(tester);
        await tester.tap(find.widgetWithText(ChoiceChip, 'Card'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('no card terminal is connected'),
          findsOneWidget,
        );
        expect(
          completeEnabled(tester),
          isTrue,
          reason: 'reference is optional',
        );
        await typeInto(tester, 'Reference (optional)', 'AUTH-123');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(h.carts.completeCalls.single.payments.single.toJson(), {
          'method': 'card',
          'amount': 112,
          'reference': 'AUTH-123',
        });
      },
    );
  });

  group('failures and safe retry', () {
    testWidgets(
      'a network failure keeps the sale open, offers Retry payment, and the retry reuses the SAME key',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (_) async => throw const ApiException(
          kind: ApiErrorKind.network,
          message:
              'Cannot reach the server. Check your connection and try again.',
        );
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();

        expect(find.textContaining('Cannot reach the server'), findsOneWidget);
        expect(find.textContaining('safe to retry'), findsOneWidget);
        expect(find.text('Retry payment'), findsOneWidget);
        expect(h.cart.sale, isNotNull);
        final key = h.carts.completeCalls.single.key;

        h.carts.onComplete = (c) async =>
            CompletedSale.fromJson(completedJson(payments: c.payments))!;
        await tester.tap(find.text('Retry payment'));
        await tester.pumpAndSettle();
        expect(h.carts.completeCalls, hasLength(2));
        expect(
          h.carts.completeCalls.last.key,
          key,
          reason: 'the same idempotency key on retry',
        );
        expect(find.text('Sale complete'), findsOneWidget);
      },
    );

    testWidgets('a timeout is handled the same way', (tester) async {
      final h = await pumpWithCart(tester);
      h.carts.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.timeout,
        message: 'The server took too long to respond. Please try again.',
      );
      await openPay(tester);
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('took too long'), findsOneWidget);
      expect(find.text('Retry payment'), findsOneWidget);
    });

    testWidgets('changing the tender after a failure sends a NEW key', (
      tester,
    ) async {
      final h = await pumpWithCart(tester);
      h.carts.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await openPay(tester);
      await typeInto(tester, 'Amount tendered', '120');
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      await typeInto(tester, 'Amount tendered', '150');
      await tester.tap(find.text('Retry payment'));
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls.map((c) => c.key).toSet(), hasLength(2));
    });

    testWidgets('a server error never shows internals and offers Retry', (
      tester,
    ) async {
      final h = await pumpWithCart(tester);
      h.carts.onComplete = (_) async =>
          throw apiError(500, message: 'ER_X at /srv/posSaleService.js:250');
      await openPay(tester);
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('went wrong on the server'), findsOneWidget);
      expect(find.textContaining('/srv/'), findsNothing);
      expect(find.text('Retry payment'), findsOneWidget);
    });

    testWidgets(
      'insufficient stock names the products and quantities; no Retry payment (it would fail identically)',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (_) async => throw apiError(
          409,
          message: 'Insufficient stock',
          code: 'POS_INSUFFICIENT_STOCK',
          data: {
            'shortages': [
              {
                'item_id': 1,
                'product_variation_id': 42,
                'requested': 2,
                'available': 1,
              },
            ],
          },
        );
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(
          find.textContaining(
            'Not enough stock: Tea (2 requested, 1 available)',
          ),
          findsOneWidget,
        );
        expect(find.text('Retry payment'), findsNothing);
        expect(find.text('Complete Sale'), findsOneWidget);
      },
    );

    testWidgets(
      'weight-unit products are explained by name, without the raw error code',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (_) async => throw apiError(
          422,
          message: 'raw',
          code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
          data: {
            'weight_unit_item_ids': [2],
          },
        );
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('sold by weight (KG/GR) (Salt)'),
          findsOneWidget,
        );
        expect(find.textContaining('POS_WEIGHT'), findsNothing);
      },
    );

    testWidgets(
      'a version conflict tells the cashier the cart changed and the total shown is the refreshed one',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (_) async => throw apiError(
          409,
          message: 'Sale has been modified since you last read it',
          data: {'current_version': 9},
        );
        h.carts.onGet = (_) async => CartSaleFactory.sale(
          version: 9,
          items: [lineJson(id: 1, quantity: 5, name: 'Tea')],
          total: 200,
        );
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('changed elsewhere and has been refreshed'),
          findsOneWidget,
        );
        expect(
          find.text('200.00'),
          findsWidgets,
          reason: 'amount due follows the refreshed server total',
        );
        expect(h.carts.completeCalls, hasLength(1), reason: 'not retried');
      },
    );

    testWidgets('a payment-total mismatch from the server is shown', (
      tester,
    ) async {
      final h = await pumpWithCart(tester);
      h.carts.onComplete = (_) async => throw apiError(
        422,
        message: 'Payment total (100) must equal the sale total (112)',
      );
      await openPay(tester);
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('must equal the sale total'), findsOneWidget);
    });

    testWidgets(
      'a completion failure is shown in the payment screen, not repeated in the cart panel behind it',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (_) async => throw apiError(
          422,
          message: 'Payment total (100) must equal the sale total (112)',
        );
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(
          find.textContaining('must equal the sale total'),
          findsOneWidget,
        );
      },
    );
  });

  group('in flight', () {
    testWidgets(
      'while the request runs: spinner, Complete/Cancel/Close and every field disabled; a second tap does nothing',
      (tester) async {
        final h = await pumpWithCart(tester);
        final gate = Completer<CompletedSale>();
        h.carts.onComplete = (_) => gate.future;
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pump();

        expect(find.byType(CircularProgressIndicator), findsWidgets);
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton).last).onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Cancel'),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<TextField>(
                find.widgetWithText(TextField, 'Amount tendered'),
              )
              .enabled,
          isFalse,
        );
        await tester.tap(find.byType(FilledButton).last, warnIfMissed: false);
        await tester.pump();
        expect(h.carts.completeCalls, hasLength(1));

        gate.complete(CompletedSale.fromJson(completedJson())!);
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.carts.completeCalls, hasLength(1));
      },
    );
  });

  group('receipt content', () {
    testWidgets(
      'shows the order number, local date/time, items with names, server totals and payment breakdown',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (c) async => CompletedSale.fromJson(
          completedJson(
            id: 7,
            number: 'POS-00000007',
            customerId: 'C-42',
            payments: c.payments,
            subtotal: 100,
            tax: 12,
            total: 112,
            completedAt: '2026-09-21 15:23:52',
            items: [
              {
                'id': 1,
                'product_variation_id': 42,
                'quantity': 2,
                'unit_price': 50,
                'tax_percent': 12,
                'tax_included': false,
                'tax_amount': 12,
                'discount_amount': 0,
                'line_total': 112,
              },
              {
                'id': 2,
                'product_variation_id': 43,
                'quantity': 1,
                'unit_price': 20,
                'tax_percent': 0,
                'tax_included': false,
                'tax_amount': 0,
                'discount_amount': 0,
                'line_total': 20,
              },
            ],
          ),
        )!;
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '150');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();

        expect(inModal(find.text('Customer')), findsOneWidget);
        expect(inModal(find.text('C-42')), findsOneWidget);
        expect(inModal(find.text('Tea')), findsOneWidget);
        expect(inModal(find.text('Salt')), findsOneWidget);
        expect(inModal(find.text('2 × 50.00')), findsOneWidget);
        expect(inModal(find.text('1 × 20.00')), findsOneWidget);
        expect(inModal(find.text('Subtotal')), findsOneWidget);
        expect(inModal(find.text('100.00')), findsOneWidget);
        expect(inModal(find.text('12.00')), findsWidgets);
        expect(inModal(find.text('Total')), findsOneWidget);
        expect(inModal(find.text('150.00')), findsWidgets, reason: 'tendered');
        expect(
          inModal(find.text('38.00')),
          findsWidgets,
          reason: 'server change',
        );
      },
    );

    testWidgets(
      'a missing product name (line not in the snapshot) falls back to the item number',
      (tester) async {
        final h = await pumpWithCart(tester);
        h.carts.onComplete = (c) async => CompletedSale.fromJson(
          completedJson(
            payments: c.payments,
            items: [
              {
                'id': 99,
                'product_variation_id': 77,
                'quantity': 1,
                'unit_price': 5,
                'tax_percent': 0,
                'tax_included': false,
                'tax_amount': 0,
                'discount_amount': 0,
                'line_total': 5,
              },
            ],
          ),
        )!;
        await openPay(tester);
        await tester.tap(find.text('Exact'));
        await tester.pump();
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        expect(inModal(find.text('Item 77')), findsOneWidget);
      },
    );
  });

  group('responsive and theming', () {
    for (final size in const [
      Size(360, 640),
      Size(400, 800),
      Size(800, 1280),
      Size(1400, 900),
      Size(1920, 1080),
    ]) {
      testWidgets(
        'no overflow at ${size.width.toInt()}x${size.height.toInt()} (form, split, error, receipt)',
        (tester) async {
          final h = await pumpWithCart(
            tester,
            width: size.width,
            height: size.height,
            name: 'A very long product name that goes on and on and on',
          );
          h.carts.onComplete = (_) async => throw apiError(
            409,
            message: 'Insufficient stock',
            code: 'POS_INSUFFICIENT_STOCK',
            data: {
              'shortages': [
                {'item_id': 1, 'requested': 2, 'available': 1},
                {'item_id': 2, 'requested': 3, 'available': 0},
              ],
            },
          );
          await openPay(tester);
          expect(tester.takeException(), isNull);
          await tester.tap(find.widgetWithText(ChoiceChip, 'Split'));
          await tester.pumpAndSettle();
          await typeInto(tester, 'Cash amount', '50');
          expect(tester.takeException(), isNull);
          await tester.tap(find.widgetWithText(ChoiceChip, 'Cash'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Exact'));
          await tester.pump();
          await tester.tap(completeBtn);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          h.carts.onComplete = (c) async =>
              CompletedSale.fromJson(completedJson(payments: c.payments))!;
          await tester.tap(completeBtn);
          await tester.pumpAndSettle();
          expect(find.text('Sale complete'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    testWidgets('no overflow at 150% text scale on a phone', (tester) async {
      await pumpWithCart(tester, width: 360, height: 700, textScale: 1.5);
      await openPay(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Split'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders in dark mode', (tester) async {
      await pumpWithCart(tester, theme: AppTheme.dark());
      await openPay(tester);
      await tester.tap(find.text('Exact'));
      await tester.pump();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Sale complete'), findsOneWidget);
    });

    testWidgets('actions meet the 48dp minimum touch target', (tester) async {
      await pumpWithCart(tester);
      await openPay(tester);
      expect(tester.getSize(completeBtn).height, greaterThanOrEqualTo(48));
      expect(
        tester.getSize(find.widgetWithText(OutlinedButton, 'Exact')).height,
        greaterThanOrEqualTo(48),
      );
      expect(
        tester.getSize(find.byTooltip('Close')).height,
        greaterThanOrEqualTo(48),
      );
    });
  });
}
