// Line discounts and per-sale price overrides in the app (backend migration
// 055). Fake server only. The server decides permission, limits and every
// amount; these tests check the app sends only intent, shows what the server
// returns, and handles refusals, conflicts, lost connections and offline.
import 'dart:async';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/cart/data/line_pricing_service.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/models/line_pricing.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/cart/ui/line_pricing_dialog.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

Map<String, dynamic> pricedLine({
  Map<String, dynamic>? discount,
  Map<String, dynamic>? override,
  double unitPrice = 10,
  double lineTotal = 11.2,
}) => {
  ...lineJson(
    id: 1,
    variationId: 42,
    unitPrice: unitPrice,
    lineTotal: lineTotal,
  ),
  'line_discount': ?discount,
  'price_override': ?override,
};

CartSale sale({
  int version = 2,
  Map<String, dynamic>? discount,
  Map<String, dynamic>? override,
  Map<String, dynamic>? merge,
}) => CartSale.fromJson({
  ...saleJson(
    id: 7,
    version: version,
    items: [pricedLine(discount: discount, override: override)],
    total: 11.2,
  ),
  'merge_notice': ?merge,
})!;

const tenPercent = {
  'discount_type': 'percentage',
  'discount_value': 10,
  'discount_amount': 1,
  'reason': 'dent',
  'applied_by': 'S1',
  'authority': 'discounts.override',
};
const priceChange = {
  'original_unit_price': 10,
  'unit_price': 8,
  'reason': 'price match',
  'applied_by': 'S1',
};

class Call {
  Call(this.op, this.args);
  final String op;
  final Map<String, Object?> args;
}

class FakeLinePricing implements LinePricingService {
  DiscountPolicy policy = const DiscountPolicy(
    lineDiscountAuthority: 'discounts.override',
    lineDiscountMaxPercent: 100,
    limitSource: 'override',
    canOverridePrice: true,
  );
  Object? policyError;
  int policyCalls = 0;
  final calls = <Call>[];
  Object? error;
  Completer<void>? hold;
  CartSale Function(Call c) answer = (c) => sale(
    version: (c.args['expectedVersion'] as int) + 1,
    discount: c.op == 'setDiscount' ? tenPercent : null,
    override: c.op == 'setPrice' ? priceChange : null,
  );

  Future<CartSale> _do(String op, Map<String, Object?> args) async {
    final c = Call(op, args);
    calls.add(c);
    if (hold != null) await hold!.future;
    if (error != null) throw error!;
    return answer(c);
  }

  @override
  Future<DiscountPolicy> loadPolicy() async {
    policyCalls++;
    if (policyError != null) throw policyError!;
    return policy;
  }

  @override
  Future<CartSale> setDiscount({
    required int saleId,
    required int itemId,
    required String type,
    required String value,
    required String reason,
    required int expectedVersion,
  }) => _do('setDiscount', {
    'saleId': saleId,
    'itemId': itemId,
    'type': type,
    'value': value,
    'reason': reason,
    'expectedVersion': expectedVersion,
  });
  @override
  Future<CartSale> removeDiscount({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) => _do('removeDiscount', {
    'saleId': saleId,
    'itemId': itemId,
    'expectedVersion': expectedVersion,
  });
  @override
  Future<CartSale> setPrice({
    required int saleId,
    required int itemId,
    required String unitPrice,
    required String reason,
    required int expectedVersion,
  }) => _do('setPrice', {
    'saleId': saleId,
    'itemId': itemId,
    'unitPrice': unitPrice,
    'reason': reason,
    'expectedVersion': expectedVersion,
  });
  @override
  Future<CartSale> removePrice({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) => _do('removePrice', {
    'saleId': saleId,
    'itemId': itemId,
    'expectedVersion': expectedVersion,
  });
}

const conflict = ApiException(
  kind: ApiErrorKind.conflict,
  statusCode: 409,
  message: 'Sale has been modified since you last read it',
  data: {'current_version': 5},
);
const notAllowed = ApiException(
  kind: ApiErrorKind.forbidden,
  statusCode: 403,
  errorCode: 'POS_LINE_DISCOUNT_OVER_LIMIT',
  message: 'This discount is above your limit of 5.00% of the line. A manager can apply it.',
);
const invalid = ApiException(
  kind: ApiErrorKind.validation,
  statusCode: 422,
  message: 'reason is required',
);
const lost = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

Future<CartController> cartWithLine(FakeCartService carts) async {
  carts.onAdd = (c) async => sale(version: c.expectedVersion + 1);
  final cart = CartController(carts);
  expect(await cart.addItem(42, 1), isTrue);
  return cart;
}

Future<CartSale> setTen(CartSale s, FakeLinePricing p) => p.setDiscount(
  saleId: s.id,
  itemId: 1,
  type: 'percentage',
  value: '10',
  reason: 'dent',
  expectedVersion: s.version,
);

void main() {
  group('models (the server contract)', () {
    test('line_discount / price_override parsed when present, absent otherwise; merge_notice; policy', () {
      final s = sale(
        discount: tenPercent,
        override: priceChange,
        merge: {
          'item_id': 1,
          'message': 'the overridden price applies to the added quantity',
        },
      );
      final l = s.items.single;
      expect(l.lineDiscount!.isPercentage, isTrue);
      expect(l.lineDiscount!.amount, 1);
      expect(l.priceOverride!.originalUnitPrice, 10);
      expect(l.priceOverride!.unitPrice, 8);
      expect(
        s.mergeNotice!.text,
        'Added to the existing line: the overridden price applies to the added quantity.',
      );
      final plain = sale().items.single;
      expect(plain.lineDiscount, isNull);
      expect(plain.priceOverride, isNull);
      expect(sale().mergeNotice, isNull);
      final p = DiscountPolicy.fromJson({
        'line_discount_authority': 'discounts.apply',
        'line_discount_max_percent': 5,
        'limit_source': 'role',
        'can_override_price': false,
      });
      expect(
        [p.canDiscount, p.canOverridePrice, p.lineDiscountMaxPercent],
        [true, false, 5],
      );
      expect(
        DiscountPolicy.fromJson({
          'line_discount_authority': 'discounts.apply',
          'line_discount_max_percent': 0,
        }).canDiscount,
        isFalse,
        reason: 'no limit = no discounts',
      );
      expect(DiscountPolicy.fromJson(null).canDiscount, isFalse);
    });

    test('input checks match what the server accepts (no NaN, infinity or negatives)', () {
      for (final ok in ['10', '12.5', '0.01', '100']) {
        expect(percentProblem(ok), isNull, reason: ok);
      }
      for (final bad in [
        '0',
        '101',
        '10.123',
        '-5',
        'abc',
        '',
        'NaN',
        'Infinity',
        '1e2',
      ]) {
        expect(percentProblem(bad), isNotNull, reason: bad);
      }
      for (final ok in ['5', '0.001', '12.345']) {
        expect(amountProblem(ok), isNull, reason: ok);
      }
      for (final bad in ['0', '-1', '1.2345', 'x', 'NaN', 'Infinity']) {
        expect(amountProblem(bad), isNotNull, reason: bad);
      }
    });
  });

  group('cart controller', () {
    late FakeCartService carts;
    late FakeLinePricing pricing;
    setUp(() {
      carts = FakeCartService();
      pricing = FakeLinePricing();
    });

    test('success: the server sale (and its new version) is shown; only intent is sent', () async {
      final cart = await cartWithLine(carts);
      final v = cart.sale!.version;
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isTrue,
      );
      expect(pricing.calls.single.args, {
        'saleId': 7,
        'itemId': 1,
        'type': 'percentage',
        'value': '10',
        'reason': 'dent',
        'expectedVersion': v,
      });
      expect(cart.sale!.version, v + 1);
      expect(cart.sale!.items.single.lineDiscount!.amount, 1);
      cart.dispose();
    });

    test('409: not retried; the cart is reloaded from the server and the cashier is told to review it', () async {
      final cart = await cartWithLine(carts);
      final gets = carts.getCalls;
      pricing.error = conflict;
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isFalse,
      );
      expect(
        pricing.calls,
        hasLength(1),
        reason: 'never retried automatically',
      );
      expect(carts.getCalls, gets + 1, reason: 'reloaded');
      expect(cart.error!.message, CartController.conflictMessage);
      cart.dispose();
    });

    test(
      '403 and 422: the server message, nothing changed, no retry',
      () async {
        final cart = await cartWithLine(carts);
        final before = cart.sale!.version;
        for (final e in [notAllowed, invalid]) {
          pricing.error = e;
          expect(
            await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
            isFalse,
          );
          expect(cart.error!.message, e.message);
        }
        expect(cart.sale!.version, before);
        expect(pricing.calls, hasLength(2));
        cart.dispose();
      },
    );

    test('lost connection: outcome unknown, further changes refused without a request until a reload succeeds', () async {
      final cart = await cartWithLine(carts);
      pricing.error = lost;
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isFalse,
      );
      expect(cart.linePricingOutcomeUnknown, isTrue);
      pricing.error = null;
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isFalse,
      );
      expect(
        pricing.calls,
        hasLength(1),
        reason: 'not submitted blind a second time',
      );
      expect(cart.error!.message, CartController.linePricingUnknownMessage);
      await cart.refresh();
      expect(cart.linePricingOutcomeUnknown, isFalse);
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isTrue,
      );
      cart.dispose();
    });

    test('no duplicate submission while one is in flight', () async {
      final cart = await cartWithLine(carts);
      pricing.hold = Completer<void>();
      final first = cart.changeLinePricing(1, (s) => setTen(s, pricing));
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isFalse,
      );
      pricing.hold!.complete();
      expect(await first, isTrue);
      expect(pricing.calls, hasLength(1));
      cart.dispose();
    });

    test('offline: refused locally with a clear message, never sent or queued, cart untouched', () async {
      final root = await Directory.systemTemp.createTemp('pos_lp_');
      addTearDown(() => root.delete(recursive: true));
      var offline = false;
      carts.onAdd = (c) async => sale(version: c.expectedVersion + 1);
      final cart = CartController(
        carts,
        offline: OfflineCartSupport(
          checkout: OfflineCheckoutService(OfflineStorageService(root)),
          isOffline: () => offline,
          scope: () => null,
        ),
      );
      addTearDown(cart.dispose);
      expect(await cart.addItem(42, 1), isTrue);
      final before = cart.sale;
      offline = true;
      expect(
        await cart.changeLinePricing(1, (s) => setTen(s, pricing)),
        isFalse,
      );
      expect(cart.error!.message, CartController.linePricingOfflineMessage);
      expect(pricing.calls, isEmpty);
      expect(identical(cart.sale, before), isTrue);
    });

    test('merge notice: shown once for the add that produced it; cleared by the next add', () async {
      var merged = true;
      carts.onAdd = (c) async => sale(
        version: c.expectedVersion + 1,
        merge: merged
            ? {
                'item_id': 1,
                'message':
                    'the fixed discount stays one amount for the whole line',
              }
            : null,
      );
      final cart = CartController(carts);
      expect(await cart.addItem(42, 1), isTrue);
      expect(cart.takeMergeNotice()!.message, contains('fixed discount'));
      expect(cart.takeMergeNotice(), isNull, reason: 'once');
      expect(await cart.addItem(42, 1), isTrue);
      merged = false;
      expect(await cart.addItem(42, 1), isTrue);
      expect(
        cart.takeMergeNotice(),
        isNull,
        reason: 'a later add without a notice shows none',
      );
      cart.dispose();
    });
  });

  group('cart line UI', () {
    Future<PageHarness> pump(
      WidgetTester tester,
      FakeLinePricing pricing, {
      CartSale? start,
      double width = 1400,
      List<String>? permissions,
      OfflineServices? offline,
    }) async {
      final h = PageHarness(offline: offline);
      h.linePricing = pricing;
      final s = start ?? sale();
      h.carts.onAdd = (_) async => s;
      h.carts.onGet = (_) async => s;
      if (permissions != null) {
        h.fakeAuth.onAuthContext = (t) async => PosAuthContext(
          staff: const StaffInfo(
            salesmanId: 'S1',
            role: StaffRole(id: 1, name: 'Any role'),
          ),
          permissions: permissions,
        );
        await h.signIn();
      }
      await pumpProductsPage(tester, h, width: width, height: 900);
      await tester.tap(find.text('Add').first);
      await tester.pumpAndSettle();
      if (width < 900) {
        await tester.tap(find.textContaining('Cart ·'));
        await tester.pumpAndSettle();
      }
      return h;
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('line-pricing-1')));
      await tester.pumpAndSettle();
    }

    testWidgets(
      'lost response while the server is now marked unreachable: the dialog offers Reload (not only the offline message) and Reload reconciles',
      (tester) async {
        late OfflineStorageService storage;
        late Directory root;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('pos_lp_unknown_');
          storage = OfflineStorageService(root);
          await storage.initialize();
        });
        addTearDown(() => root.delete(recursive: true));
        final p = FakeLinePricing()..error = lost;
        final h = await pump(tester, p, offline: OfflineServices(storage));
        var reloads = 0;
        h.carts.onGet = (_) async {
          reloads++;
          return sale(version: 9, discount: tenPercent);
        };
        await open(tester);
        await tester.enterText(find.byKey(const Key('line-discount-value')), '10');
        await tester.enterText(find.byKey(const Key('line-discount-reason')), 'dent');
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        // The real client marks itself unreachable on a network error.
        h.client.reachable.value = false;
        await tester.pumpAndSettle();
        expect(h.cart.linePricingOutcomeUnknown, isTrue);
        expect(find.byKey(const Key('line-pricing-unknown')), findsOneWidget);
        expect(find.byKey(const Key('line-pricing-offline')), findsNothing);
        expect(find.byKey(const Key('line-discount-apply')), findsNothing, reason: 'still blocked');
        expect(p.calls, hasLength(1), reason: 'never re-sent');
        await tester.tap(find.byKey(const Key('line-pricing-reload')));
        await tester.pumpAndSettle();
        expect(reloads, greaterThan(0), reason: 'Reload asks the server');
        expect(h.cart.linePricingOutcomeUnknown, isFalse);
        expect(p.calls, hasLength(1));
      },
    );

    testWidgets(
      'the action follows the server-provided permissions (any of apply / override / price_override), never a role name',
      (tester) async {
        await pump(
          tester,
          FakeLinePricing(),
          permissions: ['sales.view', 'sales.edit_current'],
        );
        expect(find.byKey(const Key('line-pricing-1')), findsNothing);
      },
    );

    testWidgets(
      'policy failure: actions unavailable with a clear message; Try again reloads it',
      (tester) async {
        final p = FakeLinePricing()..policyError = lost;
        await pump(tester, p, permissions: ['discounts.apply']);
        await open(tester);
        expect(
          find.byKey(const Key('line-pricing-policy-error')),
          findsOneWidget,
        );
        expect(find.byKey(const Key('line-discount-apply')), findsNothing);
        p.policyError = null;
        await tester.tap(find.byKey(const Key('line-pricing-policy-retry')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('line-discount-apply')), findsOneWidget);
        expect(p.policyCalls, 2);
      },
    );

    testWidgets(
      'no authority from the server: nothing offered even though the button is visible',
      (tester) async {
        final p = FakeLinePricing()
          ..policy = const DiscountPolicy(
            lineDiscountAuthority: 'discounts.apply',
            lineDiscountMaxPercent: 0,
          );
        await pump(tester, p);
        await open(tester);
        expect(find.byKey(const Key('line-pricing-none')), findsOneWidget);
        expect(find.byKey(const Key('line-discount-apply')), findsNothing);
        expect(find.byKey(const Key('line-price-apply')), findsNothing);
      },
    );

    testWidgets(
      'discount: limit shown; invalid value and missing reason stop it locally; valid sends intent and the tile shows the server result',
      (tester) async {
        final p = FakeLinePricing()
          ..policy = const DiscountPolicy(
            lineDiscountAuthority: 'discounts.apply',
            lineDiscountMaxPercent: 7.5,
            limitSource: 'individual',
          );
        await pump(tester, p);
        await open(tester);
        expect(
          find.textContaining('Your limit: 7.5% of the line'),
          findsOneWidget,
        );
        expect(
          find.byKey(const Key('line-price-apply')),
          findsNothing,
          reason: 'no sales.price_override',
        );
        await tester.enterText(
          find.byKey(const Key('line-discount-value')),
          '10.123',
        );
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('line-discount-error')), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('line-discount-value')),
          '5',
        );
        await tester.pump();
        expect(find.byKey(const Key('line-discount-estimate')), findsOneWidget);
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        await tester.pumpAndSettle();
        expect(find.text('A reason is required.'), findsOneWidget);
        expect(p.calls, isEmpty);
        await tester.enterText(
          find.byKey(const Key('line-discount-reason')),
          'dent',
        );
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        await tester.pumpAndSettle();
        expect(p.calls.single.op, 'setDiscount');
        expect(p.calls.single.args['value'], '5');
        expect(p.calls.single.args['reason'], 'dent');
        expect(
          find.byKey(const Key('line-pricing-dialog')),
          findsNothing,
          reason: 'closed after success',
        );
        expect(
          find.textContaining('Line discount 10%'),
          findsOneWidget,
          reason: 'the SERVER result, not the typed 5',
        );
      },
    );

    testWidgets(
      'server refusal (403) shown inside the dialog and the policy is asked again; 422 message shown',
      (tester) async {
        final p = FakeLinePricing()..error = notAllowed;
        await pump(tester, p);
        await open(tester);
        await tester.enterText(
          find.byKey(const Key('line-discount-value')),
          '50',
        );
        await tester.enterText(
          find.byKey(const Key('line-discount-reason')),
          'x',
        );
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('line-pricing-dialog')),
            matching: find.text(notAllowed.message),
          ),
          findsOneWidget,
        );
        expect(p.policyCalls, 2);
        p.error = invalid;
        await tester.tap(find.byKey(const Key('line-discount-apply')));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byKey(const Key('line-pricing-dialog')),
            matching: find.text('reason is required'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'price override: only with the permission, "this sale only" note, reason required; remove asks first',
      (tester) async {
        final p = FakeLinePricing();
        await pump(tester, p);
        await open(tester);
        expect(
          find.textContaining('the catalogue price is not changed'),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byKey(const Key('line-price-value')));
        await tester.enterText(find.byKey(const Key('line-price-value')), '8');
        await tester.tap(find.byKey(const Key('line-price-apply')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('line-price-error')),
          findsOneWidget,
          reason: 'reason required',
        );
        await tester.enterText(
          find.byKey(const Key('line-price-reason')),
          'price match',
        );
        await tester.tap(find.byKey(const Key('line-price-apply')));
        await tester.pumpAndSettle();
        expect(p.calls.single.args['unitPrice'], '8');
        expect(find.textContaining('Price for this sale'), findsOneWidget);
        await open(tester);
        expect(
          find.byKey(const Key('line-pricing-current-override')),
          findsOneWidget,
        );
        await tester.ensureVisible(find.byKey(const Key('line-price-remove')));
        await tester.tap(find.byKey(const Key('line-price-remove')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(p.calls, hasLength(1), reason: 'cancelled: nothing sent');
      },
    );

    testWidgets('phone width (390 px): the dialog fits without overflow', (
      tester,
    ) async {
      await pump(
        tester,
        FakeLinePricing(),
        width: 390,
        start: sale(discount: tenPercent, override: priceChange),
      );
      await open(tester);
      expect(find.byKey(const Key('line-pricing-dialog')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('merge notice is shown with the add confirmation', (
      tester,
    ) async {
      final h = PageHarness();
      h.carts.onAdd = (_) async => sale(
        merge: {
          'item_id': 1,
          'message': 'the percentage discount applies to the added quantity',
        },
      );
      await pumpProductsPage(tester, h);
      await tester.tap(find.text('Add').first);
      await tester.pump();
      expect(
        find.textContaining(
          'Added to the existing line: the percentage discount applies to the added quantity',
        ),
        findsOneWidget,
      );
    });
  });

  group('receipts', () {
    CompletedSale completed({
      Map<String, dynamic>? discount,
      Map<String, dynamic>? override,
    }) => CompletedSale.fromJson({
      ...saleJson(
        id: 9,
        status: 'completed',
        items: [
          {
            ...lineJson(
              id: 1,
              unitPrice: 150,
              lineTotal: 302.4,
              tax: 32.4,
              quantity: 2,
            ),
            'discount_amount': 30,
            'line_discount': ?discount,
            'price_override': ?override,
          },
        ],
        subtotal: 300,
        discount: 30,
        tax: 32.4,
        total: 302.4,
      ),
      'sale_number': 'S-9',
      'payments': [],
    })!;

    test('the stored original price and line discount are printed under the line; amounts are the stored ones', () {
      final lines = ReceiptFormatter.build(
        sale: completed(
          discount: {
            'discount_type': 'percentage',
            'discount_value': 10,
            'discount_amount': 30,
            'reason': 'dent',
            'applied_by': 'S1',
          },
          override: {
            'original_unit_price': 200,
            'unit_price': 150,
            'reason': 'price match',
            'applied_by': 'S1',
          },
        ),
        names: const {1: 'Apples'},
      ).toLines(columns: 42);
      final i = lines.indexWhere((l) => l.contains('2 x 150.00'));
      expect(lines[i], endsWith('302.40'));
      expect(lines[i + 1].trim(), 'Price changed from 200.00');
      expect(lines[i + 2], startsWith('  Line discount 10%'));
      expect(lines[i + 2], endsWith('-30.00'));
      expect(
        lines.join('\n'),
        isNot(contains('price match')),
        reason: 'reasons are not printed on receipts',
      );
    });

    test('ordinary sales print exactly as before (no extra lines)', () {
      final plain = ReceiptFormatter.build(
        sale: completed(),
        names: const {1: 'Apples'},
      ).toLines(columns: 42);
      final i = plain.indexWhere((l) => l.contains('2 x 150.00'));
      expect(
        plain[i + 1],
        startsWith('-'),
        reason: 'the rule follows straight after the item',
      );
      expect(
        plain.where(
          (l) => l.contains('Line discount') || l.contains('Price changed'),
        ),
        isEmpty,
      );
    });
  });
}
