// Phase 12B — WEIGHT (decimal) quantities in the app, PIECE unchanged:
// the exact-thousandths quantity rule (core/utils/quantity.dart, same as the
// backend), the cart controller (validation, exact payloads, online only),
// the cart line / sale model, the quantity dialog in weight mode, the cart
// tile control, the request body the server receives, and the receipt.
// The server stays the authority (it may refuse WEIGHT when not enabled).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/quantity.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/cart_item_tile.dart';
import 'package:buskit_pos/features/cart/ui/quantity_dialog.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

/// A draft with one WEIGHT line (1.25 kg rice @ 89.99 = 112.488).
CartSale weightSale({
  int version = 2,
  List<Map<String, dynamic>>? items,
  double subtotal = 112.488,
}) => CartSale.fromJson(
  saleJson(
    id: 7,
    version: version,
    items:
        items ??
        [
          lineJson(
            id: 1,
            variationId: 9801,
            quantity: 1.25,
            name: 'Loose Rice',
            unitPrice: 89.99,
            tax: 0,
            taxPercent: 0,
            lineTotal: 112.488,
            sellingMode: 'WEIGHT',
          ),
        ],
    subtotal: subtotal,
    total: subtotal,
  ),
)!;

void main() {
  group('quantity rule (same as the backend)', () {
    test('exact thousandths from ints, JSON doubles and text — never float multiply', () {
      expect(quantityMilliOf(2), 2000);
      expect(quantityMilliOf(1.25), 1250);
      expect(quantityMilliOf('2.500'), 2500);
      expect(quantityMilliOf(1.005), 1005);
      expect(
        quantityMilliOf(0.1 + 0.2),
        isNull,
        reason: 'float noise is refused, not rounded',
      );
      expect(quantityMilliOf('1.2345'), isNull);
      expect(quantityMilliOf(-1), isNull);
      expect(quantityFromMilli(2000), 2);
      expect(
        quantityFromMilli(2000),
        isA<int>(),
        reason: 'whole numbers stay ints (PIECE unchanged)',
      );
      expect(quantityFromMilli(1250), 1.25);
      expect(formatQuantity(1.25, weight: true), '1.250');
      expect(formatQuantity(2), '2');
      expect(formatQuantity(1.25), '1.250');
    });

    test('PIECE: whole numbers only (decimal rejected); WEIGHT: 0.001–9999, at most 3 decimals; zero / negative rejected', () {
      expect(quantityError('PIECE', 3), isNull);
      expect(
        quantityError('PIECE', 1.5),
        'Quantity must be a whole number from 1 to 9999.',
      );
      expect(quantityError('PIECE', 0), isNotNull);
      for (final ok in [
        0.25,
        '0.250',
        1.25,
        '2.500',
        0.001,
        9999,
        '9999.000',
      ]) {
        expect(quantityError('WEIGHT', ok), isNull, reason: '$ok');
      }
      for (final bad in [
        1.2345,
        '0.0001',
        0,
        -0.5,
        '-1',
        10000,
        '1e2',
        'abc',
      ]) {
        expect(quantityError('WEIGHT', bad), isNotNull, reason: '$bad');
      }
    });
  });

  group('cart controller', () {
    late FakeCartService server;
    late CartController cart;
    setUp(() {
      server = FakeCartService();
      cart = CartController(server);
    });

    test('PIECE whole quantity works exactly as before (int sent); a decimal is refused locally', () async {
      server.onAdd = (c) async => CartSale.fromJson(
        saleJson(
          id: 7,
          version: 2,
          items: [lineJson(id: 1, quantity: c.quantity)],
        ),
      )!;
      expect(await cart.addItem(42, 2), isTrue);
      expect(server.addCalls.single.quantity, 2);
      expect(server.addCalls.single.quantity, isA<int>());
      expect(await cart.addItem(42, 1.5), isFalse);
      expect(
        cart.error!.message,
        'Quantity must be a whole number from 1 to 9999.',
      );
      expect(server.addCalls, hasLength(1), reason: 'nothing sent');
      final line = cart.sale!.items.single;
      expect(
        await cart.updateQuantity(line.id, 2.5),
        isFalse,
        reason: 'a PIECE line stays whole',
      );
      expect(server.updateCalls, isEmpty);
    });

    test('WEIGHT: 1.25 / 0.25 / 2.500 accepted and sent exactly; more than 3 decimals, zero and negative refused without a request', () async {
      server.onAdd = (c) async => weightSale();
      expect(await cart.addItem(9801, 1.25, sellingMode: 'WEIGHT'), isTrue);
      expect(server.addCalls.last.quantity, 1.25);
      expect(await cart.addItem(9801, 0.25, sellingMode: 'WEIGHT'), isTrue);
      expect(await cart.addItem(9801, 2.5, sellingMode: 'WEIGHT'), isTrue);
      expect(server.addCalls.map((c) => c.quantity).toList(), [
        1.25,
        0.25,
        2.5,
      ]);
      for (final bad in [1.2345, 0, -0.5]) {
        expect(
          await cart.addItem(9801, bad, sellingMode: 'WEIGHT'),
          isFalse,
          reason: '$bad',
        );
        expect(cart.error!.message, contains('at most 3 decimal places'));
      }
      expect(server.addCalls, hasLength(3));
    });

    test('updating a WEIGHT line follows the LINE\'s mode: 0.75 sent exactly; the same weight sends nothing', () async {
      server.onAdd = (c) async => weightSale();
      server.onUpdate = (c) async => weightSale(version: 3);
      await cart.addItem(9801, 1.25, sellingMode: 'WEIGHT');
      final line = cart.sale!.items.single;
      expect(line.isWeight, isTrue);
      expect(await cart.updateQuantity(line.id, 0.75), isTrue);
      expect(server.updateCalls.single.quantity, 0.75);
      expect(
        await cart.updateQuantity(line.id, 1.250),
        isTrue,
        reason: 'unchanged quantity',
      );
      expect(server.updateCalls, hasLength(1));
      expect(await cart.updateQuantity(line.id, 1.2345), isFalse);
      expect(server.updateCalls, hasLength(1));
    });

    test('offline: WEIGHT is never sold offline (refused before anything is stored)', () async {
      final root = await Directory.systemTemp.createTemp('pos_weight_');
      addTearDown(() => root.delete(recursive: true));
      final offlineCart = CartController(
        server,
        offline: OfflineCartSupport(
          checkout: OfflineCheckoutService(OfflineStorageService(root)),
          isOffline: () => true,
          scope: () => null,
        ),
      );
      expect(
        await offlineCart.addItem(9801, 0.5, sellingMode: 'WEIGHT'),
        isFalse,
      );
      expect(
        offlineCart.error!.message,
        'Sales by weight need a connection to the server.',
      );
      expect(
        await offlineCart.addItem(9801, 1, sellingMode: 'WEIGHT'),
        isFalse,
        reason: 'even a whole weight',
      );
      expect(server.addCalls, isEmpty);
    });
  });

  group('model and totals', () {
    test('a WEIGHT line keeps its exact quantity, line total and mode; multiple WEIGHT items and totals are the server\'s exact figures', () {
      final sale = weightSale(
        items: [
          lineJson(
            id: 1,
            variationId: 9801,
            quantity: 1.25,
            name: 'Rice',
            unitPrice: 89.99,
            tax: 0,
            taxPercent: 0,
            lineTotal: 112.488,
            sellingMode: 'WEIGHT',
          ),
          lineJson(
            id: 2,
            variationId: 9804,
            quantity: 0.5,
            name: 'Dal',
            unitPrice: 120,
            tax: 3,
            taxPercent: 5,
            lineTotal: 63,
            sellingMode: 'WEIGHT',
          ),
          lineJson(
            id: 3,
            variationId: 42,
            quantity: 2,
            name: 'Soap',
            unitPrice: 10,
            tax: 0,
            taxPercent: 0,
            lineTotal: 20,
          ),
        ],
        subtotal: 192.488,
      );
      final rice = sale.items[0];
      final dal = sale.items[1];
      final soap = sale.items[2];
      expect(
        (rice.quantity, rice.quantityMilli, rice.quantityText, rice.lineTotal),
        (1.25, 1250, '1.250', 112.488),
      );
      expect(
        (dal.quantityMilli, dal.quantityText, dal.taxAmount, dal.lineTotal),
        (500, '0.500', 3.0, 63.0),
      );
      expect(
        (soap.isWeight, soap.quantity, soap.quantityText),
        (false, 2, '2'),
      );
      expect(soap.quantity, isA<int>());
      expect(sale.totals.subtotal, 192.488);
      expect(
        sale.itemCount,
        4,
        reason: '2 pieces + 2 weighed lines (one item each)',
      );
      // The server's line total for a weight is exactly price x weight to the milli.
      expect(mulCheck(89990, rice.quantityMilli), 112488);
    });

    test('older servers / completed-sale views without selling_mode are PIECE; a whole JSON double stays an int', () {
      final l = CartLine.fromJson({
        'id': 1,
        'product_variation_id': 2,
        'quantity': 3.0,
      })!;
      expect(
        (l.sellingMode, l.quantity, l.quantity is int),
        ('PIECE', 3, true),
      );
      expect(
        CartLine.fromJson({
          'id': 1,
          'product_variation_id': 2,
          'quantity': 1.2345,
        }),
        isNull,
        reason: 'never silently rounded',
      );
    });
  });

  test('checkout payload: the request body carries the decimal quantity unchanged (PIECE still an integer)', () async {
    final seen = <http.Request>[];
    final service = ApiCartService(
      PosApiClient(
        baseUrl: 'http://h',
        tokenProvider: () => 'tok',
        httpClient: MockClient((r) async {
          seen.add(r);
          return http.Response(
            jsonEncode({'status': true, 'data': saleJson(id: 7, version: 2)}),
            200,
          );
        }),
      ),
    );
    await service.addItem(
      saleId: 7,
      productVariationId: 9801,
      quantity: quantityFromMilli(1250),
      expectedVersion: 1,
    );
    await service.updateItem(
      saleId: 7,
      itemId: 1,
      quantity: quantityFromMilli(2500),
      expectedVersion: 2,
    );
    await service.addItem(
      saleId: 7,
      productVariationId: 42,
      quantity: 3,
      expectedVersion: 3,
    );
    expect(seen[0].body, contains('"quantity":1.25'));
    expect(jsonDecode(seen[0].body)['quantity'], 1.25);
    expect(jsonDecode(seen[1].body)['quantity'], 2.5);
    expect(
      seen[2].body,
      contains('"quantity":3,'),
      reason: 'PIECE payload unchanged',
    );
  });

  test('receipt: ReceiptData keeps the decimal quantity and prints it with 3 decimals; pieces print as before', () {
    final json = completedJson(
      items: [
        {
          'id': 1,
          'product_variation_id': 9801,
          'quantity': 1.25,
          'unit_price': 89.99,
          'tax_percent': 0,
          'tax_included': false,
          'tax_amount': 0,
          'discount_amount': 0,
          'line_total': 112.488,
        },
        {
          'id': 2,
          'product_variation_id': 42,
          'quantity': 2,
          'unit_price': 10,
          'tax_percent': 0,
          'tax_included': false,
          'tax_amount': 0,
          'discount_amount': 0,
          'line_total': 20,
        },
      ],
      subtotal: 132.488,
      tax: 0,
      total: 132.488,
    );
    final r = ReceiptFormatter.build(
      sale: CompletedSale.fromJson(json)!,
      names: const {1: 'Loose Rice', 2: 'Soap'},
    );
    expect(r.lines[0].quantity, 1.25);
    expect(r.lines[1].quantity, 2);
    final text = r.toLines(columns: 48);
    expect(
      text.any(
        (l) =>
            l.trimLeft().startsWith('1.250 x 89.99') &&
            l.trimRight().endsWith('112.488'),
      ),
      isTrue,
    );
    expect(text.any((l) => l.trimLeft().startsWith('2 x 10.00')), isTrue);
  });

  testWidgets(
    'quantity dialog in weight mode: 0.250 accepted (returns 0.25); 1.2345 and 0 are refused, never rounded',
    (tester) async {
      num? result = -1;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => FilledButton(
              onPressed: () async => result = await showQuantityDialog(
                context,
                initial: 1,
                itemName: 'Rice',
                weight: true,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Set weight'), findsOneWidget);
      expect(find.text('1.000'), findsOneWidget);
      for (final bad in ['1.2345', '0']) {
        await tester.enterText(find.byType(TextField), bad);
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('at most 3 decimal places'),
          findsOneWidget,
          reason: bad,
        );
      }
      await tester.enterText(find.byType(TextField), '0.250');
      await tester.tap(find.text('Update'));
      await tester.pumpAndSettle();
      expect(result, 0.25);
    },
  );

  testWidgets(
    'cart tile: a WEIGHT line shows its weight as a button (no +/- stepper); a PIECE line keeps the stepper',
    (tester) async {
      final cart = CartController(FakeCartService());
      final sale = weightSale(
        items: [
          lineJson(
            id: 1,
            variationId: 9801,
            quantity: 1.25,
            name: 'Rice',
            unitPrice: 89.99,
            tax: 0,
            taxPercent: 0,
            lineTotal: 112.488,
            sellingMode: 'WEIGHT',
          ),
          lineJson(
            id: 2,
            variationId: 42,
            quantity: 2,
            name: 'Soap',
            unitPrice: 10,
            tax: 0,
            taxPercent: 0,
            lineTotal: 20,
          ),
        ],
      );
      await tester.pumpWidget(
        ChangeNotifierProvider<CartController>.value(
          value: cart,
          child: MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  for (final l in sale.items)
                    CartItemTile(
                      line: l,
                      label: null,
                      imageUrl: null,
                      enabled: true,
                      inFlight: false,
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byKey(const Key('weight-1')), findsOneWidget);
      expect(find.text('1.250 × 89.99'), findsOneWidget);
      expect(find.byKey(const Key('weight-2')), findsNothing);
      expect(find.text('2 × 10.00'), findsOneWidget);
    },
  );
}

/// Exact price x weight to the milli, half-up (what the server computes).
int mulCheck(int priceMilli, int qtyMilli) =>
    (priceMilli * qtyMilli + 500) ~/ 1000;
