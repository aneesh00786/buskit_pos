import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/barcode/barcode_key_buffer.dart';
import 'package:buskit_pos/features/barcode/barcode_scan_handler.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

ProductItem item(int id, {String name = 'Tea', String? variation = '250g'}) =>
    ProductItem.fromJson(
      productJson(id: id, name: name, variation: variation, unit: 'pack'),
    )!;

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

Future<void> scan(WidgetTester tester, String code, {bool enter = true}) async {
  for (final ch in code.split('')) {
    final key =
        LogicalKeyboardKey.findKeyByKeyId(ch.codeUnitAt(0)) ??
        LogicalKeyboardKey(ch.codeUnitAt(0));
    await simulateKeyDownEvent(key, character: ch);
    await simulateKeyUpEvent(key);
  }
  if (enter) {
    await simulateKeyDownEvent(LogicalKeyboardKey.enter);
    await simulateKeyUpEvent(LogicalKeyboardKey.enter);
  }
  await tester.pumpAndSettle();
}

void main() {
  group('BarcodeKeyBuffer', () {
    final t0 = DateTime(2026, 1, 1, 9);
    DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

    String? burst(
      BarcodeKeyBuffer b,
      String code, {
      int gap = 10,
      int? enterGap,
    }) {
      var t = 0;
      for (final ch in code.split('')) {
        b.addChar(ch, at(t));
        t += gap;
      }
      return b.complete(at(t - gap + (enterGap ?? gap)));
    }

    test('a fast burst ending in Enter is a barcode', () {
      expect(burst(BarcodeKeyBuffer(), '4006381333931'), '4006381333931');
    });

    test('typing at human speed is not a barcode', () {
      expect(burst(BarcodeKeyBuffer(), '123456', gap: 200), isNull);
    });

    test('a slow pause before Enter is not a barcode', () {
      expect(burst(BarcodeKeyBuffer(), '123456', enterGap: 500), isNull);
    });

    test('bursts shorter than the minimum are ignored', () {
      expect(burst(BarcodeKeyBuffer(), '123'), isNull);
      expect(burst(BarcodeKeyBuffer(), '1234'), '1234');
    });

    test('over 50 characters is rejected (the backend limit)', () {
      expect(burst(BarcodeKeyBuffer(), '1' * 51), isNull);
      expect(burst(BarcodeKeyBuffer(), '1' * 50), '1' * 50);
    });

    test('earlier slow typing is dropped when a scan starts after a pause', () {
      final b = BarcodeKeyBuffer();
      b.addChar('a', at(0));
      b.addChar('b', at(1000)); // pause → "a" was not part of the burst
      for (var i = 0; i < 5; i++) {
        b.addChar('${i + 1}', at(1010 + i * 10));
      }
      expect(b.complete(at(1060)), 'b12345');
    });

    test('Enter alone, and a second Enter, produce nothing; state resets', () {
      final b = BarcodeKeyBuffer();
      expect(b.complete(at(0)), isNull);
      expect(burst(b, '12345'), '12345');
      expect(b.complete(at(500)), isNull);
      expect(b.isEmpty, isTrue);
    });
  });

  group('BarcodeScanHandler', () {
    late FakeProductService products;
    late FakeCartService carts;
    late CartController cart;
    late BarcodeScanHandler handler;

    setUp(() {
      products = FakeProductService();
      carts = FakeCartService();
      cart = CartController(carts);
      handler = BarcodeScanHandler(products: products, cart: cart);
      carts.onAdd = (c) async => CartSaleFactory.sale(
        items: [lineJson(id: 1, variationId: c.variationId)],
        total: 10,
      );
    });
    tearDown(() => cart.dispose());

    test(
      'a known code is looked up (trimmed) and one unit added with its label',
      () async {
        products.onBarcode = (_) async => item(42);
        final r = await handler.handle('  4006381333931 \n');
        expect(products.barcodeCalls, ['4006381333931']);
        expect(r.outcome, ScanOutcome.added);
        expect(r.message, 'Added 1 × Tea');
        expect(
          (carts.addCalls.single.variationId, carts.addCalls.single.quantity),
          (42, 1),
        );
        expect(cart.labelFor(42), '250g · pack');
      },
    );

    test('an unknown code says so and adds nothing', () async {
      final r = await handler.handle('999999');
      expect(r.outcome, ScanOutcome.notFound);
      expect(r.message, 'No product found for barcode 999999.');
      expect(carts.addCalls, isEmpty);
    });

    test('empty, blank and over-long codes never reach the network', () async {
      for (final bad in [null, '', '   ', 'x' * 51]) {
        expect(
          (await handler.handle(bad)).outcome,
          ScanOutcome.invalid,
          reason: '$bad',
        );
      }
      expect(products.barcodeCalls, isEmpty);
    });

    test('Phase 14B: an AMBIGUOUS barcode (two active products) adds nothing and says why', () async {
      products.onBarcode = (_) async => throw ApiException.fromStatus(
        409,
        message: 'More than one product has this barcode.',
        errorCode: 'POS_BARCODE_AMBIGUOUS',
        data: {'barcode': '4006381333931'},
      );
      final r = await handler.handle('4006381333931');
      expect(r.outcome, ScanOutcome.error);
      expect(
        r.message,
        'More than one product uses this barcode, so nothing was added. '
        'Search for the product and add it from the list.',
      );
      expect(carts.addCalls, isEmpty);
      expect(carts.createCalls, 0, reason: 'no draft opened either');
      expect(cart.sale, isNull);
    });

    test('a lookup failure is reported in plain words', () async {
      products.onBarcode = (_) async => throw netDown;
      final r = await handler.handle('123456');
      expect(r.outcome, ScanOutcome.error);
      expect(r.message, 'No connection to the server.');
      products.onBarcode = (_) async => throw StateError('boom');
      final r2 = await handler.handle('123456');
      expect(r2.message, 'Could not look up barcode 123456.');
    });

    test('the server refusing the add (e.g. no stock) is reported', () async {
      products.onBarcode = (_) async => item(42);
      carts.onAdd = (_) async => throw const ApiException(
        kind: ApiErrorKind.conflict,
        message: 'x',
        errorCode: PosErrorCodes.insufficientStock,
        statusCode: 409,
      );
      final r = await handler.handle('123456');
      expect(r.outcome, ScanOutcome.error);
      expect(r.message, contains('Not enough stock'));
    });

    test(
      'a cart busy with another change asks the cashier to scan again',
      () async {
        products.onBarcode = (_) async => item(42);
        final gate = Completer<CartSaleLike>();
        carts.onAdd = (_) => gate.future.then((_) => CartSaleFactory.sale());
        final first = cart.addItem(1, 1); // holds the cart's mutation lock
        await Future<void>.delayed(Duration.zero);
        final r = await handler.handle('123456');
        expect(r.outcome, ScanOutcome.busy);
        gate.complete(CartSaleLike());
        await first;
      },
    );

    test('rapid scans are processed one at a time, in order', () async {
      final order = <String>[];
      final gate = Completer<void>();
      products.onBarcode = (code) async {
        order.add('lookup $code');
        if (code == 'AAAA') await gate.future;
        return item(code == 'AAAA' ? 1 : 2, name: code);
      };
      final a = handler.handle('AAAA');
      final b = handler.handle('BBBB');
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(order, ['lookup AAAA'], reason: 'second scan waits for the first');
      gate.complete();
      expect((await a).added, isTrue);
      expect((await b).added, isTrue);
      expect(order, ['lookup AAAA', 'lookup BBBB']);
      expect(carts.addCalls.map((c) => c.variationId), [1, 2]);
    });

    test('one failed scan does not block the next', () async {
      products.onBarcode = (code) async =>
          code == 'BAD1' ? throw netDown : item(3);
      final a = handler.handle('BAD1');
      final b = handler.handle('GOOD');
      expect((await a).outcome, ScanOutcome.error);
      expect((await b).added, isTrue);
    });
  });

  group('hardware scanner in the app shell', () {
    testWidgets(
      'a fast burst + Enter looks the code up and adds it to the cart',
      (tester) async {
        final h = PageHarness();
        h.products.onBarcode = (_) async => item(42);
        h.carts.onAdd = (_) async => CartSaleFactory.sale(
          items: [lineJson(id: 1, variationId: 42)],
          total: 10,
        );
        await pumpProductsPage(tester, h);
        await scan(tester, '4006381333931');
        expect(h.products.barcodeCalls, ['4006381333931']);
        expect(h.carts.addCalls.single.variationId, 42);
        expect(find.text('Added 1 × Tea'), findsOneWidget);
      },
    );

    testWidgets('an unknown code shows a message and adds nothing', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      await scan(tester, '5550001112');
      expect(
        find.text('No product found for barcode 5550001112.'),
        findsOneWidget,
      );
      expect(h.carts.addCalls, isEmpty);
    });

    testWidgets('no Enter, a short burst, or a lone Enter does nothing', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      // Pauses between attempts, as a person would leave.
      Future<void> pause() => tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)),
      );
      await scan(tester, '4006381333931', enter: false);
      await pause();
      await scan(tester, '123');
      await pause();
      await scan(tester, '');
      expect(h.products.barcodeCalls, isEmpty);
    });

    testWidgets('a scan while the search box has the code clears the box', (
      tester,
    ) async {
      final h = PageHarness();
      h.products.onBarcode = (_) async => item(42);
      h.carts.onAdd = (_) async => CartSaleFactory.sale(
        items: [lineJson(id: 1, variationId: 42)],
        total: 10,
      );
      await pumpProductsPage(tester, h);
      final field = find.byType(TextField).first;
      await tester.enterText(field, '4006381333931');
      await scan(tester, '4006381333931');
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      // The debounced search for the code must not fire afterwards.
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        h.products.calls.where((c) => c.query == '4006381333931'),
        isEmpty,
      );
    });

    testWidgets('scans are ignored while a dialog covers the shell', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(Scaffold).first),
          builder: (_) => const AlertDialog(content: Text('Payment form')),
        ),
      );
      await tester.pumpAndSettle();
      await scan(tester, '4006381333931');
      expect(h.products.barcodeCalls, isEmpty);
    });

    testWidgets('a lookup error is shown', (tester) async {
      final h = PageHarness();
      h.products.onBarcode = (_) async => throw netDown;
      await pumpProductsPage(tester, h);
      await scan(tester, '4006381333931');
      expect(find.text('No connection to the server.'), findsOneWidget);
    });
  });

  group('camera scanning', () {
    testWidgets(
      'the header icon opens the camera; a detected code is looked up and added',
      (tester) async {
        final h = PageHarness();
        h.camera.next = '7622210449283';
        h.products.onBarcode = (_) async => item(42, name: 'Biscuits');
        h.carts.onAdd = (_) async => CartSaleFactory.sale(
          items: [lineJson(id: 1, variationId: 42)],
          total: 10,
        );
        await pumpProductsPage(tester, h);
        expect(find.byTooltip('Scan barcode (coming soon)'), findsNothing);
        await tester.tap(find.byTooltip('Scan barcode with camera'));
        await tester.pumpAndSettle();
        expect(h.camera.opened, 1);
        expect(h.products.barcodeCalls, ['7622210449283']);
        expect(find.text('Added 1 × Biscuits'), findsOneWidget);
      },
    );

    testWidgets('closing the camera without a code does nothing', (
      tester,
    ) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      await tester.tap(find.byTooltip('Scan barcode with camera'));
      await tester.pumpAndSettle();
      expect(h.camera.opened, 1);
      expect(h.products.barcodeCalls, isEmpty);
    });

    testWidgets('a second tap while the camera is open is ignored', (
      tester,
    ) async {
      final h = PageHarness();
      final gate = Completer<String?>();
      h.camera.onScan = () => gate.future;
      await pumpProductsPage(tester, h);
      await tester.tap(find.byTooltip('Scan barcode with camera'));
      await tester.pump();
      await tester.tap(find.byTooltip('Scan barcode with camera'));
      await tester.pump();
      expect(h.camera.opened, 1);
      gate.complete(null);
      await tester.pumpAndSettle();
    });

    testWidgets('phones get the scan action in the app bar', (tester) async {
      final h = PageHarness();
      h.camera.next = '7622210449283';
      h.products.onBarcode = (_) async => item(42);
      h.carts.onAdd = (_) async => CartSaleFactory.sale(
        items: [lineJson(id: 1, variationId: 42)],
        total: 10,
      );
      await pumpProductsPage(tester, h, width: 400, height: 800);
      await tester.tap(find.byTooltip('Scan barcode with camera'));
      await tester.pumpAndSettle();
      expect(h.products.barcodeCalls, ['7622210449283']);
      expect(find.text('Added 1 × Tea'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('without camera support the button is disabled and says why', (
      tester,
    ) async {
      final h = PageHarness();
      h.camera.supported = false;
      await pumpProductsPage(tester, h);
      final tip = find.byTooltip(
        'Camera scanning is not available on this device',
      );
      expect(tip, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.qr_code_scanner),
            )
            .onPressed,
        isNull,
      );
    });
  });
}

/// Placeholder value for a completer whose result is ignored.
class CartSaleLike {}
