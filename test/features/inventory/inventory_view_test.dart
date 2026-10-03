import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/inventory/models/inventory_adjustment.dart';
import 'package:buskit_pos/features/inventory/state/inventory_controller.dart';
import 'package:buskit_pos/features/inventory/ui/inventory_view.dart';
import 'package:buskit_pos/features/product_price/state/product_price_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

const netDown = ApiException(kind: ApiErrorKind.network, message: 'Cannot reach the server.');

ProductItem cola({double stock = 25}) =>
    ProductItem.fromJson(productJson(id: 1, name: 'Cola', stock: stock))!;

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
  Harness({double stock = 25}) {
    products.onSearch = (_) async => page([productJson(id: 1, name: 'Cola', stock: stock)]);
    products.onFindById = (_) async => cola(stock: inventory.stock.toDouble());
    inventory.stock = stock.round();
  }
  final products = FakeProductService();
  final inventory = FakeInventoryService();
  final prices = FakeProductPriceService();
  late InventoryController controller;
}

Future<Harness> pumpInventory(
  WidgetTester tester, {
  Harness? harness,
  SessionController? session,
}) async {
  final h = harness ?? Harness();
  h.controller = InventoryController(h.inventory, h.products);
  final priceController = ProductPriceController(h.prices);
  addTearDown(priceController.dispose);
  final sess = session ?? await sessionWith(null);
  tester.view.physicalSize = const Size(600, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(h.controller.dispose);
  addTearDown(sess.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<InventoryController>.value(value: h.controller),
        ChangeNotifierProvider<ProductPriceController>.value(value: priceController),
        ChangeNotifierProvider<SessionController>.value(value: sess),
      ],
      child: const MaterialApp(home: Scaffold(body: InventoryView())),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> openCola(WidgetTester tester) async {
  await tester.tap(find.text('Cola'));
  await tester.pumpAndSettle();
}

Future<void> fillForm(WidgetTester tester, {required String qty, required String reason}) async {
  await tester.enterText(inAlert(find.byType(TextField)).at(0), qty);
  await tester.enterText(inAlert(find.byType(TextField)).at(1), reason);
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

Future<void> adjustThrough(
  WidgetTester tester, {
  String action = 'Increase',
  String qty = '10',
  String reason = 'Physical stock count',
}) async {
  await tester.tap(find.text(action));
  await tester.pumpAndSettle();
  await fillForm(tester, qty: qty, reason: reason);
  await tester.tap(find.text('Confirm'));
  await tester.pumpAndSettle();
}

void main() {
  group('permission visibility', () {
    testWidgets('adjust actions shown when the loaded context grants inventory.adjust', (tester) async {
      await pumpInventory(tester, session: await sessionWith(['inventory.adjust', 'inventory.view']));
      await openCola(tester);
      expect(find.text('Increase'), findsOneWidget);
      expect(find.text('Decrease'), findsOneWidget);
    });

    testWidgets('adjust actions hidden without inventory.adjust, but stock stays visible', (tester) async {
      await pumpInventory(tester, session: await sessionWith(['sales.view']));
      await openCola(tester);
      expect(find.text('Increase'), findsNothing);
      expect(find.text('Decrease'), findsNothing);
      expect(find.text('Current stock'), findsOneWidget);
      expect(find.text('25'), findsOneWidget);
    });

    testWidgets('history hidden without inventory.view', (tester) async {
      await pumpInventory(tester, session: await sessionWith(['inventory.adjust']));
      await openCola(tester);
      expect(find.text('Recent adjustments'), findsNothing);
    });

    testWidgets('a missing permission context never hides anything (backend decides)', (tester) async {
      await pumpInventory(tester);
      await openCola(tester);
      expect(find.text('Increase'), findsOneWidget);
      expect(find.text('Recent adjustments'), findsOneWidget);
    });

    testWidgets('a staff switch never leaks the previous staff member\'s permission', (tester) async {
      final auth = FakeAuthService()
        ..onAuthContext = (t) async => const PosAuthContext(
          staff: StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Manager')),
          permissions: ['inventory.adjust'],
        );
      final session = SessionController(auth, MemoryTokenStore());
      await session.loginDevice('REG-1', 'secret');
      await session.loginStaff('S1', '1234');
      await pumpInventory(tester, session: session);
      await openCola(tester);
      expect(find.text('Increase'), findsOneWidget);

      session.logoutStaff();
      auth.onAuthContext = (t) async => const PosAuthContext(
        staff: StaffInfo(salesmanId: 'S2', role: StaffRole(id: 2, name: 'Cashier')),
        permissions: ['sales.view'],
      );
      await session.loginStaff('S2', '5678');
      await tester.pumpAndSettle();
      expect(find.text('Increase'), findsNothing);
    });
  });

  testWidgets('product search sends the query and shows current stock per result', (tester) async {
    final h = await pumpInventory(tester);
    expect(find.text('Cola'), findsOneWidget);
    expect(find.text('Stock 25'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'col');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(h.products.calls.last.query, 'col');
  });

  testWidgets('selecting a product shows its current stock', (tester) async {
    await pumpInventory(tester);
    await openCola(tester);
    expect(find.text('Current stock'), findsOneWidget);
    expect(find.text('25'), findsOneWidget);
  });

  group('form validation', () {
    testWidgets('blank/short reason and non-whole quantity are rejected before any request', (tester) async {
      final h = await pumpInventory(tester);
      await openCola(tester);
      await tester.tap(find.text('Increase'));
      await tester.pumpAndSettle();

      await fillForm(tester, qty: '2.5', reason: '  ');
      expect(find.text('Enter a whole number greater than 0'), findsOneWidget);
      expect(find.textContaining('Enter a reason'), findsOneWidget);

      await fillForm(tester, qty: '0', reason: 'ok reason');
      expect(find.text('Enter a whole number greater than 0'), findsOneWidget);
      expect(h.inventory.adjustCalls, isEmpty);
    });

    testWidgets('a decrease larger than current stock is caught locally', (tester) async {
      final h = await pumpInventory(tester);
      await openCola(tester);
      await tester.tap(find.text('Decrease'));
      await tester.pumpAndSettle();
      await fillForm(tester, qty: '30', reason: 'Damaged items');
      expect(find.textContaining('Cannot decrease below 0'), findsOneWidget);
      expect(h.inventory.adjustCalls, isEmpty);
    });
  });

  testWidgets('confirmation shows product, current, adjustment, new stock and reason; Cancel sends nothing', (tester) async {
    final h = await pumpInventory(tester);
    await openCola(tester);
    await tester.tap(find.text('Decrease'));
    await tester.pumpAndSettle();
    await fillForm(tester, qty: '3', reason: 'Damaged items');

    expect(find.text('Confirm inventory adjustment'), findsOneWidget);
    expect(inAlert(find.text('Cola')), findsOneWidget);
    expect(inAlert(find.text('25')), findsOneWidget);
    expect(inAlert(find.text('-3')), findsOneWidget);
    expect(inAlert(find.text('22')), findsOneWidget);
    expect(inAlert(find.text('Damaged items')), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.inventory.adjustCalls, isEmpty);
  });

  testWidgets('increase flow: sends the request, shows the success result, and refreshes stock', (tester) async {
    final h = await pumpInventory(tester);
    await openCola(tester);
    await adjustThrough(tester, action: 'Increase', qty: '10', reason: 'Physical stock count');

    expect(h.inventory.adjustCalls.single.direction, AdjustmentDirection.increase);
    expect(h.inventory.adjustCalls.single.quantity, '10');
    expect(find.text('Stock adjusted'), findsOneWidget);
    expect(inAlert(find.text('+10')), findsOneWidget);
    expect(inAlert(find.text('35')), findsOneWidget);

    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(h.products.idCalls, contains(1), reason: 'stock re-read from the server after adjusting');
    expect(find.text('35'), findsOneWidget);
  });

  testWidgets('decrease flow: sends the request and refreshes stock', (tester) async {
    final h = await pumpInventory(tester);
    await openCola(tester);
    await adjustThrough(tester, action: 'Decrease', qty: '4', reason: 'Damaged items');
    expect(h.inventory.adjustCalls.single.direction, AdjustmentDirection.decrease);
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('21'), findsOneWidget);
  });

  group('server errors', () {
    testWidgets('403 shows the permission-denied message', (tester) async {
      final h = Harness();
      h.inventory.onAdjust = (_) async => throw ApiException(
        kind: ApiErrorKind.forbidden,
        message: 'Forbidden',
        errorCode: PosErrorCodes.permissionDenied,
        data: const {'permission': 'inventory.adjust'},
      );
      await pumpInventory(tester, harness: h);
      await openCola(tester);
      await adjustThrough(tester);
      expect(find.textContaining('do not have permission to adjust inventory'), findsOneWidget);
    });

    testWidgets('422 insufficient stock shows the server figures and re-reads stock', (tester) async {
      final h = Harness();
      h.inventory.onAdjust = (_) async => throw ApiException.fromStatus(
        422,
        message: 'Not enough stock',
        errorCode: PosErrorCodes.insufficientStock,
        data: const {'current_stock': 2, 'requested': 3},
      );
      await pumpInventory(tester, harness: h);
      await openCola(tester);
      await adjustThrough(tester, action: 'Decrease', qty: '3', reason: 'Damaged items');
      expect(find.textContaining('only 2 available'), findsOneWidget);
      expect(h.products.idCalls, contains(1));
    });

    testWidgets('409 idempotency conflict is shown clearly', (tester) async {
      final h = Harness();
      h.inventory.onAdjust = (_) async => throw ApiException.fromStatus(
        409,
        message: 'Idempotency key reused with a different request',
      );
      await pumpInventory(tester, harness: h);
      await openCola(tester);
      await adjustThrough(tester);
      expect(find.text('Idempotency key reused with a different request'), findsOneWidget);
    });
  });

  group('controller idempotency', () {
    test('a retry of the SAME logical adjustment reuses the key; a changed one gets a new key', () async {
      final h = Harness();
      h.inventory.onAdjust = (_) async => throw netDown;
      final c = InventoryController(h.inventory, h.products);
      await c.select(cola(), loadHistory: false);

      await c.adjust(direction: AdjustmentDirection.decrease, quantity: '2', reason: 'Damaged');
      await c.adjust(direction: AdjustmentDirection.decrease, quantity: '2', reason: 'Damaged');
      expect(h.inventory.adjustCalls[0].key, h.inventory.adjustCalls[1].key);

      await c.adjust(direction: AdjustmentDirection.decrease, quantity: '3', reason: 'Damaged');
      expect(h.inventory.adjustCalls[2].key, isNot(h.inventory.adjustCalls[1].key));
      c.dispose();
    });

    test('after a success, the same adjustment again is a NEW request with a new key', () async {
      final h = Harness();
      final c = InventoryController(h.inventory, h.products);
      await c.select(cola(), loadHistory: false);
      await c.adjust(direction: AdjustmentDirection.increase, quantity: '1', reason: 'Recount');
      await c.adjust(direction: AdjustmentDirection.increase, quantity: '1', reason: 'Recount');
      expect(h.inventory.adjustCalls[0].key, isNot(h.inventory.adjustCalls[1].key));
      c.dispose();
    });

    test('double-submit while in flight is a no-op', () async {
      final h = Harness();
      final gate = Completer<InventoryAdjustment?>();
      h.inventory.onAdjust = (_) => gate.future;
      final c = InventoryController(h.inventory, h.products);
      await c.select(cola(), loadHistory: false);
      final first = c.adjust(direction: AdjustmentDirection.increase, quantity: '1', reason: 'Recount');
      expect(c.isAdjusting, isTrue);
      expect(await c.adjust(direction: AdjustmentDirection.increase, quantity: '1', reason: 'Recount'), isFalse);
      gate.complete(null);
      await first;
      expect(h.inventory.adjustCalls, hasLength(1));
      c.dispose();
    });
  });

  testWidgets('history lists adjustments newest-first and prepends a new one', (tester) async {
    final h = Harness();
    h.inventory.history = [
      InventoryAdjustment(
        id: 9,
        productVariationId: 1,
        direction: AdjustmentDirection.decrease,
        quantity: 2,
        previousQuantity: 27,
        resultingQuantity: 25,
        reason: 'Broken bottles',
        createdAt: DateTime(2026, 1, 1),
      ),
    ];
    await pumpInventory(tester, harness: h);
    await openCola(tester);
    expect(find.text('-2 → 25'), findsOneWidget);
    expect(find.textContaining('Broken bottles'), findsOneWidget);

    await adjustThrough(tester, action: 'Increase', qty: '5', reason: 'Recount');
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    final first = tester.widget<Text>(find.textContaining('→').first);
    expect(first.data, '+5 → 30');
  });
}
