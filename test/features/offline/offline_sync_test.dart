// Offline POS Phase 3 — OfflineSyncService against REAL JSON storage in a
// temporary directory. Only the server is faked: [FakeSyncServer] behaves
// like POST /offline-sales/sync (creates once per local_sale_id, replays the
// same server sale on a retry) and can drop responses or reject sales.
import 'dart:async';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/offline_sync_service.dart';
import 'package:buskit_pos/features/offline/ui/offline_sale_views.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory root;
late OfflineStorageService storage;
late FakeSyncServer server;
late OfflineSyncService sync;
DateTime now = DateTime.utc(2026, 10, 6, 9);
PosTokenScope? scope;

const theScope = PosTokenScope(
  companyId: 1,
  storeId: 213,
  registerId: 5,
  deviceId: 9,
  salesmanId: 'TEST-SALES-A1',
);

const soap = OfflineProduct(
  productVariationId: 1,
  productName: 'Soap',
  sellingMode: 'PIECE',
  sellPriceMilli: 100000,
  taxPercent: 12,
  taxMode: 'exclusive',
);

/// Behaves like the server endpoint: one server sale per local_sale_id.
class FakeSyncServer implements OfflineSyncApi {
  final Map<String, int> created = {};
  final List<String> calls = [];
  final List<Map<String, dynamic>> bodies = [];
  final List<OfflineSaleStatus?> statusDuringCall = [];
  int _next = 100;

  /// Per-call behaviour: return null to succeed, or throw.
  Future<void> Function(String id)? before;

  /// Creates the sale, then loses the response (outcome unknown to device).
  bool dropNextResponse = false;
  Completer<void>? gate;

  @override
  Future<OfflineSyncResult> sync(OfflineSale sale) async {
    calls.add(sale.localSaleId);
    bodies.add(sale.toSyncJson());
    statusDuringCall.add((await storage.getSale(sale.localSaleId))?.status);
    if (gate != null) await gate!.future;
    await before?.call(sale.localSaleId);
    final replay = created.containsKey(sale.localSaleId);
    final id = created.putIfAbsent(sale.localSaleId, () => ++_next);
    if (dropNextResponse) {
      dropNextResponse = false;
      throw const ApiException(kind: ApiErrorKind.timeout, message: 'lost');
    }
    return OfflineSyncResult(
      localSaleId: sale.localSaleId,
      serverSaleId: id,
      saleNumber: 'POS-${id.toString().padLeft(8, '0')}',
      replayed: replay,
    );
  }

  // Phase 4 — behaves like POST /offline-sales/:id/resolve.
  final List<Map<String, Object?>> resolveCalls = [];
  Future<void> Function(String id)? beforeResolve;
  String resolver = 'MGR-1';

  @override
  Future<OfflineSyncResult> resolve(
    OfflineSale sale, {
    required String reason,
    String? note,
  }) async {
    resolveCalls.add({
      'id': sale.localSaleId,
      'reason': reason,
      'note': note,
      'previous_status': sale.status.wire,
      'previous_error_code': sale.lastErrorCode,
      'body': sale.toSyncJson(),
    });
    await beforeResolve?.call(sale.localSaleId);
    final replay = created.containsKey(sale.localSaleId);
    final id = created.putIfAbsent(sale.localSaleId, () => ++_next);
    if (dropNextResponse) {
      dropNextResponse = false;
      throw const ApiException(kind: ApiErrorKind.timeout, message: 'lost');
    }
    return OfflineSyncResult(
      localSaleId: sale.localSaleId,
      serverSaleId: id,
      saleNumber: 'POS-${id.toString().padLeft(8, '0')}',
      replayed: replay,
      resolvedBy: resolver,
      resolvedAt: DateTime.utc(2026, 10, 6, 12),
      resolutionReason: reason,
    );
  }
}

ApiException rejection(String code, {int status = 409}) =>
    ApiException.fromStatus(status, message: 'rejected', errorCode: code);

Future<OfflineSale> recordSale({
  int qty = 1,
  String staff = 'TEST-SALES-A1',
}) async {
  final checkout = OfflineCheckoutService(storage, clock: () => now);
  final line = OfflineCheckoutLine.fromProduct(soap, qty);
  final sale = await checkout.complete(
    OfflineCheckoutRequest(
      localSaleId: _uuid(),
      scope: PosTokenScope(
        companyId: 1,
        storeId: 213,
        registerId: 5,
        deviceId: 9,
        salesmanId: staff,
      ),
      lines: [line],
      payments: [
        PaymentLine(
          method: TenderMethod.cash,
          amountMilli: line.lineTotalMilli,
          tenderedMilli: line.lineTotalMilli + 8000,
        ),
      ],
    ),
  );
  now = now.add(const Duration(minutes: 1)); // deterministic order
  return sale;
}

int _n = 0;
String _uuid() {
  _n++;
  final hex = _n.toRadixString(16).padLeft(8, '0');
  return '$hex-9a4d-4e7b-8c2a-1d5e6f7a8b9c';
}

Future<void> seed() async {
  await storage.saveCatalogue(
    OfflineCatalogue(
      companyId: 1,
      storeId: 213,
      cachedAt: now,
      products: const [soap],
    ),
  );
  await storage.saveInventory(
    InventorySnapshot(
      syncedAt: now,
      entries: const [
        InventorySnapshotEntry(productVariationId: 1, serverQuantity: 100),
      ],
    ),
  );
  for (final staff in ['TEST-SALES-A1']) {
    await storage.saveCurrentShift(
      OfflineShiftContext(
        companyId: 1,
        storeId: 213,
        registerId: 5,
        deviceId: 9,
        shiftId: 79,
        salesmanId: staff,
        status: 'open',
      ),
    );
  }
}

OfflineSyncService newSync() => OfflineSyncService(
  storage: storage,
  api: server,
  scope: () => scope,
  clock: () => now,
);

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos_offline_sync_');
    now = DateTime.utc(2026, 10, 6, 9);
    storage = OfflineStorageService(root, clock: () => now);
    await storage.initialize();
    await seed();
    server = FakeSyncServer();
    scope = theScope;
    sync = newSync();
  });
  tearDown(() => root.delete(recursive: true));

  test('a QUEUED sale is found, sent while SYNCING, and becomes SYNCED with the server id; queue DONE; the synced copy is kept', () async {
    final sale = await recordSale(qty: 2);
    expect(sale.status, OfflineSaleStatus.queued);
    final report = await sync.syncNow();
    expect(report.synced, [sale.localSaleId]);
    expect(server.calls, [sale.localSaleId]);
    expect(server.statusDuringCall.single, OfflineSaleStatus.syncing);
    final stored = (await storage.getSale(sale.localSaleId))!;
    expect(stored.status, OfflineSaleStatus.synced);
    expect(stored.serverSaleId, 101);
    expect(stored.serverSaleNumber, 'POS-00000101');
    expect(stored.syncedAt, now);
    final entry = (await storage.getQueueEntry(sale.localSaleId))!;
    expect(entry.status, OfflineQueueStatus.done);
    expect(entry.attemptCount, 1);
    expect(await storage.getPendingSales(), isEmpty);
    expect(
      File('${root.path}/synced/${sale.localSaleId}.json').existsSync(),
      isTrue,
    );
  });

  test('the request carries only offline-safe tenders (provider NONE) and the sale snapshot; nothing provider-related', () async {
    final sale = await recordSale(qty: 2);
    await sync.syncNow();
    final body = server.bodies.single;
    expect(body['local_sale_id'], sale.localSaleId);
    expect(body['device_id'], 9);
    expect(body['salesman_id'], 'TEST-SALES-A1');
    expect(body['shift_id'], 79);
    final pay = (body['payments'] as List).single as Map;
    expect(pay['provider'], 'NONE');
    expect(pay.containsKey('payment_attempt_id'), isFalse);
    expect(pay['tendered_milli'], 232000);
    expect(pay['change_milli'], 8000);
    final line = (body['lines'] as List).single as Map;
    expect(line['unit_price_milli'], 100000);
    expect(line['tax_amount_milli'], 24000);
    expect((body['totals'] as Map)['grand_total_milli'], 224000);
  });

  test('network error: back to QUEUED with back-off, same id, the run stops; a later run syncs it with the SAME local_sale_id', () async {
    final a = await recordSale();
    final b = await recordSale();
    server.before = (id) async {
      throw const ApiException(kind: ApiErrorKind.network, message: 'down');
    };
    final report = await sync.syncNow();
    expect(report.stoppedEarly, isTrue);
    expect(server.calls, [a.localSaleId], reason: 'later sales wait');
    final sa = (await storage.getSale(a.localSaleId))!;
    expect(sa.status, OfflineSaleStatus.queued);
    expect(sa.lastError, OfflineSyncService.retryMessage);
    final ea = (await storage.getQueueEntry(a.localSaleId))!;
    expect(ea.status, OfflineQueueStatus.pending);
    expect(ea.nextAttemptAt, now.add(const Duration(seconds: 30)));
    expect(report.nextRetryAt, ea.nextAttemptAt);

    // Not due yet: a normal run skips it; time passes and the server is back.
    server.before = null;
    expect((await sync.syncNow()).synced, isEmpty);
    now = now.add(const Duration(seconds: 31));
    final again = await sync.syncNow();
    expect(again.synced, [a.localSaleId, b.localSaleId]);
    expect(server.calls, [a.localSaleId, a.localSaleId, b.localSaleId]);
    expect((await storage.getSale(a.localSaleId))!.lastError, isNull);
  });

  test('lost response: the server created the sale but the device never heard; the retry reuses the id and gets the ORIGINAL server sale', () async {
    final sale = await recordSale();
    server.dropNextResponse = true;
    await sync.syncNow();
    expect(server.created.length, 1, reason: 'the server did create it');
    expect(
      (await storage.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.queued,
    );
    final again = await sync.syncNow(force: true);
    expect(again.synced, [sale.localSaleId]);
    expect(server.calls, [sale.localSaleId, sale.localSaleId]);
    expect(server.created.length, 1, reason: 'no second server sale');
    expect(
      (await storage.getSale(sale.localSaleId))!.serverSaleId,
      server.created[sale.localSaleId],
    );
    expect(
      (await storage.getSales()).length +
          (await storage.getSyncedSales()).length,
      1,
      reason: 'no new local sale',
    );
  });

  test('permanent rejection: SYNC_FAILED with a clear reason, queue FAILED, kept visible; later sales still sync; not retried automatically', () async {
    final bad = await recordSale(qty: 7);
    final good = await recordSale();
    server.before = (id) async {
      if (id == bad.localSaleId) throw rejection('OFFLINE_STOCK_CONFLICT');
    };
    final report = await sync.syncNow();
    expect(report.failed, [bad.localSaleId]);
    expect(report.synced, [good.localSaleId]);
    final s = (await storage.getSale(bad.localSaleId))!;
    expect(s.status, OfflineSaleStatus.syncFailed);
    expect(
      s.lastError,
      'Could not sync this sale because stock is no longer available.',
    );
    expect(s.lastErrorCode, 'OFFLINE_STOCK_CONFLICT');
    expect(
      (await storage.getQueueEntry(bad.localSaleId))!.status,
      OfflineQueueStatus.failed,
    );
    expect((await storage.getPendingSales()).map((x) => x.localSaleId), [
      bad.localSaleId,
    ]);
    // Still counts against offline stock (it was sold on this device).
    expect(
      (await storage.getStockLevels())[1]!.offlineConsumedQuantity,
      8,
      reason: '7 unsynced + 1 synced after the snapshot',
    );

    server.before = null;
    now = now.add(const Duration(hours: 5));
    await sync.syncNow(force: true);
    expect(
      server.calls.where((c) => c == bad.localSaleId).length,
      1,
      reason: 'never retried automatically',
    );
  });

  test('reasons for every rejection type are human-readable (no codes, SQL or ids)', () {
    final cases = {
      'OFFLINE_TAX_MISMATCH':
          'Could not sync this sale because tax information changed.',
      'OFFLINE_SHIFT_INVALID': 'Could not sync this sale because the original shift is no longer valid.',
      'OFFLINE_PRICE_MISMATCH':
          'Could not sync this sale because a price changed.',
      'OFFLINE_PRODUCT_INVALID':
          'Could not sync this sale because a product is no longer available.',
    };
    cases.forEach((code, msg) {
      final e = rejection(code);
      expect(OfflineSyncService.classify(e), SyncFailureKind.permanent);
      expect(OfflineSyncService.messageFor(e), msg);
    });
    for (final e in [
      const ApiException(kind: ApiErrorKind.network, message: 'x'),
      const ApiException(kind: ApiErrorKind.timeout, message: 'x'),
      ApiException.fromStatus(500),
      ApiException.fromStatus(503),
      ApiException.fromStatus(429),
    ]) {
      expect(OfflineSyncService.classify(e), SyncFailureKind.retryable);
      expect(
        OfflineSyncService.messageFor(e),
        'Could not connect to the server. This sale will be retried.',
      );
    }
    expect(
      OfflineSyncService.classify(ApiException.fromStatus(401)),
      SyncFailureKind.paused,
    );
    expect(
      OfflineSyncService.messageFor(
        ApiException.fromStatus(422, message: 'SQL near SELECT'),
      ),
      'Could not sync this sale. Please contact support.',
    );
  });

  test('manual retry of a SYNC_FAILED sale reuses the SAME local_sale_id and syncs it', () async {
    final sale = await recordSale();
    server.before = (_) async => throw rejection('OFFLINE_TAX_MISMATCH');
    await sync.syncNow();
    expect(
      (await storage.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.syncFailed,
    );
    server.before = null;
    final report = await sync.retry(sale.localSaleId);
    expect(report.synced, [sale.localSaleId]);
    expect(server.calls, [sale.localSaleId, sale.localSaleId]);
    expect(
      (await storage.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.synced,
    );
    expect(
      (await storage.getQueueEntry(sale.localSaleId))!.status,
      OfflineQueueStatus.done,
    );
  });

  test('one runner: simultaneous triggers (start-up + reconnect + Sync now) share one run; each sale is sent once', () async {
    final a = await recordSale();
    final b = await recordSale();
    server.gate = Completer<void>();
    final r1 = sync.syncNow();
    final r2 = sync.syncNow();
    final r3 = sync.syncNow(force: true);
    expect(sync.isRunning, isTrue);
    server.gate!.complete();
    final reports = await Future.wait([r1, r2, r3]);
    expect(
      identical(reports[0], reports[1]) && identical(reports[1], reports[2]),
      isTrue,
    );
    expect(server.calls, [a.localSaleId, b.localSaleId]);
  });

  test('queued sales are processed oldest first, deterministically', () async {
    final ids = [for (var i = 0; i < 5; i++) (await recordSale()).localSaleId];
    await sync.syncNow();
    expect(server.calls, ids);
  });

  test('app restart keeps QUEUED and SYNC_FAILED sales (with their reason)', () async {
    final failed = await recordSale();
    final queued = await recordSale();
    server.before = (id) async {
      if (id == failed.localSaleId) throw rejection('OFFLINE_SHIFT_INVALID');
      throw const ApiException(kind: ApiErrorKind.timeout, message: 't');
    };
    final report = await sync.syncNow();
    expect(report.failed, [failed.localSaleId]);
    expect(report.retryLater, [queued.localSaleId]);

    final restarted = OfflineStorageService(root, clock: () => now);
    await restarted.initialize();
    final q = (await restarted.getSale(queued.localSaleId))!;
    expect(q.status, OfflineSaleStatus.queued);
    expect(
      (await restarted.getQueueEntry(queued.localSaleId))!.status,
      OfflineQueueStatus.pending,
    );
    final f = (await restarted.getSale(failed.localSaleId))!;
    expect(f.status, OfflineSaleStatus.syncFailed);
    expect(
      f.lastError,
      'Could not sync this sale because the original shift is no longer valid.',
    );
    expect(
      (await restarted.getQueueEntry(failed.localSaleId))!.status,
      OfflineQueueStatus.failed,
    );
  });

  test('a crash after the server accepted the sale (left SYNCING / IN_PROGRESS) is re-sent with the same id and replayed', () async {
    final sale = await recordSale();
    // Simulate: sent, server created it, app died before the local update.
    await storage.transitionQueueEntry(
      sale.localSaleId,
      OfflineQueueStatus.inProgress,
    );
    await storage.transitionSale(sale.localSaleId, OfflineSaleStatus.syncing);
    server.created[sale.localSaleId] = 555;
    final restarted = OfflineStorageService(root, clock: () => now);
    await restarted.initialize();
    storage = restarted;
    final report = await newSync().syncNow();
    expect(report.synced, [sale.localSaleId]);
    expect((await restarted.getSale(sale.localSaleId))!.serverSaleId, 555);
    expect(server.created.length, 1);
  });

  test('only the cashier and device that recorded a sale send it; nothing is sent without a session; 401 pauses without failing', () async {
    final mine = await recordSale();
    await storage.saveCurrentShift(
      const OfflineShiftContext(
        companyId: 1,
        storeId: 213,
        registerId: 5,
        deviceId: 9,
        shiftId: 79,
        salesmanId: 'TEST-SALES-A2',
        status: 'open',
      ),
    );
    final theirs = await recordSale(staff: 'TEST-SALES-A2');
    scope = null;
    expect((await sync.syncNow()).stoppedEarly, isTrue);
    expect(server.calls, isEmpty);

    scope = theScope;
    server.before = (_) async => throw ApiException.fromStatus(401);
    final paused = await sync.syncNow();
    expect(paused.stoppedEarly, isTrue);
    expect(
      (await storage.getSale(mine.localSaleId))!.status,
      OfflineSaleStatus.queued,
    );
    expect(
      (await storage.getQueueEntry(mine.localSaleId))!.nextAttemptAt,
      isNull,
    );

    server.before = null;
    final report = await sync.syncNow();
    expect(report.synced, [mine.localSaleId]);
    expect(report.skipped, [theirs.localSaleId]);
    expect(
      (await storage.getSale(theirs.localSaleId))!.status,
      OfflineSaleStatus.queued,
    );
  });

  test('back-off is bounded and exponential', () {
    final s = OfflineSyncService(
      storage: storage,
      api: server,
      scope: () => scope,
      baseDelay: const Duration(seconds: 30),
      maxDelay: const Duration(minutes: 30),
    );
    expect(
      [for (var i = 1; i <= 8; i++) s.backoff(i).inSeconds],
      [30, 60, 120, 240, 480, 960, 1800, 1800],
    );
  });

  test('stock: a sale synced after the stock snapshot still counts until the next refresh', () async {
    final sale = await recordSale(qty: 3);
    expect((await storage.getStockLevels())[1]!.availableQuantity, 97);
    now = now.add(const Duration(minutes: 5));
    await sync.syncNow();
    expect(
      (await storage.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.synced,
    );
    expect(
      (await storage.getStockLevels())[1]!.availableQuantity,
      97,
      reason: 'not double-counted, not given back',
    );
    await storage.saveInventory(
      InventorySnapshot(
        syncedAt: now.add(const Duration(minutes: 1)),
        entries: const [
          InventorySnapshotEntry(productVariationId: 1, serverQuantity: 97),
        ],
      ),
    );
    expect(
      (await storage.getStockLevels())[1]!.availableQuantity,
      97,
      reason: 'the refreshed server figure includes it',
    );
  });

  testWidgets(
    'sales history shows waiting / failed (with reason) / synced (local reference -> server number); Retry sync re-sends the same sale',
    (tester) async {
      late OfflineSale waiting;
      late OfflineSale failed;
      late OfflineSale done;
      await tester.runAsync(() async {
        done = await recordSale();
        await sync.syncNow();
        failed = await recordSale();
        server.before = (_) async => throw rejection('OFFLINE_TAX_MISMATCH');
        await sync.syncNow();
        server.before = null;
        waiting = await recordSale();
      });
      final offline = OfflineServices(
        storage,
        syncApi: server,
        scope: () => scope,
        clock: () => now,
      );
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: LocalSalesSection(offline: offline),
              ),
            ),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('On this device — not yet synced (2)'),
        findsOneWidget,
      );
      expect(find.textContaining('waiting to sync'), findsOneWidget);
      expect(find.textContaining('Sync failed'), findsOneWidget);
      expect(find.textContaining('tax information changed'), findsOneWidget);
      expect(
        find.text('${offlineSaleTitle(done)} → POS-00000101'),
        findsOneWidget,
      );
      expect(find.text(offlineSaleTitle(waiting)), findsOneWidget);

      await tester.tap(find.text(offlineSaleTitle(failed)));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline-sync-error')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const Key('offline-retry-sync')));
        for (
          var i = 0;
          i < 100 &&
              (await storage.getSale(failed.localSaleId))!.status !=
                  OfflineSaleStatus.synced;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();
      expect(
        (await tester.runAsync(() => storage.getSale(failed.localSaleId)))!
            .status,
        OfflineSaleStatus.synced,
      );
      expect(server.calls.where((c) => c == failed.localSaleId).length, 2);
      expect(
        find.textContaining('${offlineSaleTitle(failed)} →'),
        findsOneWidget,
      );
    },
  );
}
