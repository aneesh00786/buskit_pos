// Phase 6S — POS_DRAFT_SYNCED_OFFLINE (backend Phase 6R): completing an
// online draft is refused because its cart is already recorded as a synced
// offline sale. CartController level, with REAL offline storage (temp dir):
// recognised only for that code, never retried (online or offline), the
// offline sale and queue untouched, keys unchanged, and the duplicate draft
// cancelled only through the existing cancel flow — an unknown cancel outcome
// is reconciled with the server before the draft is shown as cancelled.
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const scope = PosTokenScope(companyId: 1, storeId: 213, registerId: 5, deviceId: 9, salesmanId: 'TEST-SALES-A1');
const soap = OfflineProduct(
  productVariationId: 1,
  productName: 'Soap',
  sellingMode: 'PIECE',
  sellPriceMilli: 100000,
  taxPercent: 12,
  taxMode: 'exclusive',
);
const pay224 = PaymentLine(method: TenderMethod.cash, amountMilli: 224000, tenderedMilli: 224000);

ApiException syncedOffline() => apiError(
  409,
  message: 'This cart was already recorded as an offline sale. Cancel this draft instead of completing it.',
  code: PosErrorCodes.draftSyncedOffline,
  data: {'server_sale_id': 901},
);

/// The server draft (id 7) the cart was built in: soap x2 = 224.000.
CartSale serverDraft({int version = 3, String status = 'draft'}) => CartSale.fromJson({
  ...saleJson(
    id: 7,
    version: version,
    status: status,
    items: [lineJson(id: 501, variationId: 1, quantity: 2, name: 'Soap', unitPrice: 100, tax: 24, taxPercent: 12, lineTotal: 224)],
    subtotal: 200,
    tax: 24,
    total: 224,
  ),
  'shift_id': 79,
  'store_id': 213,
  'register_id': 5,
})!;

late Directory root;
late OfflineStorageService storage;
late FakeCartService server;
late CartController cart;
bool offline = false;

/// Every file the offline storage holds, with its exact bytes.
Map<String, String> storageSnapshot() => {
  for (final f in root.listSync(recursive: true).whereType<File>())
    f.path.substring(root.path.length): f.readAsStringSync(),
};

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos_draft_synced_offline_');
    storage = OfflineStorageService(root);
    await storage.initialize();
    await storage.saveCatalogue(
      OfflineCatalogue(companyId: 1, storeId: 213, cachedAt: DateTime.now().toUtc(), products: const [soap]),
    );
    await storage.saveInventory(
      InventorySnapshot(
        syncedAt: DateTime.utc(2026, 10, 6, 8),
        entries: const [InventorySnapshotEntry(productVariationId: 1, serverQuantity: 10)],
      ),
    );
    await storage.saveCurrentShift(
      OfflineShiftContext(
        companyId: 1,
        storeId: 213,
        registerId: 5,
        deviceId: 9,
        shiftId: 79,
        salesmanId: 'TEST-SALES-A1',
        openedAt: DateTime.utc(2026, 10, 6, 8),
        status: 'open',
        currency: 'INR',
      ),
    );
    server = FakeCartService();
    server.onGet = (_) async => serverDraft();
    offline = false;
    cart = CartController(
      server,
      offline: OfflineCartSupport(
        checkout: OfflineCheckoutService(storage),
        isOffline: () => offline,
        scope: () => scope,
        staffName: () => 'Asha',
      ),
    );
  });
  tearDown(() async {
    cart.dispose();
    await root.delete(recursive: true);
  });

  /// The cart of draft 7 was paid while offline: one offline sale recorded
  /// (its source draft is 7). Returns its local id.
  Future<String> recordOfflineSaleFromDraft() async {
    offline = true;
    expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
    expect(await cart.completeSale([pay224]), isTrue, reason: '${cart.error?.message}');
    final local = cart.completedOfflineSale!;
    expect(local.sourceDraftSaleId, 7);
    cart.acknowledgeOfflineCompletion();
    offline = false;
    return local.localSaleId;
  }

  group('recognising the conflict', () {
    test('only HTTP 409 with POS_DRAFT_SYNCED_OFFLINE is this conflict', () {
      expect(isDraftSyncedOffline(syncedOffline()), isTrue);
      expect(syncedOffline().isRetryable, isFalse, reason: 'a permanent business conflict');
      expect(isDraftSyncedOffline(apiError(409, message: 'Sale has been modified', data: {'current_version': 9})), isFalse);
      expect(isDraftSyncedOffline(apiError(409, code: PosErrorCodes.insufficientStock)), isFalse);
      expect(isDraftSyncedOffline(apiError(422, code: PosErrorCodes.draftSyncedOffline)), isFalse);
      expect(isDraftSyncedOffline(const ApiException(kind: ApiErrorKind.timeout, message: 't')), isFalse);
      expect(describeApiError(syncedOffline()), contains('already been recorded through offline sync'));
    });
  });

  group('completing a draft whose cart is already a synced offline sale', () {
    test('never retried online or offline; the offline sale, queue and keys are untouched', () async {
      final localId = await recordOfflineSaleFromDraft();
      final stored = storageSnapshot();
      expect(stored.values.any((c) => c.contains(localId)), isTrue, reason: 'the offline sale is stored');

      // The draft comes back (payment recovery) and is paid online.
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw syncedOffline();
      expect(await cart.completeSale([pay224]), isFalse);
      expect(server.completeCalls, hasLength(1));
      final key = server.completeCalls.single.key;
      expect(cart.draftSyncedOffline, isTrue);
      expect(cart.error?.message, draftSyncedOfflineMessage);
      expect(cart.error?.isRetryable, isFalse);
      expect(cart.sale?.id, 7, reason: 'the draft stays open (recoverable)');
      expect(cart.currentIdempotencyKey, key, reason: 'the key is kept, never regenerated');

      // A second press is refused locally: no request at all.
      expect(await cart.completeSale([pay224]), isFalse);
      expect(server.completeCalls, hasLength(1), reason: 'never re-sent');
      expect(cart.error?.message, draftSyncedOfflineMessage);

      // The connection drops: it is NOT recorded as a second offline sale.
      offline = true;
      expect(await cart.completeSale([pay224]), isFalse);
      expect(cart.completedOfflineSale, isNull);
      offline = false;

      expect(storageSnapshot(), stored, reason: 'offline sale, queue and local id unchanged, nothing new queued');
      expect(cart.currentIdempotencyKey, key);
    });

    test('confirmed cancellation goes through the existing cancel; only the draft is cancelled', () async {
      await recordOfflineSaleFromDraft();
      final stored = storageSnapshot();
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw syncedOffline();
      await cart.completeSale([pay224]);

      expect(await cart.cancelDuplicateDraft(), isTrue);
      expect(server.cancelCalls.map((c) => [c.saleId, c.expectedVersion]).toList(), [
        [7, 3],
      ]);
      expect(cart.sale, isNull);
      expect(cart.lastCancelledSaleId, 7);
      expect(cart.draftSyncedOffline, isFalse);
      expect(server.completeCalls, hasLength(1));
      expect(storageSnapshot(), stored, reason: 'the synced offline sale is never touched');
    });

    test('a refused cancellation leaves the draft open and still blocked', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw syncedOffline();
      await cart.completeSale([pay224]);
      server.onCancel = (_) async => throw apiError(409, message: 'This sale has a provider payment in progress or captured');
      final gets = server.getCalls;

      expect(await cart.cancelDuplicateDraft(), isFalse);
      expect(cart.sale?.id, 7);
      expect(cart.sale?.isDraft, isTrue);
      expect(cart.draftSyncedOffline, isTrue);
      expect(cart.errorOperation, CartOperation.cancel);
      expect(cart.error?.message, CartController.cancelNotAllowedMessage);
      expect(server.getCalls, gets + 1, reason: 'the existing conflict reload, no extra reconciliation');
      expect(await cart.completeSale([pay224]), isFalse);
      expect(server.completeCalls, hasLength(1));
    });

    test('an unknown cancel outcome is reconciled: shown cancelled ONLY when the server says so', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw syncedOffline();
      await cart.completeSale([pay224]);
      server.onCancel = (_) async => throw const ApiException(kind: ApiErrorKind.timeout, message: 'timeout');

      // 1. the server still has it as a draft -> stays open, can be retried
      server.onGet = (_) async => serverDraft();
      expect(await cart.cancelDuplicateDraft(), isFalse);
      expect(cart.sale?.isDraft, isTrue);
      expect(cart.draftSyncedOffline, isTrue);
      expect(cart.error?.message, CartController.duplicateDraftCancelUnconfirmedMessage);

      // 2. the server cannot be read either -> still open (never assumed cancelled)
      server.onGet = (_) async => throw const ApiException(kind: ApiErrorKind.network, message: 'offline');
      expect(await cart.cancelDuplicateDraft(), isFalse);
      expect(cart.sale?.id, 7);
      expect(cart.draftSyncedOffline, isTrue);

      // 3. the cancel did reach the server -> reconciled as cancelled
      server.onGet = (_) async => serverDraft(version: 4, status: 'canceled');
      expect(await cart.cancelDuplicateDraft(), isTrue);
      expect(cart.sale, isNull);
      expect(cart.lastCancelledSaleId, 7);
      expect(cart.error, isNull);
      expect(server.cancelCalls, hasLength(3));
      expect(server.completeCalls, hasLength(1));
    });

    test('cancelDuplicateDraft does nothing for a draft that was not refused this way', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      expect(await cart.cancelDuplicateDraft(), isFalse);
      expect(server.cancelCalls, isEmpty);
    });
  });

  group('other failures keep their existing behaviour', () {
    test('a timeout keeps the same key and allows the existing manual retry', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw const ApiException(kind: ApiErrorKind.timeout, message: 'timeout');
      expect(await cart.completeSale([pay224]), isFalse);
      expect(cart.draftSyncedOffline, isFalse);
      expect(cart.error?.isRetryable, isTrue);
      final key = server.completeCalls.single.key;
      server.onComplete = (c) async => CompletedSale.fromJson(completedJson(id: c.saleId, payments: c.payments))!;
      expect(await cart.completeSale([pay224]), isTrue);
      expect(server.completeCalls.map((c) => c.key).toList(), [key, key]);
    });

    test('a 5xx stays a transient error with the same key', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw apiError(500, message: 'boom');
      expect(await cart.completeSale([pay224]), isFalse);
      expect(cart.draftSyncedOffline, isFalse);
      expect(cart.error?.isRetryable, isTrue);
      expect(cart.hasPendingCompletion, isTrue);
    });

    test('a version-conflict 409 keeps its message and does not block the draft', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw apiError(409, message: 'Sale has been modified', data: {'current_version': 4});
      server.onGet = (_) async => serverDraft(version: 4);
      expect(await cart.completeSale([pay224]), isFalse);
      expect(cart.draftSyncedOffline, isFalse);
      expect(cart.error?.message, CartController.conflictMessage);
      server.onComplete = (c) async => CompletedSale.fromJson(completedJson(id: c.saleId, payments: c.payments))!;
      expect(await cart.completeSale([pay224]), isTrue, reason: 'completing again is still possible');
      expect(server.completeCalls, hasLength(2));
    });

    test('another 409 (insufficient stock) is not mistaken for this conflict', () async {
      expect(cart.restoreRecoveredSale(serverDraft()), isTrue);
      server.onComplete = (_) async => throw apiError(409, message: 'Insufficient stock', code: PosErrorCodes.insufficientStock);
      expect(await cart.completeSale([pay224]), isFalse);
      expect(cart.draftSyncedOffline, isFalse);
      expect(cart.error?.errorCode, PosErrorCodes.insufficientStock);
    });
  });
}
