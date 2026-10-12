// Phase 6X — an unpaid cart started OFFLINE is saved as a draft (drafts/,
// real JSON storage in a temporary directory) on every change BEFORE the
// change is shown, survives a restart with its stable local sale id, and is
// recorded as exactly ONE queued offline sale under that same id. Discard
// deletes the draft (nothing queued); storage failures keep the cart and
// never duplicate a sale; online carts never create a draft.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/offline/json_file_store.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const theScope = PosTokenScope(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, salesmanId: 'TEST-SALES-A1');
const otherStaff = PosTokenScope(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, salesmanId: 'TEST-SALES-A2');
const soap = OfflineProduct(productVariationId: 1, productName: 'Soap', sellingMode: 'PIECE', sellPriceMilli: 100000, taxPercent: 12, taxMode: 'exclusive');
const oil = OfflineProduct(productVariationId: 2, productName: 'Oil', sellingMode: 'PIECE', sellPriceMilli: 236000, taxPercent: 18, taxMode: 'inclusive');

late Directory root;
late OfflineStorageService storage;
late FakeCartService server;
bool offline = true;
PosTokenScope? scope = theScope;

CartController newCart() => CartController(
  server,
  offline: OfflineCartSupport(
    checkout: OfflineCheckoutService(storage),
    isOffline: () => offline,
    scope: () => scope,
    staffName: () => 'Asha',
  ),
);

/// A fresh process on the same device storage: new storage service, new cart.
Future<CartController> restart() async {
  storage = OfflineStorageService(root);
  await storage.initialize();
  return newCart();
}

List<String> files(String dir) {
  final d = Directory('${root.path}/$dir');
  if (!d.existsSync()) return const [];
  return d.listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => n.endsWith('.json')).toList()..sort();
}

Map<String, dynamic> readJson(String rel) => jsonDecode(File('${root.path}/$rel').readAsStringSync()) as Map<String, dynamic>;
/// The draft's sale data (inside the store's {schema_version, type, data} envelope).
Map<String, dynamic> draftJson(String id) => readJson('drafts/$id.json')['data'] as Map<String, dynamic>;
Future<void> chmod(String mode, String dir) async {
  await Directory('${root.path}/$dir').create(recursive: true);
  await Process.run('chmod', [mode, '${root.path}/$dir']);
}

PaymentLine cash(int amount) => PaymentLine(method: TenderMethod.cash, amountMilli: amount, tenderedMilli: amount);
int totalMilli(CartController c) => (c.sale!.totals.grandTotal! * 1000).round();

void main() {
  late CartController cart;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos_cart_draft_');
    storage = OfflineStorageService(root);
    await storage.initialize();
    await storage.saveCatalogue(OfflineCatalogue(companyId: 1, storeId: 213, cachedAt: DateTime.now().toUtc(), products: const [soap, oil]));
    await storage.saveInventory(
      InventorySnapshot(
        syncedAt: DateTime.utc(2026, 10, 6, 8),
        entries: const [InventorySnapshotEntry(productVariationId: 1, serverQuantity: 10), InventorySnapshotEntry(productVariationId: 2, serverQuantity: 5)],
      ),
    );
    await storage.saveCurrentShift(
      OfflineShiftContext(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, shiftId: 79, salesmanId: 'TEST-SALES-A1', openedAt: DateTime.utc(2026, 10, 6, 8), status: 'open', currency: 'INR'),
    );
    await storage.saveCustomers(const [OfflineCustomer(id: 11, customerId: 'CUST-11', fullname: 'Meera K', mobileno: '9000000011')]);
    server = FakeCartService();
    offline = true;
    scope = theScope;
    cart = newCart();
  });
  tearDown(() async {
    cart.dispose();
    await Process.run('chmod', ['-R', 'u+w', root.path]);
    await root.delete(recursive: true);
  });

  group('saving the unpaid cart', () {
    test('1. adding an item saves a DRAFT (drafts/, not sales/ or queue/) under one stable local sale id', () async {
      expect(await cart.addItem(1, 2), isTrue, reason: '${cart.error?.message}');
      final id = cart.localDraftId!;
      expect(OfflineSale.idPattern.hasMatch(id), isTrue);
      expect(files('drafts'), ['$id.json']);
      expect(files('sales'), isEmpty, reason: 'an unpaid cart is never a recorded sale');
      expect(files('queue'), isEmpty);
      final d = draftJson(id);
      expect(d['status'], 'DRAFT');
      expect(d['lines'], hasLength(1));
      expect([d['lines'][0]['product_variation_id'], d['lines'][0]['quantity'], d['lines'][0]['unit_price_milli']], [1, 2, 100000]);
      expect(d['payments'], isEmpty);
      expect([d['salesman_id'], d['store_id'], d['register_id'], d['shift_id']], ['TEST-SALES-A1', 213, 5, 79]);
      expect((await storage.getStockLevels())[1]!.availableQuantity, 10, reason: 'a draft never reserves stock');
      expect(await storage.getPendingSales(), isEmpty, reason: 'never synced');
    });

    test('2. quantity changes, a second item and removals update the SAME draft', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      await cart.addItem(2, 1);
      expect(await cart.updateQuantity(1, 3), isTrue);
      var lines = (draftJson(id)['lines'] as List).map((l) => [l['product_variation_id'], l['quantity']]).toList();
      expect(lines, [
        [1, 3],
        [2, 1],
      ]);
      expect(await cart.removeItem(2), isTrue);
      lines = (draftJson(id)['lines'] as List).map((l) => [l['product_variation_id'], l['quantity']]).toList();
      expect(lines, [
        [1, 3],
      ]);
      expect(cart.localDraftId, id, reason: 'the id never changes');
      expect(files('drafts'), ['$id.json']);
      // Removing the last line leaves nothing to recover: the draft goes.
      expect(await cart.removeItem(1), isTrue);
      expect(files('drafts'), isEmpty);
    });

    test('3. the customer chosen for the cart is saved with it', () async {
      expect(cart.setPendingCustomer('CUST-11', label: 'Meera K'), isTrue);
      await cart.addItem(1, 1);
      final d = draftJson(cart.localDraftId!);
      expect([d['customer_id'], d['customer_name']], ['CUST-11', 'Meera K']);
    });

    test('an unchanged quantity writes nothing', () async {
      await cart.addItem(1, 2);
      final id = cart.localDraftId!;
      final before = File('${root.path}/drafts/$id.json').readAsStringSync();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(await cart.updateQuantity(1, 2), isTrue);
      expect(File('${root.path}/drafts/$id.json').readAsStringSync(), before);
    });
  });

  group('restoring after a restart', () {
    test('4/5. a simulated process restart restores the cart with identical lines, customer and the SAME local sale id', () async {
      cart.setPendingCustomer('CUST-11', label: 'Meera K');
      await cart.addItem(1, 2);
      await cart.addItem(2, 1);
      final id = cart.localDraftId!;
      final shown = cart.sale!;
      cart.dispose();

      cart = await restart();
      expect(cart.sale, isNull, reason: 'nothing until restored');
      expect(await cart.restoreLocalDraft(), isTrue);
      expect(cart.isLocalSale, isTrue);
      expect(cart.localDraftId, id);
      expect(cart.customerId, 'CUST-11');
      final restored = cart.sale!;
      expect(
        restored.items.map((l) => [l.productVariationId, l.quantity, l.unitPrice, l.taxAmount, l.lineTotal, l.productName]).toList(),
        shown.items.map((l) => [l.productVariationId, l.quantity, l.unitPrice, l.taxAmount, l.lineTotal, l.productName]).toList(),
      );
      expect(restored.totals.grandTotal, shown.totals.grandTotal);
      expect(files('sales'), isEmpty);
    });

    test('only the signed-in cashier\'s own draft is restored; another cashier\'s stays untouched', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      cart.dispose();
      scope = otherStaff;
      cart = await restart();
      expect(await cart.restoreLocalDraft(), isFalse);
      expect(cart.sale, isNull);
      expect(files('drafts'), ['$id.json']);
      scope = theScope;
      cart.dispose();
      cart = await restart();
      expect(await cart.restoreLocalDraft(), isTrue);
      expect(cart.localDraftId, id);
    });

    test('restore never replaces a cart that is already open', () async {
      await cart.addItem(1, 1);
      expect(await cart.restoreLocalDraft(), isFalse);
      offline = false;
      final online = newCart();
      server.onAdd = (_) async => CartSaleFactory.sale(items: [lineJson(id: 1)], total: 1);
      await online.addItem(5, 1);
      expect(await online.restoreLocalDraft(), isFalse, reason: 'an online draft is open');
      online.dispose();
    });
  });

  group('checkout', () {
    test('6/7. completing a restored cart stores exactly ONE queued sale under the draft\'s id; the draft is removed after it', () async {
      await cart.addItem(1, 2);
      final id = cart.localDraftId!;
      cart.dispose();
      cart = await restart();
      await cart.restoreLocalDraft();
      expect(await cart.completeSale([cash(totalMilli(cart))]), isTrue, reason: '${cart.error?.message}');
      final saved = cart.completedOfflineSale!;
      expect(saved.localSaleId, id, reason: 'the same local sale id end to end');
      expect(saved.status, OfflineSaleStatus.queued);
      expect(files('sales'), ['$id.json']);
      expect(files('queue'), ['$id.json']);
      expect(files('drafts'), isEmpty);
      expect((await storage.getPendingSales()).map((s) => s.localSaleId).toList(), [id]);
      expect(saved.toSyncJson()['local_sale_id'], id, reason: 'the sync payload carries the same id');
    });

    test('7. a draft is only removed once the queued sale is stored: a refused checkout keeps it', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      expect(await cart.completeSale([cash(1)]), isFalse, reason: 'wrong total: refused, nothing written');
      expect(files('drafts'), ['$id.json']);
      expect(files('sales'), isEmpty);
      expect(cart.localDraftId, id, reason: 'still the same cart');
    });

    test('12. repeated checkout cannot create a second queued sale', () async {
      await cart.addItem(1, 1);
      final pay = [cash(totalMilli(cart))];
      final both = await Future.wait([cart.completeSale(pay), cart.completeSale(pay)]);
      expect(both.where((ok) => ok), hasLength(1), reason: 'the second press is ignored while the first runs');
      expect(await cart.completeSale(pay), isFalse, reason: 'the cart is empty afterwards');
      expect(files('sales'), hasLength(1));
      expect(files('queue'), hasLength(1));
      expect(files('drafts'), isEmpty);
    });
  });

  group('discard', () {
    test('8. a confirmed discard (cancelCurrent, called only after the UI confirmation) deletes the draft and queues nothing', () async {
      await cart.addItem(1, 2);
      expect(files('drafts'), hasLength(1));
      expect(await cart.cancelCurrent(), isTrue);
      expect(cart.sale, isNull);
      expect(files('drafts'), isEmpty);
      expect(files('sales'), isEmpty);
      expect(files('queue'), isEmpty);
      cart.dispose();
      cart = await restart();
      expect(await cart.restoreLocalDraft(), isFalse, reason: 'nothing comes back');
    });

    test('9. without a discard the draft stays exactly as it was', () async {
      await cart.addItem(1, 2);
      final id = cart.localDraftId!;
      final before = File('${root.path}/drafts/$id.json').readAsStringSync();
      cart.dispose();
      cart = await restart();
      expect(File('${root.path}/drafts/$id.json').readAsStringSync(), before);
    });
  });

  group('storage failures', () {
    test('10a. a draft that cannot be saved: the change is NOT made, the previous cart and draft are kept; a retry works', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      final before = File('${root.path}/drafts/$id.json').readAsStringSync();
      await chmod('555', 'drafts');
      expect(await cart.addItem(2, 1), isFalse);
      expect(cart.error?.message, CartController.draftSaveFailedMessage);
      expect(cart.sale!.items.map((l) => l.productVariationId).toList(), [1], reason: 'the change was not shown as done');
      expect(File('${root.path}/drafts/$id.json').readAsStringSync(), before);
      await chmod('755', 'drafts');
      expect(await cart.addItem(2, 1), isTrue);
      expect((draftJson(id)['lines'] as List), hasLength(2));
    });

    test('10b. checkout fails before the sale is written: draft and cart kept, editing allowed, a retry records ONE sale', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      await chmod('555', 'sales');
      expect(await cart.completeSale([cash(totalMilli(cart))]), isFalse);
      expect(cart.error?.message, OfflineCheckoutService.storageFailureMessage);
      expect(files('sales'), isEmpty);
      expect(files('drafts'), ['$id.json']);
      expect(await cart.updateQuantity(1, 2), isTrue, reason: 'nothing was recorded, so the cart can still change');
      await chmod('755', 'sales');
      expect(await cart.completeSale([cash(totalMilli(cart))]), isTrue, reason: '${cart.error?.message}');
      expect(files('sales'), ['$id.json']);
      expect(cart.completedOfflineSale!.lines.single.quantity, 2);
      expect(files('drafts'), isEmpty);
    });

    test('10c. checkout fails AFTER the sale was written (queue write failed): the cart is locked, the retry finishes the SAME sale — never a second one', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      final pay = [cash(totalMilli(cart))];
      await chmod('555', 'queue');
      expect(await cart.completeSale(pay), isFalse);
      expect(files('sales'), ['$id.json'], reason: 'the sale file was written before the failure');
      // Locked: no edit, no discard can contradict or duplicate the recorded sale.
      expect(await cart.addItem(2, 1), isFalse);
      expect(cart.error?.message, CartController.localSaleWrittenMessage);
      expect(await cart.updateQuantity(1, 3), isFalse);
      expect(await cart.cancelCurrent(), isFalse);
      expect(files('drafts'), ['$id.json'], reason: 'the draft stays until the queued sale is stored');
      await chmod('755', 'queue');
      expect(await cart.completeSale(pay), isTrue, reason: '${cart.error?.message}');
      expect(cart.completedOfflineSale!.localSaleId, id);
      expect(files('sales'), ['$id.json']);
      expect(files('queue'), ['$id.json']);
      expect(files('drafts'), isEmpty);
    });

    test('10d. the app stopped after the sale was stored but before the draft was deleted: the draft never comes back', () async {
      await cart.addItem(1, 1);
      final id = cart.localDraftId!;
      final keep = File('${root.path}/drafts/$id.json').readAsStringSync();
      expect(await cart.completeSale([cash(totalMilli(cart))]), isTrue);
      File('${root.path}/drafts/$id.json').writeAsStringSync(keep); // simulate the missed delete
      cart.dispose();
      cart = await restart();
      expect(await cart.restoreLocalDraft(), isFalse);
      expect(files('drafts'), isEmpty, reason: 'cleaned up: its id is a recorded sale');
      expect(files('sales'), ['$id.json']);
      final stale = OfflineSale.fromJson((jsonDecode(keep) as Map<String, dynamic>)['data'] as Map<String, dynamic>)!;
      await expectLater(storage.saveCartDraft(stale), throwsA(isA<OfflineStorageException>()), reason: 'a recorded sale\'s draft can never be written again');
      expect(files('drafts'), isEmpty);
    });
  });

  group('online carts are unaffected', () {
    test('11. an online cart (server draft) never writes a local draft', () async {
      offline = false;
      server.onAdd = (_) async => CartSaleFactory.sale(items: [lineJson(id: 1, name: 'Tea')], total: 112);
      expect(await cart.addItem(1, 1), isTrue);
      expect(cart.isLocalSale, isFalse);
      expect(cart.localDraftId, isNull);
      expect(files('drafts'), isEmpty);
      expect(await cart.restoreLocalDraft(), isFalse);
    });
  });
}
