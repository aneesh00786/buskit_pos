// Phase 14G — a NEW offline sale needs a catalogue refreshed from the server
// within offlineCatalogueMaxAge (24 h). Missing / malformed timestamps are
// too old; a future timestamp is not. Online sales, sales already queued and
// their sync are untouched. Real JSON files in a temp directory; only the
// server is faked.
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_catalogue.dart';
import 'package:buskit_pos/features/offline/models/offline_context.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_catalogue_freshness.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/offline_sync_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

late Directory root;
late OfflineStorageService storage;
late DateTime now;

const scope = PosTokenScope(
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

const stale = OfflineCheckoutService.staleCatalogueMessage;

Future<void> seed({DateTime? cachedAt, bool catalogue = true}) async {
  if (catalogue) {
    await storage.saveCatalogue(
      OfflineCatalogue(
        companyId: 1,
        storeId: 213,
        cachedAt: cachedAt ?? now,
        products: const [soap],
      ),
    );
  }
  await storage.saveInventory(
    InventorySnapshot(
      syncedAt: now,
      entries: const [
        InventorySnapshotEntry(productVariationId: 1, serverQuantity: 100),
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

int _n = 0;
String uuid() =>
    '${(++_n).toRadixString(16).padLeft(8, '0')}-9a4d-4e7b-8c2a-1d5e6f7a8b9c';

OfflineCheckoutRequest request({String? id}) {
  final line = OfflineCheckoutLine.fromProduct(soap, 1);
  return OfflineCheckoutRequest(
    localSaleId: id ?? uuid(),
    scope: scope,
    lines: [line],
    payments: [
      PaymentLine(
        method: TenderMethod.cash,
        amountMilli: line.lineTotalMilli,
        tenderedMilli: line.lineTotalMilli,
      ),
    ],
  );
}

OfflineCheckoutService checkout() =>
    OfflineCheckoutService(storage, clock: () => now);

List<String> files(String dir) {
  final d = Directory('${root.path}/$dir');
  if (!d.existsSync()) return const [];
  return d.listSync().whereType<File>().map((f) => f.path).toList();
}

Future<String> rejection(Future<Object?> f) async {
  try {
    await f;
  } on OfflineCheckoutRejected catch (e) {
    return e.message;
  }
  fail('expected the sale to be refused');
}

class FakeSyncApi implements OfflineSyncApi {
  final List<String> synced = [];
  @override
  Future<OfflineSyncResult> sync(OfflineSale sale) async {
    synced.add(sale.localSaleId);
    return OfflineSyncResult(
      localSaleId: sale.localSaleId,
      serverSaleId: 100 + synced.length,
      saleNumber: 'POS-${100 + synced.length}',
      replayed: false,
    );
  }

  @override
  Future<OfflineSyncResult> resolve(
    OfflineSale sale, {
    required String reason,
    String? note,
  }) => throw UnimplementedError();
}

void main() {
  setUp(() async {
    root = await Directory.systemTemp.createTemp('pos_catalogue_age_');
    now = DateTime.utc(2026, 10, 7, 12);
    storage = OfflineStorageService(root, clock: () => now);
    await storage.initialize();
  });
  tearDown(() => root.delete(recursive: true));

  group('the rule (isOfflineCatalogueFresh)', () {
    test('24 hours, inclusive; missing = stale; future = fresh', () {
      final t = DateTime.utc(2026, 10, 7, 12);
      expect(offlineCatalogueMaxAge, const Duration(hours: 24));
      bool fresh(DateTime? at) => isOfflineCatalogueFresh(at, t);
      expect(fresh(t.subtract(const Duration(hours: 1))), isTrue);
      expect(fresh(t.subtract(const Duration(hours: 24))), isTrue);
      expect(
        fresh(t.subtract(const Duration(hours: 24, microseconds: 1))),
        isFalse,
      );
      expect(fresh(null), isFalse);
      expect(fresh(t.add(const Duration(days: 3))), isTrue);
      // Time zones do not matter (compared as instants).
      expect(
        isOfflineCatalogueFresh(
          DateTime.utc(2026, 10, 6, 12),
          DateTime.parse('2026-10-07T17:30:00+05:30'),
        ),
        isTrue,
      );
    });
  });

  group('new offline sale', () {
    test('1. a fresh catalogue allows it (recorded and queued)', () async {
      await seed(cachedAt: now.subtract(const Duration(hours: 3)));
      final sale = await checkout().complete(request());
      expect(sale.status, OfflineSaleStatus.queued);
      expect(files('sales'), hasLength(1));
      expect(files('queue'), hasLength(1));
    });

    test(
      '2. exactly at the maximum age is allowed; one second later is refused',
      () async {
        await seed(cachedAt: now.subtract(offlineCatalogueMaxAge));
        await checkout().complete(request());
        now = now.add(const Duration(seconds: 1));
        expect(await rejection(checkout().complete(request())), stale);
        expect(files('sales'), hasLength(1));
      },
    );

    test('3 / 11 / 12. a stale catalogue refuses it before anything is written, with a clear message', () async {
      await seed(cachedAt: now.subtract(const Duration(hours: 25)));
      expect(
        await rejection(checkout().complete(request())),
        'Offline catalogue is too old. Connect to the internet and refresh '
        'the catalogue before starting a new offline sale.',
      );
      expect(files('sales'), isEmpty, reason: 'nothing persisted');
      expect(files('queue'), isEmpty, reason: 'nothing queued');
      expect(stale, isNot(contains('deleted')));
      expect(stale.toLowerCase(), isNot(contains('lost')));
    });

    test('4. no catalogue (no timestamp) refuses it', () async {
      await seed(catalogue: false);
      expect(await rejection(checkout().complete(request())), stale);
      expect(files('sales'), isEmpty);
    });

    test(
      '5. a malformed or missing cached_at refuses it safely (no crash)',
      () async {
        await seed();
        final file = File('${root.path}/products.json');
        final original = file.readAsStringSync();
        for (final bad in ['not-a-date', '', null, 42]) {
          Object? patch(Object? v) => switch (v) {
            Map() => {
              for (final e in v.entries)
                e.key: e.key == 'cached_at' ? bad : patch(e.value),
            },
            List() => v.map(patch).toList(),
            _ => v,
          };
          file.writeAsStringSync(jsonEncode(patch(jsonDecode(original))));
          // A fresh storage instance: nothing memoised from the good file.
          storage = OfflineStorageService(root, clock: () => now);
          expect(await storage.getCatalogueCachedAt(), isNull, reason: '$bad');
          expect(
            await rejection(checkout().complete(request())),
            stale,
            reason: '$bad',
          );
        }
        expect(files('sales'), isEmpty);
      },
    );

    test(
      '6. a timestamp in the future (clock moved back) does not block',
      () async {
        await seed(cachedAt: now.add(const Duration(hours: 6)));
        final sale = await checkout().complete(request());
        expect(sale.status, OfflineSaleStatus.queued);
      },
    );

    test('7. online, catalogue age is ignored: the sale goes to the server unchanged', () async {
      await seed(cachedAt: now.subtract(const Duration(days: 30)));
      final server = FakeCartService();
      server.onAdd = (_) async => CartSaleFactory.sale(
        items: [lineJson(id: 1, variationId: 1)],
        total: 10,
      );
      final cart = CartController(
        server,
        offline: OfflineCartSupport(
          checkout: checkout(),
          isOffline: () => false,
          scope: () => scope,
        ),
      );
      expect(await cart.addItem(1, 1), isTrue);
      expect(
        await cart.completeSale([
          const PaymentLine(
            method: TenderMethod.cash,
            amountMilli: 10000,
            tenderedMilli: 10000,
          ),
        ]),
        isTrue,
        reason: '${cart.error?.message}',
      );
      expect(server.completeCalls, hasLength(1));
      expect(cart.completedOfflineSale, isNull);
      expect(files('sales'), isEmpty);
    });

    test('offline through the cart: refused at payment, the cart is kept and the message shown', () async {
      await seed(cachedAt: now.subtract(const Duration(days: 2)));
      final server = FakeCartService();
      final cart = CartController(
        server,
        offline: OfflineCartSupport(
          checkout: checkout(),
          isOffline: () => true,
          scope: () => scope,
        ),
      );
      // Browsing / ringing up cached products still works.
      expect(
        await cart.addItem(1, 1),
        isTrue,
        reason: '${cart.error?.message}',
      );
      expect(
        await cart.completeSale([
          const PaymentLine(
            method: TenderMethod.cash,
            amountMilli: 112000,
            tenderedMilli: 112000,
          ),
        ]),
        isFalse,
      );
      expect(cart.error!.message, stale);
      expect(cart.error!.kind, ApiErrorKind.validation);
      expect(cart.hasActiveDraftWithItems, isTrue, reason: 'items kept');
      expect(server.completeCalls, isEmpty);
      expect(files('sales'), isEmpty);
    });
  });

  group('8. sales already queued', () {
    test('stay stored, visible and syncable when the catalogue goes stale; '
        'an interrupted save still finishes', () async {
      await seed(cachedAt: now);
      final queued = await checkout().complete(request());
      now = now.add(const Duration(days: 3)); // catalogue now stale
      expect(await rejection(checkout().complete(request())), stale);

      // Still stored and visible to the existing recovery/sync screens.
      expect(
        (await storage.getSale(queued.localSaleId))!.status,
        OfflineSaleStatus.queued,
      );
      expect((await storage.getPendingSales()).map((s) => s.localSaleId), [
        queued.localSaleId,
      ]);
      expect(
        (await storage.getQueueEntry(queued.localSaleId))!.status,
        OfflineQueueStatus.pending,
      );
      // Retrying the SAME local sale id returns the recorded sale (no guard).
      final again = await checkout().complete(request(id: queued.localSaleId));
      expect(again.localSaleId, queued.localSaleId);

      // And the existing sync still sends it.
      final api = FakeSyncApi();
      final report = await OfflineSyncService(
        storage: storage,
        api: api,
        scope: () => scope,
        clock: () => now,
      ).syncNow(force: true);
      expect(api.synced, [queued.localSaleId]);
      expect(report.synced, [queued.localSaleId]);
    });
  });

  group('catalogue refresh', () {
    test('9. a successful refresh records the time and new offline sales are allowed again', () async {
      await seed(cachedAt: now.subtract(const Duration(days: 5)));
      expect(await rejection(checkout().complete(request())), stale);
      final products = FakeProductService()
        ..onSearch = (c) async =>
            page([productJson(id: 1, name: 'Soap', price: 100)]);
      now = now.add(const Duration(minutes: 10));
      final ok = await OfflineCacheService(
        storage,
        clock: () => now,
      ).refreshCatalogue(products, scope);
      expect(ok, isTrue);
      expect(await storage.getCatalogueCachedAt(), now);
      final raw = File('${root.path}/products.json').readAsStringSync();
      expect(raw, contains('"cached_at":"2026-10-07T12:10:00.000Z"'));
      expect(
        (await checkout().complete(request())).status,
        OfflineSaleStatus.queued,
      );
    });

    test(
      '10. a failed or partial refresh leaves the old time (still stale)',
      () async {
        final old = now.subtract(const Duration(days: 5));
        await seed(cachedAt: old);
        final cache = OfflineCacheService(storage, clock: () => now);
        final failing = FakeProductService()
          ..onSearch = (c) async => c.page == 1
              ? page([
                  productJson(id: 1, name: 'Soap', price: 100),
                ], totalPages: 2)
              : throw const ApiException(
                  kind: ApiErrorKind.network,
                  message: 'offline',
                );
        expect(await cache.refreshCatalogue(failing, scope), isFalse);
        expect(await storage.getCatalogueCachedAt(), old);
        final down = FakeProductService()
          ..onSearch = (c) async => throw const ApiException(
            kind: ApiErrorKind.server,
            message: 'down',
          );
        expect(await cache.refreshCatalogue(down, scope), isFalse);
        expect(await storage.getCatalogueCachedAt(), old);
        expect(await rejection(checkout().complete(request())), stale);
      },
    );

    test('reading the catalogue, searching it and recording sales never move the time', () async {
      final at = now.subtract(const Duration(hours: 2));
      await seed(cachedAt: at);
      await storage.getProducts();
      await storage.searchProducts('soap');
      await checkout().complete(request());
      now = now.add(const Duration(hours: 1));
      expect(
        await OfflineStorageService(
          root,
          clock: () => now,
        ).getCatalogueCachedAt(),
        at,
      );
    });
  });
}
