// Offline POS Phase 4 — END-TO-END manager resolution: the real app code
// against the REAL backend routes on the isolated test database.
//
// Skipped unless OFFLINE_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/offlineSyncE2eServer.js (local test DB only).
// Run this file against a FRESH server (it expects no earlier sales).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
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

void main() {
  final cfgPath = Platform.environment['OFFLINE_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs OFFLINE_E2E_CONFIG (buskit-web test/pos/e2e/offlineSyncE2eServer.js)'
      : null;

  test(
    'cashier sells offline -> shift closed online -> sync fails -> manager resolves -> ONE server sale, original cashier/shift, shift stays closed',
    () async {
      final cfg = asMap(jsonDecode(File(cfgPath!).readAsStringSync()))!;
      String? token;
      final client = PosApiClient(
        baseUrl: cfg['base_url'] as String,
        tokenProvider: () => token,
      );
      final root = await Directory.systemTemp.createTemp(
        'pos_offline_res_e2e_',
      );
      addTearDown(() => root.delete(recursive: true));

      Future<String> login(String staff) async {
        final r = await client.post(
          '/auth/staff-login',
          body: {'salesman_id': staff, 'pin': cfg['pin']},
          token: cfg['device_token'] as String,
          notifyUnauthorized: false,
        );
        return asString(asMap(r)!['token'])!;
      }

      // 1-3. Cashier signs in, opens the shift, loads catalogue + stock.
      final cashier = cfg['salesman_id'] as String;
      final manager = cfg['manager_salesman_id'] as String;
      token = await login(cashier);
      PosTokenScope scope = PosTokenScope.fromToken(token)!;
      final shiftId = asInt(
        asMap(
          await client.post('/shifts/open', body: {'opening_amount': 0}),
        )!['id'],
      )!;
      final storage = OfflineStorageService(root);
      await storage.initialize();
      final offline = OfflineServices(
        storage,
        syncApi: ApiOfflineSyncApi(client),
        scope: () => scope,
      );
      await offline.cache.recordShift(scope: scope, shiftId: shiftId);
      expect(
        await offline.cache.refreshCatalogue(ApiProductService(client), scope),
        isTrue,
      );

      // 4-6. Offline cash sale -> QUEUED.
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
        await cart.addItem(2, 2),
        isTrue,
        reason: '${cart.error?.message}',
      );
      final total = (cart.sale!.totals.grandTotal! * 1000).round();
      expect(
        await cart.completeSale([
          PaymentLine(
            method: TenderMethod.cash,
            amountMilli: total,
            tenderedMilli: total,
          ),
        ]),
        isTrue,
      );
      final local = cart.completedOfflineSale!;
      expect(local.status, OfflineSaleStatus.queued);

      // 7. The shift is closed through the normal server flow.
      await client.post('/shifts/$shiftId/close', body: {'closing_amount': 0});

      // 8-10. Reconnect: the automatic sync is refused — SYNC_FAILED.
      isOffline = false;
      final run = await offline.sync!.syncNow();
      expect(run.failed, [local.localSaleId]);
      final failed = (await storage.getSale(local.localSaleId))!;
      expect(failed.status, OfflineSaleStatus.syncFailed);
      expect(failed.lastErrorCode, 'OFFLINE_SHIFT_INVALID');
      expect(
        failed.lastError,
        'Could not sync this sale because the original shift is no longer valid.',
      );

      // The sale's own cashier cannot resolve it — even holding every
      // permission (this fixture's role) — the server's four-eyes rule.
      final denied = await offline.sync!.resolve(
        local.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(denied.ok, isFalse);
      expect(
        denied.message,
        'The cashier who made this sale cannot resolve it; another manager must authorize it.',
      );
      expect(
        (await storage.getSale(local.localSaleId))!.status,
        OfflineSaleStatus.syncFailed,
      );
      expect(
        (await storage.getSale(local.localSaleId))!.lastErrorCode,
        'OFFLINE_SHIFT_INVALID',
        reason: 'still resolvable',
      );

      // 11-13. The manager signs in on the same device and reviews the sale.
      token = await login(manager);
      scope = PosTokenScope.fromToken(token)!;
      final me = asMap(await client.get('/auth/me'))!;
      expect(asList(me['permissions']), contains('sales.resolve_offline'));
      final review = (await storage.getSale(local.localSaleId))!;
      expect(offlineNeedsManagerResolution(review, manager), isTrue);

      // 14-17. SHIFT_CLOSED resolution.
      final out = await offline.sync!.resolve(
        local.localSaleId,
        reason: OfflineResolutionReason.shiftClosed,
      );
      expect(out.ok, isTrue, reason: out.message);

      // 18-21. Attribution, resolver, local state, queue.
      final synced = (await storage.getSale(local.localSaleId))!;
      expect(synced.status, OfflineSaleStatus.synced);
      expect(synced.salesmanId, cashier);
      expect(synced.shiftId, shiftId);
      expect(synced.resolvedBy, manager);
      expect(synced.resolutionReason, 'SHIFT_CLOSED');
      expect(
        (await storage.getQueueEntry(local.localSaleId))!.status,
        OfflineQueueStatus.done,
      );

      final sale = asMap(await client.get('/sales/${synced.serverSaleId}'))!;
      expect(sale['status'], 'completed');
      expect(sale['shift_id'], shiftId);
      expect(sale['register_id'], cfg['register_id']);
      final shift = asMap(await client.get('/shifts/$shiftId'))!;
      expect(shift['status'], 'closed', reason: 'never reopened');

      // 22. Exactly one server sale, attributed to the cashier.
      final completed = asList(
        await client.get('/sales', query: {'status': 'completed'}),
      );
      expect(completed.length, 1);
      expect(asMap(completed.single)!['salesman_id'], cashier);
      expect(asMap(completed.single)!['device_id'], cfg['device_id']);

      // A retry (lost response) returns the same sale; still one.
      final retry = await ApiOfflineSyncApi(client)
          .resolve(failed, reason: 'SHIFT_CLOSED');
      expect(retry.serverSaleId, synced.serverSaleId);
      expect(retry.replayed, isTrue);
      expect(
        asList(await client.get('/sales', query: {'status': 'completed'}))
            .length,
        1,
      );
      client.close();
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
