// Phase 6X — the unpaid offline cart through the REAL screens (products page
// + cart panel), with REAL JSON storage in a temporary directory: a restart
// (a new page and controller on the same device storage) brings the cart back
// automatically; the existing "Void sale" confirmation guards the discard —
// "Keep sale" leaves the saved cart untouched, "Void sale" deletes it and
// nothing is queued. Real file I/O runs inside runAsync.
import 'dart:io';

import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_page.dart';

const scope = PosTokenScope(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, salesmanId: 'TEST-SALES-A1');

late Directory root;

Future<void> seed(OfflineStorageService storage) async {
  await storage.saveCatalogue(
    OfflineCatalogue(
      companyId: 1,
      storeId: 213,
      cachedAt: DateTime.now().toUtc(),
      products: const [OfflineProduct(productVariationId: 1, productName: 'Tea', sellingMode: 'PIECE', sellPriceMilli: 112000, taxPercent: 12, taxMode: 'inclusive')],
    ),
  );
  await storage.saveInventory(InventorySnapshot(syncedAt: DateTime.utc(2026, 10, 6), entries: const [InventorySnapshotEntry(productVariationId: 1, serverQuantity: 10)]));
  await storage.saveCurrentShift(
    const OfflineShiftContext(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, shiftId: 79, salesmanId: 'TEST-SALES-A1', status: 'open'),
  );
}

/// Lets the real file I/O behind a cart operation finish (outside fake time).
Future<void> settleIo(PageHarness h) async {
  await Future<void>.delayed(const Duration(milliseconds: 20));
  for (var i = 0; i < 250 && h.cart.isMutating; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

/// Real file I/O started from widget code completes on the real event loop;
/// its continuations then need frames. Alternate the two until it is done.
Future<void> pumpIo(WidgetTester tester, {int rounds = 30}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

/// One "app run": a new storage service, harness, controller and page on the
/// SAME device folder, offline.
Future<PageHarness> launch(WidgetTester tester) async {
  late OfflineStorageService storage;
  await tester.runAsync(() async {
    storage = OfflineStorageService(root);
    await storage.initialize();
  });
  final h = PageHarness(offline: OfflineServices(storage))..offlineScope = scope;
  h.client.reachable.value = false;
  await pumpProductsPage(tester, h);
  await pumpIo(tester); // the start-up restore reads the device folder
  await tester.pumpAndSettle();
  return h;
}

List<String> files(String dir) {
  final d = Directory('${root.path}/$dir');
  if (!d.existsSync()) return const [];
  return d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => n.endsWith('.json')).toList();
}

Future<PageHarness> startWithCart(WidgetTester tester) async {
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('pos_cart_draft_ui_');
    final s = OfflineStorageService(root);
    await s.initialize();
    await seed(s);
  });
  addTearDown(() async {
    await Process.run('chmod', ['-R', 'u+w', root.path]);
    await root.delete(recursive: true);
  });
  final h = await launch(tester);
  await tester.runAsync(() async {
    await tester.tap(find.text('Add').first);
    await settleIo(h);
  });
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets('a restart brings the unpaid offline cart back on its own, with the same local sale id', (tester) async {
    final first = await startWithCart(tester);
    expect(first.cart.isLocalSale, isTrue);
    final id = first.cart.localDraftId!;
    expect(files('drafts'), ['$id.json']);

    // "Process restart": a brand-new page/controller on the same device storage.
    await tester.pumpWidget(const SizedBox());
    final second = await launch(tester);
    expect(second.cart.isLocalSale, isTrue, reason: 'restored at start-up');
    expect(second.cart.localDraftId, id);
    expect(second.cart.sale!.items.single.productName, 'Tea');
    expect(find.byKey(const Key('local-cart-notice')), findsOneWidget);
    expect(second.carts.createCalls, 0, reason: 'nothing is sent to the server');
  });

  testWidgets('"Void sale" asks first: "Keep sale" leaves the saved cart untouched', (tester) async {
    final h = await startWithCart(tester);
    final id = h.cart.localDraftId!;
    final before = await tester.runAsync(() => File('${root.path}/drafts/$id.json').readAsString());
    await tester.tap(find.text('Void sale'));
    await tester.pumpAndSettle();
    expect(find.text('Void this sale?'), findsOneWidget);
    await tester.tap(find.text('Keep sale'));
    await tester.pumpAndSettle();
    expect(h.cart.isLocalSale, isTrue);
    expect(h.cart.localDraftId, id);
    expect(await tester.runAsync(() => File('${root.path}/drafts/$id.json').readAsString()), before);
  });

  testWidgets('confirmed "Void sale" deletes the saved cart and queues nothing; a restart restores nothing', (tester) async {
    final h = await startWithCart(tester);
    await tester.tap(find.text('Void sale'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Void sale').last);
    await pumpIo(tester);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
    expect(h.cart.sale, isNull);
    expect(files('drafts'), isEmpty);
    expect(files('sales'), isEmpty);
    expect(files('queue'), isEmpty);
    await tester.pumpWidget(const SizedBox());
    final again = await launch(tester);
    expect(again.cart.sale, isNull);
  });

  testWidgets('a cart change that cannot be saved is not made, and the cashier is told', (tester) async {
    final h = await startWithCart(tester);
    await tester.runAsync(() => Process.run('chmod', ['555', '${root.path}/drafts']));
    await tester.tap(find.text('Add').first);
    await pumpIo(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('The cart could not be saved on this device'), findsWidgets);
    expect(h.cart.sale!.items.single.quantity, 1, reason: 'still the saved cart');
    await tester.pump(const Duration(seconds: 5)); // let any message time out
    await tester.pumpAndSettle();
  });
}
