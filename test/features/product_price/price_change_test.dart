import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/inventory/state/inventory_controller.dart';
import 'package:buskit_pos/features/inventory/ui/inventory_view.dart';
import 'package:buskit_pos/features/product_price/models/price_change.dart';
import 'package:buskit_pos/features/product_price/state/product_price_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

const netDown = ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server.');

/// The product as `GET /products/:id` would return it for the fake's
/// current price state.
Map<String, dynamic> colaJson(FakeProductPriceService prices) {
  final j = productJson(id: 1, name: 'Cola', price: prices.price, stock: 25);
  final pricing = Map<String, dynamic>.from(j['pricing'] as Map);
  pricing['catalogue_price'] = prices.cataloguePrice;
  pricing['price_source'] = prices.price == prices.cataloguePrice ? 'catalogue' : 'pos';
  pricing['price_version'] = prices.version;
  j['pricing'] = pricing;
  return j;
}

Finder inAlert(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

Future<SessionController> sessionWith(List<String>? permissions) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
      permissions: permissions,
    );
  }
  final s = SessionController(auth, MemoryTokenStore());
  await s.loginDevice('REG-1', 'secret');
  await s.loginStaff('S1', '1234');
  return s;
}

class Harness {
  Harness({double price = 25, double catalogue = 25}) {
    prices = FakeProductPriceService(price: price, cataloguePrice: catalogue);
    products.onSearch = (_) async => page([colaJson(prices)]);
    products.onFindById = (_) async => ProductItem.fromJson(colaJson(prices));
  }
  final products = FakeProductService();
  final inventory = FakeInventoryService();
  late final FakeProductPriceService prices;
  int catalogueRefreshes = 0;
  late InventoryController inv;
  late ProductPriceController priceCtrl;
}

Future<Harness> pumpPage(WidgetTester tester, {Harness? harness, SessionController? session}) async {
  final h = harness ?? Harness();
  h.inv = InventoryController(h.inventory, h.products);
  h.priceCtrl = ProductPriceController(
    h.prices,
    onPriceChanged: () async {
      await h.inv.refreshSelected();
      h.catalogueRefreshes++;
    },
  );
  final sess = session ?? await sessionWith(null);
  tester.view.physicalSize = const Size(600, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(h.inv.dispose);
  addTearDown(h.priceCtrl.dispose);
  addTearDown(sess.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<InventoryController>.value(value: h.inv),
        ChangeNotifierProvider<ProductPriceController>.value(value: h.priceCtrl),
        ChangeNotifierProvider<SessionController>.value(value: sess),
      ],
      child: const MaterialApp(home: Scaffold(body: InventoryView())),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('Cola'));
  await tester.pumpAndSettle();
  return h;
}

Future<void> openForm(WidgetTester tester) async {
  await tester.tap(find.text('Change price'));
  await tester.pumpAndSettle();
}

Future<void> fillForm(WidgetTester tester, String price, {String? reason}) async {
  await tester.enterText(inAlert(find.byType(TextField)).at(0), price);
  if (reason != null) await tester.enterText(inAlert(find.byType(TextField)).at(1), reason);
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

Future<void> changeThrough(WidgetTester tester, String price, {String? reason}) async {
  await openForm(tester);
  await fillForm(tester, price, reason: reason);
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

void main() {
  group('permission visibility', () {
    testWidgets('Change price shown when the loaded context grants products.price_change', (tester) async {
      await pumpPage(tester, session: await sessionWith(['products.price_change']));
      expect(find.text('Change price'), findsOneWidget);
      expect(find.text('Price history'), findsOneWidget);
    });

    testWidgets('hidden without the permission, but the price itself stays visible', (tester) async {
      final h = await pumpPage(tester, session: await sessionWith(['inventory.adjust']));
      expect(find.text('Change price'), findsNothing);
      expect(find.text('Price history'), findsNothing);
      expect(find.text('Selling price (POS)'), findsOneWidget);
      expect(find.text('25.00'), findsOneWidget);
      expect(h.prices.historyCalls, 0, reason: 'no history request when positively denied');
    });

    testWidgets('a missing permission context never hides the action (backend decides)', (tester) async {
      await pumpPage(tester);
      expect(find.text('Change price'), findsOneWidget);
    });

    testWidgets('a staff switch never leaks the previous staff member\'s permission', (tester) async {
      final auth = FakeAuthService()
        ..onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
          permissions: ['products.price_change'],
        );
      final session = SessionController(auth, MemoryTokenStore());
      await session.loginDevice('REG-1', 'secret');
      await session.loginStaff('S1', '1234');
      await pumpPage(tester, session: session);
      expect(find.text('Change price'), findsOneWidget);

      session.logoutStaff();
      auth.onAuthContext = (t) async => const PosAuthContext(
        staff: StaffInfo(salesmanId: 'S2', role: StaffRole(id: 2, name: 'Cashier')),
        permissions: ['sales.view'],
      );
      await session.loginStaff('S2', '5678');
      await tester.pumpAndSettle();
      expect(find.text('Change price'), findsNothing);
    });
  });

  group('form validation', () {
    testWidgets('zero, negative, malformed, over-precise and unchanged prices never reach the server', (tester) async {
      final h = await pumpPage(tester);
      await openForm(tester);
      for (final bad in ['0', '-5', 'abc', '10.1234', '25']) {
        await fillForm(tester, bad);
        expect(inAlert(find.byType(TextField)), findsWidgets, reason: 'form stays open for "$bad"');
      }
      expect(find.text('That is already the current price'), findsOneWidget);
      expect(h.prices.calls, isEmpty);
    });
  });

  testWidgets('confirmation shows old and new price; Cancel sends nothing', (tester) async {
    final h = await pumpPage(tester);
    await openForm(tester);
    await fillForm(tester, '30.5', reason: 'Supplier increase');
    expect(find.text('Confirm price change'), findsOneWidget);
    expect(inAlert(find.text('25.00')), findsOneWidget);
    expect(inAlert(find.text('30.50')), findsOneWidget);
    expect(inAlert(find.text('Supplier increase')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.prices.calls, isEmpty);
  });

  testWidgets('success: sends price + version, refreshes the product and the catalogue, shows feedback', (tester) async {
    final h = await pumpPage(tester);
    await changeThrough(tester, '30', reason: 'Supplier increase');

    final call = h.prices.calls.single;
    expect((call.action, call.productId, call.price, call.expectedVersion, call.reason), ('set', 1, '30', 0, 'Supplier increase'));
    expect(find.textContaining('Price updated to 30.00'), findsOneWidget);
    expect(h.catalogueRefreshes, 1);
    expect(h.products.idCalls, contains(1));
    expect(find.text('30.00'), findsWidgets);
    expect(find.text('POS price'), findsOneWidget);
    expect(find.textContaining('Catalogue price 25.00'), findsOneWidget);
    expect(find.text('25.00 → 30.00'), findsOneWidget, reason: 'new change prepended to history');
  });

  testWidgets('Use catalogue price resets the override', (tester) async {
    final h = await pumpPage(tester, harness: Harness(price: 40, catalogue: 25));
    expect(find.text('Use catalogue price'), findsOneWidget);
    await tester.tap(find.text('Use catalogue price'));
    await tester.pumpAndSettle();
    expect(find.text('Use catalogue price?'), findsOneWidget);
    await tester.tap(find.text('Confirm'));
    await tester.pumpAndSettle();
    expect(h.prices.calls.single.action, 'reset');
    expect(find.text('Use catalogue price'), findsNothing);
    expect(find.text('POS price'), findsNothing);
  });

  group('failed requests', () {
    testWidgets('403 shows the permission message', (tester) async {
      final h = Harness();
      h.prices.onChange = (_) async => throw ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'Forbidden',
        errorCode: PosErrorCodes.permissionDenied,
        data: const {'permission': 'products.price_change'},
      );
      await pumpPage(tester, harness: h);
      await changeThrough(tester, '30');
      expect(find.textContaining('do not have permission to change prices'), findsOneWidget);
      expect(h.catalogueRefreshes, 0);
    });

    testWidgets('409 stale version shows the server message and re-reads the current price', (tester) async {
      final h = Harness();
      h.prices.onChange = (_) async {
        h.prices.price = 27; // someone else changed it
        h.prices.version = 1;
        throw ApiException.fromStatus(
          409,
          message: 'The price was changed by someone else. Review the current price and try again.',
          errorCode: 'POS_PRICE_VERSION_CONFLICT',
          data: const {'current_version': 1},
        );
      };
      await pumpPage(tester, harness: h);
      await changeThrough(tester, '30');
      expect(find.textContaining('changed by someone else'), findsOneWidget);
      expect(find.text('27.00'), findsWidgets, reason: 'the fresh server price is shown after a conflict');
    });

    testWidgets('422 shows the validation message', (tester) async {
      final h = Harness();
      h.prices.onChange = (_) async => throw ApiException.fromStatus(422, message: 'price must be greater than 0');
      await pumpPage(tester, harness: h);
      await changeThrough(tester, '30');
      expect(find.text('price must be greater than 0'), findsOneWidget);
    });
  });

  group('controller', () {
    test('duplicate submit while in flight is a no-op', () async {
      final prices = FakeProductPriceService();
      final gate = Completer<ProductPriceState?>();
      prices.onChange = (_) => gate.future;
      final c = ProductPriceController(prices);
      final first = c.changePrice(productId: 1, expectedVersion: 0, price: '30');
      expect(c.isBusy, isTrue);
      expect(await c.changePrice(productId: 1, expectedVersion: 0, price: '30'), isFalse);
      gate.complete(null);
      await first;
      expect(prices.calls, hasLength(1));
      c.dispose();
    });

    test('a retry of the same change reuses the idempotency key; a different change gets a new one', () async {
      final prices = FakeProductPriceService()..onChange = (_) async => throw netDown;
      final c = ProductPriceController(prices);
      await c.changePrice(productId: 1, expectedVersion: 0, price: '30');
      await c.changePrice(productId: 1, expectedVersion: 0, price: '30');
      expect(prices.calls[0].key, prices.calls[1].key);
      await c.changePrice(productId: 1, expectedVersion: 0, price: '31');
      expect(prices.calls[2].key, isNot(prices.calls[1].key));
      c.dispose();
    });

    test('after a success, the same request again is a new attempt with a new key', () async {
      final prices = FakeProductPriceService();
      final c = ProductPriceController(prices);
      await c.changePrice(productId: 1, expectedVersion: 0, price: '30');
      await c.changePrice(productId: 1, expectedVersion: 0, price: '30');
      expect(prices.calls[0].key, isNot(prices.calls[1].key));
      c.dispose();
    });
  });

  test('ProductPricing parses the POS override fields', () {
    final j = productJson(id: 1, price: 30);
    (j['pricing'] as Map)
      ..['catalogue_price'] = 25
      ..['price_source'] = 'pos'
      ..['price_version'] = 3;
    final p = ProductItem.fromJson(j)!.pricing;
    expect((p.sellPrice, p.cataloguePrice, p.priceSource, p.priceVersion, p.hasPosOverride), (30.0, 25.0, 'pos', 3, true));
    final plain = ProductItem.fromJson(productJson(id: 2))!.pricing;
    expect((plain.priceVersion, plain.hasPosOverride), (0, false));
  });
}
