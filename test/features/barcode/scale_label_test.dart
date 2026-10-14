// Supermarket scale labels at the till. The SERVER parses every label; the
// till only recognises one (active format: length + prefix) and sends the
// barcode. Fake server only. All labels are FICTIONAL.
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/barcode/barcode_scan_handler.dart';
import 'package:buskit_pos/features/barcode/scale_label.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import 'barcode_test.dart' show item, scan;

const label = '2112345012506'; // fictional: prefix 21, PLU 12345, 1.250 kg
const config = ScaleLabelConfig(
  weightSalesEnabled: true,
  formats: [
    ScaleLabelFormat(id: 1, barcodeLength: 13, prefixes: ['21', '22']),
  ],
);

class AddCall {
  AddCall(this.saleId, this.barcode, this.expectedVersion, this.confirmRepeat);
  final int saleId;
  final String barcode;
  final int expectedVersion;
  final bool confirmRepeat;
}

class FakeScaleLabels implements ScaleLabelService {
  ScaleLabelConfig formats = config;
  Object? loadError;
  int loadCalls = 0;
  final List<String> resolveCalls = [];
  final List<AddCall> addCalls = [];
  Object? resolveError;

  /// Next answers for addToSale (an ApiException is thrown).
  final List<Object> answers = [];

  static const line = ScaleLabelLine(
    productName: 'Loose Apples',
    weightKg: 1.25,
    lineTotal: 250,
    unitPrice: 200,
    plu: '12345',
  );

  @override
  Future<ScaleLabelConfig> loadFormats() async {
    loadCalls++;
    if (loadError != null) throw loadError!;
    return formats;
  }

  @override
  Future<ScaleLabelLine?> resolve(String barcode) async {
    resolveCalls.add(barcode);
    if (resolveError != null) throw resolveError!;
    return line;
  }

  @override
  Future<(CartSale, ScaleLabelLine?)> addToSale({
    required int saleId,
    required String barcode,
    required int expectedVersion,
    bool confirmRepeat = false,
  }) async {
    addCalls.add(AddCall(saleId, barcode, expectedVersion, confirmRepeat));
    final a = answers.isNotEmpty ? answers.removeAt(0) : null;
    if (a is ApiException) throw a;
    return (
      CartSale.fromJson(
        saleJson(
          id: saleId,
          version: expectedVersion + 1,
          items: [lineJson(id: 1, variationId: 9811, quantity: 1.25)],
          total: 250,
        ),
      )!,
      line,
    );
  }
}

const repeated = ApiException(
  kind: ApiErrorKind.conflict,
  statusCode: 409,
  errorCode: 'POS_SCALE_LABEL_REPEATED',
  message: 'This exact scale label is already in this sale. If this is a second identical pack, confirm to add it again.',
);
const badCheckDigit = ApiException(
  kind: ApiErrorKind.validation,
  statusCode: 422,
  errorCode: 'POS_SCALE_LABEL_CHECK_DIGIT',
  message: 'The scale label failed its check digit (damaged or mistyped). Scan it again or enter the weight by hand.',
);

void main() {
  group('recognising a label', () {
    test('only an ACTIVE format\'s exact length and prefix — never "anything starting with 2"', () {
      expect(config.matches(label), isTrue);
      expect(config.matches('2212345012506'), isTrue);
      for (final c in [
        '2345',
        '23456789',
        '2112345012',
        '2312345012506',
        '21123450125066',
        '4006381333931',
      ]) {
        expect(config.matches(c), isFalse, reason: c);
      }
      expect(
        ScaleLabelConfig.none.matches(label),
        isFalse,
        reason: 'no format = no labels',
      );
    });

    test('formats JSON round trip; malformed entries are ignored', () {
      final c = ScaleLabelConfig.fromJson({
        'weight_sales_enabled': true,
        'formats': [
          {
            'id': 1,
            'barcode_length': 13,
            'prefixes': ['21'],
          },
          {'id': 2, 'barcode_length': 13, 'prefixes': []},
          {
            'id': null,
            'barcode_length': 12,
            'prefixes': ['2'],
          },
          'junk',
        ],
      });
      expect(c.formats.map((f) => f.id), [1]);
      expect(ScaleLabelConfig.fromJson(c.toJson()).matches(label), isTrue);
    });

    test('formats are loaded online (cached for maxAge), kept on failure, and restored offline after a restart', () async {
      var now = DateTime(2026, 10, 13, 9);
      final svc = FakeScaleLabels();
      Map<String, Object?>? saved;
      final r = ScaleLabelRecognizer(
        svc,
        save: (j) async => saved = j,
        clock: () => now,
      );
      expect(await r.matches(label, online: true), isTrue);
      expect(await r.matches(label, online: true), isTrue);
      expect(svc.loadCalls, 1, reason: 'cached');
      now = now.add(const Duration(minutes: 6));
      svc.loadError = const SocketException('down');
      expect(
        await r.matches(label, online: true),
        isTrue,
        reason: 'a failed refresh keeps the last formats',
      );
      expect(svc.loadCalls, 2);
      // A new install of the recognizer while OFFLINE: the saved copy is used.
      final offline = ScaleLabelRecognizer(
        FakeScaleLabels()..loadError = const SocketException('down'),
        restore: () async => saved,
      );
      expect(await offline.matches(label, online: false), isTrue);
      final nothingSaved = ScaleLabelRecognizer(
        FakeScaleLabels(),
        restore: () async => null,
      );
      expect(await nothingSaved.matches(label, online: false), isFalse);
    });
  });

  group('scan handler', () {
    late FakeCartService carts;
    late FakeScaleLabels svc;
    late CartController cart;
    late FakeProductService products;
    late BarcodeScanHandler handler;

    setUp(() {
      carts = FakeCartService();
      svc = FakeScaleLabels();
      cart = CartController(carts);
      products = FakeProductService();
      handler = BarcodeScanHandler(
        products: products,
        cart: cart,
        scaleLabels: ScaleLabelRecognizer(svc),
      );
    });
    tearDown(() => cart.dispose());

    test('a label goes to the server as a barcode only; the ordinary lookup is not used', () async {
      final r = await handler.handle(label);
      expect(r.outcome, ScanOutcome.added);
      expect(r.message, contains('1.250 kg × Loose Apples'));
      expect(products.barcodeCalls, isEmpty);
      expect(
        carts.addCalls,
        isEmpty,
        reason: 'never the ordinary add with a client quantity',
      );
      final call = svc.addCalls.single;
      expect(call.barcode, label);
      expect(call.confirmRepeat, isFalse);
      expect(cart.sale!.items.single.quantityMilli, 1250);
    });

    test(
      'an ordinary barcode (even one starting with 2) is unchanged',
      () async {
        products.onBarcode = (_) async => item(42);
        carts.onAdd = (c) async => CartSale.fromJson(
          saleJson(
            id: c.saleId,
            version: c.expectedVersion + 1,
            items: [lineJson(id: 1, variationId: 42)],
          ),
        )!;
        for (final code in ['4006381333931', '2345']) {
          await handler.handle(code);
        }
        expect(products.barcodeCalls, ['4006381333931', '2345']);
        expect(svc.addCalls, isEmpty);
        expect(svc.resolveCalls, isEmpty);
      },
    );

    test(
      'a refused label leaves the cart as it was — no empty sale is opened',
      () async {
        svc.resolveError = badCheckDigit;
        final r = await handler.handle(label);
        expect(r.outcome, ScanOutcome.error);
        expect(r.message, contains('check digit'));
        expect(carts.createCalls, 0, reason: 'no draft for a refused label');
        expect(svc.addCalls, isEmpty);
        expect(cart.sale, isNull);
      },
    );

    test('with an open sale a refusal changes nothing in it', () async {
      await handler.handle(label);
      final before = cart.sale!;
      svc.answers.add(badCheckDigit);
      final r = await handler.handle('2212345012506');
      expect(r.outcome, ScanOutcome.error);
      expect(
        identical(cart.sale, before) || cart.sale!.version == before.version,
        isTrue,
      );
      expect(cart.sale!.items, hasLength(1));
    });

    test('the same label twice: asks for confirmation; only a confirmed second pack is added', () async {
      await handler.handle(label);
      svc.answers.add(repeated);
      final r = await handler.handle(label);
      expect(r.outcome, ScanOutcome.confirmRepeat);
      expect(cart.error, isNull, reason: 'the question is not a cart error');
      final again = await handler.handle(label, confirmRepeat: true);
      expect(again.outcome, ScanOutcome.added);
      expect(svc.addCalls.map((c) => c.confirmRepeat), [false, false, true]);
    });

    test('offline: a label is refused clearly, nothing is sent, the cart is untouched', () async {
      final root = await Directory.systemTemp.createTemp('pos_scale_');
      addTearDown(() => root.delete(recursive: true));
      final offlineCart = CartController(
        carts,
        offline: OfflineCartSupport(
          checkout: OfflineCheckoutService(OfflineStorageService(root)),
          isOffline: () => true,
          scope: () => null,
        ),
      );
      addTearDown(offlineCart.dispose);
      final saved = config.toJson();
      final h = BarcodeScanHandler(
        products: products,
        cart: offlineCart,
        scaleLabels: ScaleLabelRecognizer(svc, restore: () async => saved),
      );
      final r = await h.handle(label);
      expect(r.outcome, ScanOutcome.error);
      expect(r.message, BarcodeScanHandler.scaleOfflineMessage);
      expect(svc.addCalls, isEmpty);
      expect(svc.resolveCalls, isEmpty);
      expect(svc.loadCalls, 0, reason: 'offline: no request at all');
      expect(
        products.barcodeCalls,
        isEmpty,
        reason: 'not looked up as an ordinary barcode',
      );
      expect(offlineCart.sale, isNull);
    });

    test(
      'offline storage keeps the formats (prefixes and lengths only)',
      () async {
        final root = await Directory.systemTemp.createTemp('pos_scale_store_');
        addTearDown(() => root.delete(recursive: true));
        final storage = OfflineStorageService(root);
        expect(await storage.getScaleLabelFormats(), isNull);
        await storage.saveScaleLabelFormats(config.toJson());
        final back = ScaleLabelConfig.fromJson(
          await storage.getScaleLabelFormats(),
        );
        expect(back.matches(label), isTrue);
      },
    );
  });

  group('products page', () {
    testWidgets(
      'scanned label: added with the server weight and price; repeat asks first; "Do not add" adds nothing',
      (tester) async {
        final h = PageHarness();
        final svc = FakeScaleLabels();
        h.scaleLabels = ScaleLabelRecognizer(svc);
        await pumpProductsPage(tester, h);
        await scan(tester, label);
        expect(
          find.textContaining('Added 1.250 kg × Loose Apples'),
          findsOneWidget,
        );
        expect(h.products.barcodeCalls, isEmpty);

        svc.answers.add(repeated);
        await scan(tester, label);
        expect(
          find.byKey(const Key('scale-label-repeat-dialog')),
          findsOneWidget,
        );
        await tester.tap(find.byKey(const Key('scale-label-repeat-cancel')));
        await tester.pumpAndSettle();
        expect(find.text('Not added again.'), findsOneWidget);
        expect(svc.addCalls, hasLength(2));

        svc.answers.add(repeated);
        await scan(tester, label);
        await tester.tap(find.byKey(const Key('scale-label-repeat-confirm')));
        await tester.pumpAndSettle();
        expect(svc.addCalls.last.confirmRepeat, isTrue);
        expect(svc.addCalls, hasLength(4));
      },
    );

    testWidgets(
      'without scale-label wiring every scan takes the ordinary path (unchanged)',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h);
        await scan(tester, label);
        expect(h.products.barcodeCalls, [label]);
        expect(
          find.text('No product found for barcode $label.'),
          findsOneWidget,
        );
      },
    );
  });
}
