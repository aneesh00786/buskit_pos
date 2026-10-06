// Offline POS Phase 1 — the JSON storage foundation, tested against REAL
// files in a temporary directory (no mocks): atomic writes, corruption
// handling, schema versions, caches, offline sales + queue, recovery after
// interrupted writes, restarts and concurrent writes.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/offline/json_file_store.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_payment_policy.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

late Directory root;
DateTime now = DateTime.utc(2026, 10, 6, 9, 0);

OfflineStorageService open() => OfflineStorageService(root, clock: () => now);
File file(String rel) => File('${root.path}/$rel');

const soap = OfflineProduct(
  productVariationId: 1,
  productName: 'Soap',
  variationName: '100g',
  productCode: 'SOAP-100',
  barcode: '8901000000011',
  sellingMode: 'PIECE',
  sellPriceMilli: 100000,
  taxPercent: 12,
  taxMode: 'exclusive',
);
const oil = OfflineProduct(
  productVariationId: 2,
  productName: 'Oil',
  variationName: '1L',
  productCode: 'OIL-1L',
  barcode: '8901000000028',
  sellingMode: 'PIECE',
  sellPriceMilli: 236000,
  taxPercent: 18,
  taxMode: 'inclusive',
);
const apples = OfflineProduct(
  productVariationId: 3,
  productName: 'Apples',
  sellingMode: 'WEIGHT',
  sellPriceMilli: 150000,
  taxPercent: 0,
  taxMode: 'none',
);

final shift = OfflineShiftContext(
  companyId: 1,
  storeId: 213,
  registerId: 5,
  deviceId: 9,
  shiftId: 79,
  salesmanId: 'TEST-SALES-A1',
  openedAt: DateTime.utc(2026, 10, 6, 8),
  status: 'open',
  currency: 'INR',
);

// Line figures as the server computes them (posTax.computeLine), supplied by
// the caller — storage never recomputes them.
OfflineSaleLine soapLine(int qty) => OfflineSaleLine(
  productVariationId: 1,
  productName: 'Soap',
  variationName: '100g',
  quantity: qty,
  unitPriceMilli: 100000,
  taxPercent: 12,
  taxMode: 'exclusive',
  taxAmountMilli: 12000 * qty,
  lineTotalMilli: 112000 * qty,
);
OfflineSaleLine oilLine(int qty) => OfflineSaleLine(
  productVariationId: 2,
  productName: 'Oil',
  quantity: qty,
  unitPriceMilli: 236000,
  taxPercent: 18,
  taxMode: 'inclusive',
  taxAmountMilli: 36000 * qty,
  lineTotalMilli: 236000 * qty,
);

OfflineSale sale({
  List<OfflineSaleLine>? lines,
  List<OfflinePayment>? payments,
  String? id,
  int storeId = 213,
  OfflineSaleStatus status = OfflineSaleStatus.completedLocal,
}) {
  final ls = lines ?? [soapLine(2)];
  final total = ls.fold<int>(0, (s, l) => s + l.lineTotalMilli);
  return OfflineSale(
    localSaleId: id ?? generateUuidV4(),
    status: status,
    companyId: 1,
    storeId: storeId,
    registerId: 5,
    deviceId: 9,
    shiftId: 79,
    salesmanId: 'TEST-SALES-A1',
    installationId: 'install-1',
    currency: 'INR',
    createdAt: now,
    updatedAt: now,
    lines: ls,
    payments:
        payments ??
        [
          OfflinePayment(
            method: 'cash',
            amountMilli: total,
            tenderedMilli: total + 1000,
            changeMilli: 1000,
          ),
        ],
    subtotalMilli: ls.fold<int>(0, (s, l) => s + l.listedAmountMilli),
    taxTotalMilli: ls.fold<int>(0, (s, l) => s + l.taxAmountMilli),
    discountTotalMilli: 0,
    grandTotalMilli: total,
  );
}

Future<OfflineStorageService> ready() async {
  final s = open();
  await s.initialize();
  await s.saveCatalogue(
    OfflineCatalogue(
      companyId: 1,
      storeId: 213,
      cachedAt: now,
      products: const [soap, oil, apples],
    ),
  );
  await s.saveCurrentShift(shift);
  return s;
}

Map<String, dynamic> envelopeOf(String rel) =>
    jsonDecode(file(rel).readAsStringSync()) as Map<String, dynamic>;

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos-offline-test-');
    now = DateTime.utc(2026, 10, 6, 9, 0);
  });
  tearDown(() async {
    if (await root.exists()) {
      await Process.run('chmod', ['-R', 'u+w', root.path]);
      await root.delete(recursive: true);
    }
  });

  group('storage basics', () {
    test('initialize creates the offline folders and is repeatable', () async {
      final s = open();
      await s.initialize();
      await s.initialize();
      for (final d in ['sales', 'queue', 'synced']) {
        expect(Directory('${root.path}/$d').existsSync(), isTrue, reason: d);
      }
    });

    test('documents are written as versioned envelopes and read back; no temp files remain', () async {
      final s = await ready();
      final env = envelopeOf('products.json');
      expect(env['schema_version'], 1);
      expect(env['type'], 'catalogue');
      expect((env['data'] as Map)['company_id'], 1);
      expect(
        root.listSync(recursive: true).where((e) => e.path.contains('.tmp-')),
        isEmpty,
      );
      expect(
        (await s.getCatalogue())!.products.map((p) => p.productVariationId),
        [1, 2, 3],
      );
    });

    test('atomic write: a failed write leaves the previous document intact (never truncated)', () async {
      final s = await ready();
      final before = file('products.json').readAsStringSync();
      await Process.run('chmod', [
        'u-w',
        root.path,
      ]); // the rename step cannot happen
      await expectLater(
        s.saveCatalogue(
          OfflineCatalogue(
            companyId: 1,
            storeId: 213,
            cachedAt: now,
            products: const [soap],
          ),
        ),
        throwsA(isA<OfflineStorageException>()),
      );
      await Process.run('chmod', ['u+w', root.path]);
      expect(file('products.json').readAsStringSync(), before);
      expect((await open().getCatalogue())!.products.length, 3);
    });

    test('a temp file left by a crash mid-write is cleaned up and the real document is unaffected', () async {
      await ready();
      file('products.json.tmp-dead').writeAsStringSync('{"half": ');
      file('sales/abc.json.tmp-dead').writeAsStringSync('{');
      final report = await open().initialize();
      expect(report.tempFilesRemoved, 2);
      expect((await open().getCatalogue())!.products.length, 3);
    });

    test(
      'missing, empty and malformed cache files fail safely and are reported',
      () async {
        final s = open();
        await s.initialize();
        expect(
          await s.getCatalogue(),
          isNull,
          reason: 'missing = nothing cached, no issue',
        );
        expect(s.issues, isEmpty);
        file('products.json').writeAsStringSync('');
        file('customers.json').writeAsStringSync('{not json');
        file('inventory.json').writeAsStringSync(
          '{"schema_version":1,"type":"inventory","data":{"synced_at":"nope"}}',
        );
        expect(await s.getCatalogue(), isNull);
        expect(await s.getProducts(), isEmpty);
        expect(await s.getCustomers(), isEmpty);
        expect(await s.getStockLevels(), isEmpty);
        expect(s.issues.map((i) => i.path).toSet(), {
          'products.json',
          'customers.json',
          'inventory.json',
        });
      },
    );

    test('schema versions: a newer version is reported as incompatible (not guessed); older documents are migrated on read', () async {
      final s = await ready();
      final env = envelopeOf('products.json')..['schema_version'] = 99;
      file('products.json').writeAsStringSync(jsonEncode(env));
      expect(await s.getCatalogue(), isNull);
      expect(s.issues.single.problem, 'unsupported schema version 99');

      final store = JsonFileStore(root)..registerType('demo', current: 1);
      await store.write('demo.json', type: 'demo', data: {'name': 'old'});
      final upgraded = JsonFileStore(root)
        ..registerType(
          'demo',
          current: 2,
          migrations: {
            1: (d) => {...d, 'renamed': d['name']},
          },
        );
      final r = await upgraded.read('demo.json', type: 'demo');
      expect([r.version, r.data!['renamed']], [2, 'old']);
      final noPath = JsonFileStore(root)
        ..registerType('demo', current: 3, migrations: {1: (d) => d});
      expect(
        (await noPath.read('demo.json', type: 'demo')).state,
        JsonReadState.incompatible,
        reason: 'missing migration step',
      );
    });
  });

  group('caches', () {
    test('product cache: survives a restart; search by name / variation / code / barcode; WEIGHT stays unsellable', () async {
      await ready();
      final s = open();
      expect((await s.searchProducts('soap')).single.productVariationId, 1);
      expect((await s.searchProducts('1l')).single.productVariationId, 2);
      expect((await s.searchProducts('OIL-1')).single.productVariationId, 2);
      expect((await s.findByCode('8901000000011'))!.productName, 'Soap');
      expect((await s.findByCode('SOAP-100'))!.productVariationId, 1);
      expect(await s.findByCode('nope'), isNull);
      expect((await s.getProduct(3))!.isPosSellable, isFalse);
      expect((await s.getProduct(2))!.taxMode, 'inclusive');
      final cat = (await s.getCatalogue())!;
      expect([cat.companyId, cat.storeId], [1, 213]);
    });

    test(
      'customer cache: minimal fields only, searchable, survives a restart',
      () async {
        final s = open();
        await s.initialize();
        await s.saveCustomers(const [
          OfflineCustomer(
            id: 7,
            customerId: 'CUST-7',
            fullname: 'Asha Rao',
            mobileno: '9876543210',
            email: 'asha@example.com',
          ),
        ]);
        final again = open();
        expect(
          (await again.searchCustomers('asha')).single.customerId,
          'CUST-7',
        );
        expect((await again.searchCustomers('98765')).single.id, 7);
        final stored =
            (envelopeOf('customers.json')['data'] as Map)['customers'] as List;
        expect((stored.single as Map).keys.toSet(), {
          'id',
          'customer_id',
          'fullname',
          'mobileno',
          'email',
        });
      },
    );

    test('inventory snapshot + offline consumption: available = server quantity - unsynced local sales; marked stale', () async {
      final s = await ready();
      await s.saveInventory(
        InventorySnapshot(
          syncedAt: now,
          entries: const [
            InventorySnapshotEntry(productVariationId: 1, serverQuantity: 100),
            InventorySnapshotEntry(productVariationId: 2, serverQuantity: 10),
          ],
        ),
      );
      await s.recordCompletedSale(sale(lines: [soapLine(3)]));
      final second = await s.recordCompletedSale(
        sale(lines: [soapLine(2), oilLine(1)]),
      );
      var levels = await open().getStockLevels();
      expect(
        [
          levels[1]!.serverQuantity,
          levels[1]!.offlineConsumedQuantity,
          levels[1]!.availableQuantity,
        ],
        [100, 5, 95],
      );
      expect(levels[2]!.availableQuantity, 9);
      expect(levels[1]!.staleLabel, startsWith('Offline stock — last updated'));
      await s.transitionSale(second.localSaleId, OfflineSaleStatus.syncing);
      await s.moveToSynced(second.localSaleId, serverSaleId: 555);
      levels = await s.getStockLevels();
      expect(
        levels[1]!.offlineConsumedQuantity,
        3,
        reason:
            'a server-confirmed sale no longer counts as offline consumption',
      );
    });

    test('shift context and device identity persist across restarts; the device id is created once', () async {
      await ready();
      final s1 = open();
      final d1 = await s1.getOrCreateDeviceInfo(deviceIdentifier: 'REG-1');
      final s2 = open();
      final d2 = await s2.getOrCreateDeviceInfo();
      expect(d2.installationId, d1.installationId);
      expect(d2.deviceIdentifier, 'REG-1');
      final same = await Future.wait(
        List.generate(10, (_) => open().getOrCreateDeviceInfo()),
      );
      expect(same.map((d) => d.installationId).toSet(), {d1.installationId});
      final sh = (await s2.getCurrentShift())!;
      expect(
        [
          sh.companyId,
          sh.storeId,
          sh.registerId,
          sh.deviceId,
          sh.shiftId,
          sh.salesmanId,
          sh.isOpen,
        ],
        [1, 213, 5, 9, 79, 'TEST-SALES-A1', true],
      );
      file('device.json').writeAsStringSync('garbage');
      await expectLater(
        open().getOrCreateDeviceInfo(),
        throwsA(isA<OfflineStorageException>()),
        reason: 'a corrupt identity is never silently replaced',
      );
    });
  });

  group('offline sales and queue', () {
    test('a completed cash sale is stored in its own file with its queue entry; scope, prices and tax are snapshotted', () async {
      final s = await ready();
      final recorded = await s.recordCompletedSale(
        sale(lines: [soapLine(2), oilLine(1)]),
      );
      final id = recorded.localSaleId;
      expect(file('sales/$id.json').existsSync(), isTrue);
      expect(file('queue/$id.json').existsSync(), isTrue);
      final stored = (await open().getSale(id))!;
      expect(stored.status, OfflineSaleStatus.queued);
      expect(stored.serverSaleId, isNull);
      expect(
        [
          stored.companyId,
          stored.storeId,
          stored.registerId,
          stored.deviceId,
          stored.shiftId,
          stored.salesmanId,
        ],
        [1, 213, 5, 9, 79, 'TEST-SALES-A1'],
      );
      expect(
        [stored.subtotalMilli, stored.taxTotalMilli, stored.grandTotalMilli],
        [436000, 60000, 460000],
      );
      final oilStored = stored.lines[1];
      expect(
        [
          oilStored.unitPriceMilli,
          oilStored.taxPercent,
          oilStored.taxMode,
          oilStored.taxIncluded,
          oilStored.taxAmountMilli,
          oilStored.lineTotalMilli,
        ],
        [236000, 18.0, 'inclusive', true, 36000, 236000],
      );
      expect(stored.payments.single.toJson()['provider'], 'NONE');
      final q = (await s.getQueueEntry(id))!;
      expect(
        [q.status, q.entityType, q.operation, q.attemptCount, q.idempotencyKey],
        [OfflineQueueStatus.pending, 'sale', 'create', 0, id],
      );
    });

    test('price snapshot: a later catalogue price change never changes a stored sale', () async {
      final s = await ready();
      final id = (await s.recordCompletedSale(sale())).localSaleId;
      await s.saveCatalogue(
        OfflineCatalogue(
          companyId: 1,
          storeId: 213,
          cachedAt: now,
          products: const [
            OfflineProduct(
              productVariationId: 1,
              productName: 'Soap',
              sellingMode: 'PIECE',
              sellPriceMilli: 999000,
              taxPercent: 28,
              taxMode: 'exclusive',
            ),
          ],
        ),
      );
      final stored = (await open().getSale(id))!;
      expect(
        [
          stored.lines.single.unitPriceMilli,
          stored.lines.single.taxPercent,
          stored.grandTotalMilli,
        ],
        [100000, 12.0, 224000],
      );
    });

    test(
      'local sale ids are UUID v4 and unique; a duplicate id is refused',
      () async {
        final ids = List.generate(2000, (_) => generateUuidV4());
        expect(ids.toSet().length, 2000);
        expect(ids.every(OfflineSale.idPattern.hasMatch), isTrue);
        final s = await ready();
        final first = await s.recordCompletedSale(sale());
        await expectLater(
          s.recordCompletedSale(sale(id: first.localSaleId)),
          throwsA(isA<OfflineStorageException>()),
        );
        await expectLater(
          s.recordCompletedSale(sale(id: '12345')),
          throwsA(isA<OfflineStorageException>()),
        );
      },
    );

    test('many sales: one file per sale and per queue entry, all listed after a restart', () async {
      final s = await ready();
      final ids = <String>[];
      for (var i = 0; i < 25; i++) {
        now = now.add(const Duration(minutes: 1));
        ids.add((await s.recordCompletedSale(sale())).localSaleId);
      }
      final again = open();
      await again.initialize();
      expect((await again.getSales()).map((x) => x.localSaleId), ids);
      expect((await again.getPendingSales()).length, 25);
      expect((await again.getQueueEntries()).map((q) => q.localId), ids);
      expect(Directory('${root.path}/sales').listSync().length, 25);
      expect(Directory('${root.path}/queue').listSync().length, 25);
    });

    test('refused sales write nothing: bad totals, payments not equal to the total, no shift, other store, unknown or WEIGHT product', () async {
      final s = await ready();
      final bad = sale();
      final wrongTotal = OfflineSale.fromJson({
        ...bad.toJson(),
        'grand_total_milli': 1,
      })!;
      final underpaid = sale(
        payments: const [OfflinePayment(method: 'cash', amountMilli: 1)],
      );
      final otherStore = sale(storeId: 999);
      final unknown = sale(
        lines: [
          OfflineSaleLine(
            productVariationId: 42,
            productName: 'X',
            quantity: 1,
            unitPriceMilli: 1000,
            taxPercent: 0,
            taxMode: 'none',
            taxAmountMilli: 0,
            lineTotalMilli: 1000,
          ),
        ],
      );
      final weight = sale(
        lines: [
          OfflineSaleLine(
            productVariationId: 3,
            productName: 'Apples',
            quantity: 1,
            unitPriceMilli: 150000,
            taxPercent: 0,
            taxMode: 'none',
            taxAmountMilli: 0,
            lineTotalMilli: 150000,
          ),
        ],
      );
      for (final x in [
        wrongTotal,
        underpaid,
        otherStore,
        unknown,
        weight,
        sale(status: OfflineSaleStatus.draft),
      ]) {
        await expectLater(
          s.recordCompletedSale(x),
          throwsA(isA<OfflineStorageException>()),
        );
      }
      await s.clearCurrentShift();
      await expectLater(
        s.recordCompletedSale(sale()),
        throwsA(isA<OfflineStorageException>()),
      );
      expect(Directory('${root.path}/sales').listSync(), isEmpty);
      expect(Directory('${root.path}/queue').listSync(), isEmpty);
    });

    test('sale state machine: queued -> syncing -> sync_failed -> queued -> syncing -> synced (with server id); forbidden moves are refused', () async {
      final s = await ready();
      final id = (await s.recordCompletedSale(sale())).localSaleId;
      await expectLater(
        s.transitionSale(id, OfflineSaleStatus.synced),
        throwsA(isA<OfflineStorageException>()),
      );
      await expectLater(
        s.transitionSale(id, OfflineSaleStatus.cancelled),
        throwsA(isA<OfflineStorageException>()),
        reason: 'a paid sale is never just cancelled',
      );
      expect(
        (await s.transitionSale(id, OfflineSaleStatus.syncing)).status,
        OfflineSaleStatus.syncing,
      );
      final failed = await s.transitionSale(
        id,
        OfflineSaleStatus.syncFailed,
        error: 'timeout',
      );
      expect(
        [failed.status, failed.lastError],
        [OfflineSaleStatus.syncFailed, 'timeout'],
      );
      expect(failed.status.label, 'Sync failed');
      await s.transitionSale(id, OfflineSaleStatus.queued);
      await s.transitionSale(id, OfflineSaleStatus.syncing);
      final synced = await s.moveToSynced(id, serverSaleId: 4242);
      expect(
        [synced.status, synced.serverSaleId, synced.status.label],
        [OfflineSaleStatus.synced, 4242, 'Synced'],
      );
      expect(file('sales/$id.json').existsSync(), isFalse);
      // Phase 3: the queue entry is kept as a DONE record, not deleted.
      expect((await s.getQueueEntry(id))!.status, OfflineQueueStatus.done);
      expect(file('synced/$id.json').existsSync(), isTrue);
      expect((await open().getSale(id))!.serverSaleId, 4242);
      expect((await open().getSale(id))!.syncedAt, isNotNull);
      expect(await s.getPendingSales(), isEmpty);
      expect((await s.getSyncedSales()).single.localSaleId, id);
      expect(
        OfflineSaleStatus.queued.label,
        'Saved on this device — not yet synced',
        reason: 'never shown as synced before the server confirms',
      );
    });

    test('draft sales: stored without a queue entry; can be cancelled; never count against stock', () async {
      final s = await ready();
      await s.saveInventory(
        InventorySnapshot(
          syncedAt: now,
          entries: const [
            InventorySnapshotEntry(productVariationId: 1, serverQuantity: 10),
          ],
        ),
      );
      final draft = sale(status: OfflineSaleStatus.draft);
      await s.saveDraft(draft);
      expect(file('queue/${draft.localSaleId}.json').existsSync(), isFalse);
      expect((await s.getStockLevels())[1]!.availableQuantity, 10);
      expect(
        (await s.transitionSale(
          draft.localSaleId,
          OfflineSaleStatus.cancelled,
        )).status,
        OfflineSaleStatus.cancelled,
      );
    });

    test('queue state machine: attempts counted, errors and retry time kept, forbidden moves refused', () async {
      final s = await ready();
      final id = (await s.recordCompletedSale(sale())).localSaleId;
      await expectLater(
        s.transitionQueueEntry(id, OfflineQueueStatus.done),
        throwsA(isA<OfflineStorageException>()),
      );
      now = now.add(const Duration(minutes: 1));
      var q = await s.transitionQueueEntry(id, OfflineQueueStatus.inProgress);
      expect(
        [q.status, q.attemptCount, q.lastAttemptAt],
        [OfflineQueueStatus.inProgress, 1, now],
      );
      final retryAt = now.add(const Duration(minutes: 5));
      q = await s.transitionQueueEntry(
        id,
        OfflineQueueStatus.failed,
        error: 'HTTP 503',
        nextAttemptAt: retryAt,
      );
      expect(
        [q.status, q.lastError, q.nextAttemptAt],
        [OfflineQueueStatus.failed, 'HTTP 503', retryAt],
      );
      q = await s.transitionQueueEntry(id, OfflineQueueStatus.inProgress);
      expect(q.attemptCount, 2);
      q = await s.transitionQueueEntry(id, OfflineQueueStatus.done);
      expect(q.status, OfflineQueueStatus.done);
      expect((await open().getQueueEntry(id))!.attemptCount, 2);
    });
  });

  group('payments offline', () {
    test('policy: cash always; manual card/other only when approved; provider payments never, with the exact message', () {
      const strict = OfflinePaymentPolicy();
      expect(strict.allows(method: 'cash'), isTrue);
      expect(
        strict.check(method: 'card'),
        OfflinePaymentPolicy.onlineRequiredMessage,
      );
      expect(
        strict.check(method: 'other'),
        'Internet connection is required for this payment method.',
      );
      const relaxed = OfflinePaymentPolicy(
        OfflineSettings(offlineManualTenders: {'card'}),
      );
      expect(relaxed.allows(method: 'card'), isTrue);
      expect(relaxed.allows(method: 'other'), isFalse);
      for (final p in ['PINE_LABS', 'RAZORPAY', 'SOMETHING_NEW']) {
        expect(
          relaxed.check(method: 'card', provider: p),
          OfflinePaymentPolicy.onlineRequiredMessage,
          reason: p,
        );
        expect(
          relaxed.check(method: 'cash', provider: p),
          OfflinePaymentPolicy.onlineRequiredMessage,
          reason: p,
        );
      }
    });

    test('a sale with a tender not allowed offline is refused before anything is written; approving manual card in settings allows it', () async {
      final s = await ready();
      final card = sale(
        payments: const [
          OfflinePayment(
            method: 'card',
            amountMilli: 224000,
            reference: 'slip-1',
          ),
        ],
      );
      await expectLater(
        s.recordCompletedSale(card),
        throwsA(isA<OfflinePaymentNotAllowed>()),
      );
      expect(Directory('${root.path}/sales').listSync(), isEmpty);
      await s.saveSettings(
        const OfflineSettings(offlineManualTenders: {'card'}),
      );
      expect((await open().getSettings()).offlineManualTenders, {'card'});
      expect(
        (await s.recordCompletedSale(card)).status,
        OfflineSaleStatus.queued,
      );
      // A provider payment can never even be represented offline.
      expect(
        OfflinePayment.fromJson({
          'method': 'card',
          'provider': 'PINE_LABS',
          'amount_milli': 1,
        }),
        isNull,
      );
    });
  });

  group('corruption, recovery and concurrency', () {
    test('a corrupt sale file is preserved untouched and reported; it is never deleted, and bulk deletion is refused', () async {
      final s = await ready();
      final good = await s.recordCompletedSale(sale());
      final badId = generateUuidV4();
      file('sales/$badId.json').writeAsStringSync(
        '{"schema_version":1,"type":"sale","data":{"local_sale_id":"$badId","status":"QUEUED","lines":[{"oops":1}]}}',
      );
      final before = file('sales/$badId.json').readAsStringSync();
      final again = open();
      final report = await again.initialize();
      expect(report.unreadableSales, [badId]);
      expect((await again.getSales()).map((x) => x.localSaleId), [
        good.localSaleId,
      ]);
      expect(await again.getSale(badId), isNull);
      expect(again.issues.map((i) => i.path), contains('sales/$badId.json'));
      expect(file('sales/$badId.json').readAsStringSync(), before);
      await expectLater(
        again.deleteOfflineData(),
        throwsA(isA<OfflineStorageException>()),
      );
      expect(file('sales/$badId.json').existsSync(), isTrue);
      await again.clearCache();
      expect(
        file('products.json').existsSync(),
        isFalse,
        reason: 'caches may be cleared',
      );
      expect(
        file('sales/${good.localSaleId}.json').existsSync(),
        isTrue,
        reason: 'sales never are',
      );
    });

    test('sale saved but queue write failed (crash/disk error): the sale stays COMPLETED_LOCAL and the next start re-creates its queue entry', () async {
      final s = await ready();
      final queueDir = Directory('${root.path}/queue');
      await queueDir.delete();
      File('${root.path}/queue')
          .writeAsStringSync('not a directory'); // queue writes now fail
      final x = sale();
      await expectLater(
        s.recordCompletedSale(x),
        throwsA(isA<OfflineStorageException>()),
      );
      expect(
        (await open().getSale(x.localSaleId))!.status,
        OfflineSaleStatus.completedLocal,
        reason: 'the paid sale is kept',
      );
      File('${root.path}/queue').deleteSync();
      final recovered = open();
      final report = await recovered.initialize();
      expect(report.recreatedQueueEntries, [x.localSaleId]);
      expect(report.promotedToQueued, [x.localSaleId]);
      expect(
        (await recovered.getSale(x.localSaleId))!.status,
        OfflineSaleStatus.queued,
      );
      expect(
        (await recovered.getQueueEntry(x.localSaleId))!.status,
        OfflineQueueStatus.pending,
      );
    });

    test('interrupted move to synced (synced copy written, pending files not yet removed) is finished on start; orphan queue entries are reported, not deleted', () async {
      final s = await ready();
      final id = (await s.recordCompletedSale(sale())).localSaleId;
      final synced = (await s.getSale(id))!
          .copyWith(status: OfflineSaleStatus.synced, serverSaleId: 77);
      file('synced/$id.json').writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'type': 'sale',
          'data': synced.toJson(),
        }),
      );
      final orphan = generateUuidV4();
      file('queue/$orphan.json').writeAsStringSync(
        jsonEncode({
          'schema_version': 1,
          'type': 'queue',
          'data': {'local_id': orphan},
        }),
      );
      final report = await open().initialize();
      expect(report.finishedSyncMoves, [id]);
      expect(file('sales/$id.json').existsSync(), isFalse);
      expect(
        (await open().getQueueEntry(id))!.status,
        OfflineQueueStatus.done,
        reason: 'Phase 3: kept as a DONE record',
      );
      expect(report.orphanQueueEntries, [orphan]);
      expect(file('queue/$orphan.json').existsSync(), isTrue);
    });

    test('concurrent read-modify-write updates of one document never lose an update', () async {
      await open().initialize();
      final store = JsonFileStore(root)..registerType('counter', current: 1);
      await store.write('counter.json', type: 'counter', data: {'n': 0});
      await Future.wait(
        List.generate(
          100,
          (_) => store.update(
            'counter.json',
            type: 'counter',
            change: (c) => {'n': (c!['n'] as int) + 1},
          ),
        ),
      );
      expect(
        (await store.read('counter.json', type: 'counter')).data!['n'],
        100,
      );
    });

    test(
      'concurrent sales and queue updates through the service all land',
      () async {
        final s = await ready();
        final recorded = await Future.wait(
          List.generate(20, (_) => s.recordCompletedSale(sale())),
        );
        await Future.wait(
          recorded.map(
            (r) => s.transitionQueueEntry(
              r.localSaleId,
              OfflineQueueStatus.inProgress,
            ),
          ),
        );
        final entries = await open().getQueueEntries();
        expect(entries.length, 20);
        expect(
          entries.every(
            (e) =>
                e.status == OfflineQueueStatus.inProgress &&
                e.attemptCount == 1,
          ),
          isTrue,
        );
      },
    );
  });
}
