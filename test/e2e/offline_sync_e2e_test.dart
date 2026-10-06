// Offline POS Phase 3 — END-TO-END: the real app code (PosApiClient, cache,
// CartController offline checkout, JSON storage, OfflineSyncService) against
// the REAL backend routes on the isolated test database.
//
// Skipped unless OFFLINE_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/offlineSyncE2eServer.js (local test DB only):
//   node test/pos/e2e/offlineSyncE2eServer.js /tmp/e2e.json &
//   OFFLINE_E2E_CONFIG=/tmp/e2e.json flutter test test/e2e/offline_sync_e2e_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/offline/models/offline_queue_entry.dart';
import 'package:buskit_pos/features/offline/models/offline_sale.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:buskit_pos/features/offline/offline_sync_service.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// Forwards to the real network; can LOSE the response of the next sync call
/// AFTER the server has processed it (the "unknown outcome" case).
class DroppingClient extends http.BaseClient {
  DroppingClient(this._inner);
  final http.Client _inner;
  bool dropNextSync = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final res = await _inner.send(request);
    if (dropNextSync && request.url.path.endsWith('/offline-sales/sync')) {
      dropNextSync = false;
      await res.stream.drain<void>();
      throw http.ClientException('connection lost after the request');
    }
    return res;
  }
}

void main() {
  final cfgPath = Platform.environment['OFFLINE_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs OFFLINE_E2E_CONFIG (buskit-web test/pos/e2e/offlineSyncE2eServer.js)'
      : null;

  test(
    'online -> offline sale -> reconnect -> sync -> server sale; lost response replayed; stock conflict kept as SYNC_FAILED',
    () async {
      final cfg = asMap(jsonDecode(File(cfgPath!).readAsStringSync()))!;
      final wire = DroppingClient(http.Client());
      String? staffToken;
      final client = PosApiClient(
        baseUrl: cfg['base_url'] as String,
        httpClient: wire,
        tokenProvider: () => staffToken,
      );
      final root = await Directory.systemTemp.createTemp('pos_offline_e2e_');
      addTearDown(() => root.delete(recursive: true));

      // 1-2. Login (device token -> staff PIN) and open the shift (online).
      final login = await client.post(
        '/auth/staff-login',
        body: {'salesman_id': cfg['salesman_id'], 'pin': cfg['pin']},
        token: cfg['device_token'] as String,
        notifyUnauthorized: false,
      );
      staffToken = asString(asMap(login)!['token']);
      final scope = PosTokenScope.fromToken(staffToken)!;
      expect(scope.deviceId, cfg['device_id']);
      final shift = asMap(
        await client.post('/shifts/open', body: {'opening_amount': 0}),
      )!;
      final shiftId = asInt(shift['id'])!;

      final storage = OfflineStorageService(root);
      await storage.initialize();
      final offline = OfflineServices(
        storage,
        syncApi: ApiOfflineSyncApi(client),
        scope: () => scope,
      );
      await offline.cache.recordShift(scope: scope, shiftId: shiftId);

      // 3-4. Load catalogue + stock from the server.
      expect(
        await offline.cache.refreshCatalogue(ApiProductService(client), scope),
        isTrue,
      );
      expect((await storage.getStockLevels())[2]!.serverQuantity, 100);

      // 5-8. Network gone: local cart, cash, saved QUEUED, local stock drops.
      var isOffline = true;
      final cart = CartController(
        ApiCartService(client),
        offline: OfflineCartSupport(
          checkout: offline.checkout,
          isOffline: () => isOffline,
          scope: () => scope,
        ),
      );
      expect(
        await cart.addItem(2, 3),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final total = (cart.sale!.totals.grandTotal! * 1000).round();
      expect(
        await cart.completeSale([
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: total,
            tenderedMilli: total + 10000,
          ),
        ]),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final local = cart.completedOfflineSale!;
      expect(local.status, OfflineSaleStatus.queued);
      expect((await storage.getStockLevels())[2]!.availableQuantity, 97);

      // 9-19. Back online: sync.
      isOffline = false;
      final report = await offline.sync!.syncNow();
      expect(report.synced, [
        local.localSaleId,
      ], reason: 'failed: ${report.failed}');
      final synced = (await storage.getSale(local.localSaleId))!;
      expect(synced.status, OfflineSaleStatus.synced);
      expect(synced.serverSaleId, isNotNull);
      expect(
        (await storage.getQueueEntry(local.localSaleId))!.status,
        OfflineQueueStatus.done,
      );

      final serverSale = asMap(
        await client.get('/sales/${synced.serverSaleId}'),
      )!;
      expect(serverSale['status'], 'completed');
      expect(serverSale['shift_id'], shiftId);
      expect(serverSale['sale_number'], synced.serverSaleNumber);
      expect(
        ((serverSale['totals'] as Map)['grand_total'] as num) * 1000,
        total,
      );
      final items = asList(serverSale['items']);
      expect(items.length, 1);
      expect(asMap(items.single)!['quantity'], 3);
      final pay = asMap(asList(serverSale['payments']).single)!;
      expect(pay['method'], 'cash');
      final product = asMap(await client.get('/products/2'))!;
      expect(
        asMap(product['stock'])!['current_stock'],
        97,
        reason: 'server deducted',
      );

      // 20-21. History refresh: the sale appears ONCE on the server.
      Future<List<Object?>> list() async =>
          asList(await client.get('/sales', query: {'status': 'completed'}));
      var sales = await list();
      expect(
        sales.where((s) => asMap(s)!['id'] == synced.serverSaleId).length,
        1,
      );
      expect(sales.length, 1);
      await offline.cache.refreshCatalogue(ApiProductService(client), scope);
      expect(
        (await storage.getStockLevels())[2]!.availableQuantity,
        97,
        reason: 'not double-counted after refresh',
      );

      // Lost response: the server creates the sale, the device never hears.
      isOffline = true;
      expect(
        await cart.addItem(4, 1),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final t2 = (cart.sale!.totals.grandTotal! * 1000).round();
      expect(
        await cart.completeSale([
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: t2,
            tenderedMilli: t2,
          ),
        ]),
        isTrue,
      );
      final second = cart.completedOfflineSale!;
      cart.acknowledgeOfflineCompletion();
      isOffline = false;
      wire.dropNextSync = true;
      final lost = await offline.sync!.syncNow();
      expect(lost.retryLater, [second.localSaleId]);
      expect(
        (await storage.getSale(second.localSaleId))!.status,
        OfflineSaleStatus.queued,
      );
      expect((await list()).length, 2, reason: 'the server DID create it');
      final retried = await offline.sync!.syncNow(force: true);
      expect(retried.synced, [second.localSaleId]);
      sales = await list();
      expect(sales.length, 2, reason: 'no duplicate after the retry');
      final secondSynced = (await storage.getSale(second.localSaleId))!;
      expect(
        sales.where((s) => asMap(s)!['id'] == secondSynced.serverSaleId).length,
        1,
      );

      // Stock conflict: cached 97, offline sale of 7, an online sale takes 92.
      isOffline = true;
      expect(
        await cart.addItem(2, 7),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final t3 = (cart.sale!.totals.grandTotal! * 1000).round();
      expect(
        await cart.completeSale([
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: t3,
            tenderedMilli: t3,
          ),
        ]),
        isTrue,
      );
      final conflicted = cart.completedOfflineSale!;
      cart.acknowledgeOfflineCompletion();
      isOffline = false;
      final draft = asMap(await client.post('/sales', body: {}))!;
      final withItem = asMap(
        await client.post(
          '/sales/${draft['id']}/items',
          body: {
            'product_variation_id': 2,
            'quantity': 92,
            'expected_version': draft['version'],
          },
        ),
      )!;
      final onlineTotal = (withItem['totals'] as Map)['grand_total'];
      await client.post(
        '/sales/${draft['id']}/complete',
        body: {
          'expected_version': withItem['version'],
          'idempotency_key': generateUuidV4(),
          'payments': [
            {
              'method': 'cash',
              'amount': onlineTotal,
              'tendered_amount': onlineTotal,
            },
          ],
        },
      );
      final before = (await list()).length;
      final conflictRun = await offline.sync!.syncNow();
      expect(conflictRun.failed, [conflicted.localSaleId]);
      final failed = (await storage.getSale(conflicted.localSaleId))!;
      expect(failed.status, OfflineSaleStatus.syncFailed);
      expect(
        failed.lastError,
        'Could not sync this sale because stock is no longer available.',
      );
      expect(failed.lastErrorCode, 'OFFLINE_STOCK_CONFLICT');
      expect(
        (await storage.getQueueEntry(conflicted.localSaleId))!.status,
        OfflineQueueStatus.failed,
      );
      expect((await storage.getPendingSales()).map((s) => s.localSaleId), [
        conflicted.localSaleId,
      ], reason: 'kept for resolution');
      expect((await list()).length, before, reason: 'no partial sale');
      final after = asMap(await client.get('/products/2'))!;
      expect(
        asMap(after['stock'])!['current_stock'],
        5,
        reason: 'never negative, nothing deducted',
      );

      client.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
