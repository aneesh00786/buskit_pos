// Offline checkout through the REAL screens (products page -> cart -> pay
// modal -> success view, and the sales-history local list), with REAL JSON
// storage in a temporary directory. Real file I/O runs inside runAsync.
import 'dart:io';

import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/ui/offline_sale_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_page.dart';

const scope = PosTokenScope(
  companyId: 1,
  storeId: 213,
  registerId: 5,
  deviceId: 9,
  salesmanId: 'TEST-SALES-A1',
);

late Directory root;
late OfflineStorageService storage;

Future<void> seed() async {
  // Product 1 "Tea" — the product the harness lists — at 112.000 incl. 12%.
  await storage.saveCatalogue(
    OfflineCatalogue(
      companyId: 1,
      storeId: 213,
      // Phase 14G: refreshed just now (fresh for the real-clock checkout).
      cachedAt: DateTime.now().toUtc(),
      products: const [
        OfflineProduct(
          productVariationId: 1,
          productName: 'Tea',
          sellingMode: 'PIECE',
          sellPriceMilli: 112000,
          taxPercent: 12,
          taxMode: 'inclusive',
        ),
      ],
    ),
  );
  await storage.saveInventory(
    InventorySnapshot(
      syncedAt: DateTime.utc(2026, 10, 6),
      entries: const [
        InventorySnapshotEntry(productVariationId: 1, serverQuantity: 10),
      ],
    ),
  );
  await storage.saveCurrentShift(
    const OfflineShiftContext(
      companyId: 1,
      storeId: 213,
      registerId: 5,
      deviceId: 9,
      shiftId: 79,
      salesmanId: 'TEST-SALES-A1',
      status: 'open',
    ),
  );
}

/// Pumps the POS page offline with a local cart holding one Tea.
Future<PageHarness> pumpOfflineCart(WidgetTester tester) async {
  late PageHarness h;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('pos_offline_ui_');
    storage = OfflineStorageService(root);
    await storage.initialize();
    await seed();
  });
  addTearDown(() async {
    await Process.run('chmod', ['-R', 'u+w', root.path]);
    await root.delete(recursive: true);
  });
  h = PageHarness(offline: OfflineServices(storage))..offlineScope = scope;
  await pumpProductsPage(tester, h);
  h.client.reachable.value = false;
  await tester.pumpAndSettle();
  await tester.runAsync(() async {
    await tester.tap(find.text('Add').first);
    await settleIo(h);
  });
  await tester.pumpAndSettle();
  return harness = h;
}

late PageHarness harness;

/// Lets the real file I/O behind a cart operation finish (outside fake time).
Future<void> settleIo(PageHarness h) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  for (var i = 0; i < 250 && h.cart.isMutating; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

Future<void> payCash(WidgetTester tester, String amount) async {
  await tester.tap(find.text('Pay'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Amount tendered'),
    amount,
  );
  await tester.pump();
  final h = harness;
  await tester.runAsync(() async {
    await tester.tap(find.widgetWithText(FilledButton, 'Complete Sale'));
    await settleIo(h);
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'offline cash checkout: local cart notice, offline note, "Sale saved on this device." with the LOCAL reference — never "Synced" or a server number',
    (tester) async {
      final h = await pumpOfflineCart(tester);
      expect(h.cart.isLocalSale, isTrue);
      expect(find.byKey(const Key('local-cart-notice')), findsOneWidget);
      expect(h.carts.createCalls, 0, reason: 'no server draft offline');

      await tester.tap(find.text('Pay'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline-checkout-note')), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await payCash(tester, '200');
      expect(find.text(OfflineSaleSavedView.savedMessage), findsOneWidget);
      expect(find.text(OfflineSaleSavedView.notSyncedMessage), findsOneWidget);
      expect(find.textContaining('Offline Sale #LOCAL-'), findsOneWidget);
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Sale complete'), findsNothing);
      expect(find.text('Order'), findsNothing, reason: 'no server number');
      expect(find.text('Change due'), findsOneWidget);
      expect(find.text('88.00'), findsWidgets, reason: '200 - 112');
      expect(h.carts.completeCalls, isEmpty);

      final pending = await tester.runAsync(storage.getPendingSales);
      expect(pending!.single.payments.single.tenderedMilli, 200000);
      expect(pending.single.payments.single.changeMilli, 88000);

      await tester.tap(find.text('New Sale'));
      await tester.pumpAndSettle();
      expect(h.cart.sale, isNull);
      expect(h.cart.completedOfflineSale, isNull);
    },
  );

  testWidgets(
    'a storage failure shows the "do not leave this screen" error and keeps the cart',
    (tester) async {
      final h = await pumpOfflineCart(tester);
      await tester.runAsync(
        () => Process.run('chmod', ['555', '${root.path}/sales']),
      );
      await payCash(tester, '112');
      expect(
        find.textContaining('Unable to save the sale on this device'),
        findsOneWidget,
      );
      expect(find.text(OfflineSaleSavedView.savedMessage), findsNothing);
      expect(h.cart.sale!.items.single.quantity, 1);
      final files = await tester.runAsync(
        () => Directory('${root.path}/sales').list().toList(),
      );
      expect(files, isEmpty);
    },
  );

  testWidgets(
    'sales history shows sales saved on this device, clearly marked, with a detail view (no server id)',
    (tester) async {
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('pos_offline_hist_');
        storage = OfflineStorageService(root);
        await storage.initialize();
        await seed();
        await OfflineCheckoutService(storage).complete(
          OfflineCheckoutRequest(
            localSaleId: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
            scope: scope,
            staffName: 'Asha',
            lines: [
              OfflineCheckoutLine.fromProduct(
                (await storage.getProduct(1))!,
                2,
              ),
            ],
            payments: const [
              PaymentLine(
                method: TenderMethod.cash,
                amountMilli: 224000,
                tenderedMilli: 250000,
              ),
            ],
          ),
        );
      });
      addTearDown(() => root.delete(recursive: true));

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: LocalSalesSection(offline: OfflineServices(storage)),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('local-sales')), findsOneWidget);
      expect(
        find.textContaining('On this device — not yet synced (1)'),
        findsOneWidget,
      );
      expect(find.text('Offline Sale #LOCAL-3F2B8C1E'), findsOneWidget);
      expect(
        find.textContaining('Saved on this device — waiting to sync'),
        findsOneWidget,
      );

      await tester.tap(find.text('Offline Sale #LOCAL-3F2B8C1E'));
      await tester.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      Finder inDialog(Finder f) => find.descendant(of: dialog, matching: f);
      expect(inDialog(find.text('Tea')), findsOneWidget);
      expect(inDialog(find.textContaining('2 × 112.00')), findsOneWidget);
      expect(inDialog(find.text('Asha (TEST-SALES-A1)')), findsOneWidget);
      expect(inDialog(find.text('#79')), findsOneWidget);
      expect(inDialog(find.text('Cash')), findsOneWidget);
      expect(inDialog(find.text('26.00')), findsOneWidget, reason: 'change');
      expect(
        inDialog(find.text('Saved on this device — waiting to sync')),
        findsOneWidget,
      );
    },
  );
}
