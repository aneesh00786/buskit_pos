// Phase 5 — production-readiness fixes in offline storage/sync, against REAL
// files (only the server is faked, by the sync tests' FakeSyncServer):
//  * a corrupted / half-written queue entry no longer leaves its sale stuck
//    "waiting to sync" forever — it is kept aside and rebuilt from the sale;
//  * a queued sale whose entry was left FAILED is back in the normal flow;
//  * unreadable sale files are surfaced to staff (never silently invisible);
//  * synced sales are read from disk once per run (stock lookups stay fast).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/ui/offline_sale_views.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_sync_test.dart' as base;

List<String> files(String dir) =>
    Directory('${base.root.path}/$dir')
        .listSync()
        .map((e) => e.uri.pathSegments.last)
        .toList()
      ..sort();

void main() {
  setUp(() async {
    base.root = await Directory.systemTemp.createTemp('pos_offline_hard_');
    base.now = DateTime.utc(2026, 10, 6, 9);
    base.storage = OfflineStorageService(base.root, clock: () => base.now);
    await base.storage.initialize();
    await base.seed();
    base.server = base.FakeSyncServer();
    base.scope = base.theScope;
  });
  tearDown(() => base.root.delete(recursive: true));

  test('a corrupted queue entry is kept aside and rebuilt by the sync run: the sale syncs instead of waiting forever', () async {
    final sale = await base.recordSale();
    File('${base.root.path}/queue/${sale.localSaleId}.json')
        .writeAsStringSync('{"schema_version":1,"type":"queue","da');
    expect(
      await base.storage.getQueueEntry(sale.localSaleId),
      isNull,
      reason: 'unreadable',
    );
    final report = await base.newSync().syncNow();
    expect(report.synced, [sale.localSaleId]);
    expect(
      (await base.storage.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.synced,
    );
    final q = files('queue');
    expect(
      q.where((n) => n.startsWith('${sale.localSaleId}.json.corrupt-')).length,
      1,
      reason: 'the bad file is kept, not deleted',
    );
    expect(
      (await base.storage.getQueueEntry(sale.localSaleId))!.status,
      OfflineQueueStatus.done,
    );
    expect(
      base.storage.issues
          .map((i) => i.path)
          .any((p) => p.contains('.corrupt-')),
      isTrue,
    );
  });

  test('app restart with a corrupted queue entry: start-up recovery quarantines and rebuilds it (once), the sale is QUEUED', () async {
    final sale = await base.recordSale();
    File('${base.root.path}/queue/${sale.localSaleId}.json')
        .writeAsStringSync('');
    final restarted = OfflineStorageService(base.root, clock: () => base.now);
    final report = await restarted.initialize();
    expect(report.quarantinedQueueEntries, [sale.localSaleId]);
    expect(report.recreatedQueueEntries, [sale.localSaleId]);
    expect(
      (await restarted.getQueueEntry(sale.localSaleId))!.status,
      OfflineQueueStatus.pending,
    );
    expect(
      (await restarted.getSale(sale.localSaleId))!.status,
      OfflineSaleStatus.queued,
    );
    final again = await OfflineStorageService(base.root).initialize();
    expect(again.quarantinedQueueEntries, isEmpty);
    expect(again.recreatedQueueEntries, isEmpty);
    expect(
      files('queue').where((n) => n.endsWith('.json')).length,
      1,
      reason: 'no duplicate entries',
    );
  });

  test('a QUEUED sale whose entry was left FAILED (crash mid-resolution) is synced, not stuck', () async {
    final sale = await base.recordSale();
    await base.storage.transitionQueueEntry(
      sale.localSaleId,
      OfflineQueueStatus.inProgress,
    );
    await base.storage.transitionQueueEntry(
      sale.localSaleId,
      OfflineQueueStatus.failed,
      error: 'x',
    );
    final report = await base.newSync().syncNow();
    expect(report.synced, [sale.localSaleId]);
  });

  test('synced sales are read once and kept current in memory: stock lookups stay correct and fast as synced/ grows', () async {
    // 2,000 synced sales from earlier days (before the stock snapshot).
    Directory('${base.root.path}/synced').createSync(recursive: true);
    for (var i = 0; i < 2000; i++) {
      final id =
          '${(0x10000000 + i).toRadixString(16)}-9a4d-4e7b-8c2a-1d5e6f7a8b9c';
      final s = OfflineSale(
        localSaleId: id,
        status: OfflineSaleStatus.synced,
        companyId: 1,
        storeId: 213,
        registerId: 5,
        shiftId: 1,
        salesmanId: 'S',
        installationId: 'i',
        createdAt: DateTime.utc(2026, 9),
        updatedAt: DateTime.utc(2026, 9),
        syncedAt: DateTime.utc(2026, 9),
        serverSaleId: i + 1,
        lines: const [
          OfflineSaleLine(
            productVariationId: 1,
            productName: 'Soap',
            quantity: 1,
            unitPriceMilli: 100000,
            taxPercent: 12,
            taxMode: 'exclusive',
            taxAmountMilli: 12000,
            lineTotalMilli: 112000,
          ),
        ],
        payments: const [OfflinePayment(method: 'cash', amountMilli: 112000)],
        subtotalMilli: 100000,
        taxTotalMilli: 12000,
        discountTotalMilli: 0,
        grandTotalMilli: 112000,
      );
      File('${base.root.path}/synced/$id.json').writeAsStringSync(_doc(s));
    }
    final storage = OfflineStorageService(base.root, clock: () => base.now);
    await storage.initialize();
    base.storage = storage;
    expect(
      (await storage.getStockLevels())[1]!.availableQuantity,
      100,
      reason: 'old synced sales are in the snapshot already',
    );

    final sw = Stopwatch()..start();
    for (var i = 0; i < 10; i++) {
      await storage.getStockLevels();
    }
    expect(
      sw.elapsedMilliseconds,
      lessThan(1500),
      reason: '10 lookups no longer re-read 2,000 files each',
    );

    // A sale synced now (after the snapshot) is reflected without a re-read.
    final sale = await base.recordSale(qty: 3);
    base.now = base.now.add(const Duration(minutes: 1));
    await base.newSync().syncNow();
    expect((await storage.getStockLevels())[1]!.availableQuantity, 97);
    expect((await storage.getSyncedSales()).length, 2001);
    expect((await storage.getSyncedSales()).last.localSaleId, sale.localSaleId);
  });

  testWidgets(
    'an unreadable sale file is shown to staff (kept, not synced) — never silently invisible',
    (tester) async {
      await tester.runAsync(() async {
        await base.recordSale();
        final badId = '7e5f0000-9a4d-4e7b-8c2a-1d5e6f7a8b9c';
        File('${base.root.path}/sales/$badId.json').writeAsStringSync(
          '{"schema_version":1,"type":"sale","data":{"oops":true}}',
        );
        expect(await base.storage.unreadableSaleFiles(), ['$badId.json']);
      });
      final offline = OfflineServices(
        base.storage,
        syncApi: base.server,
        scope: () => base.scope,
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
      expect(find.byKey(const Key('offline-unreadable')), findsOneWidget);
      expect(
        find.textContaining(
          '1 offline sale file on this device could not be read.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('waiting to sync'),
        findsOneWidget,
        reason: 'readable sales still listed',
      );
    },
  );
}

String _doc(OfflineSale s) =>
    jsonEncode({'schema_version': 1, 'type': 'sale', 'data': s.toJson()});
