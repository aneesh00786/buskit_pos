// Phase 6 — END-TO-END payment recovery after an app restart: the real app
// code (PosApiClient, CartController, ApiPaymentTerminalService,
// ApiPaymentRecoveryService, JSON storage reminders) against the REAL backend
// routes on the isolated test database, with the REAL Pine Labs / Razorpay
// provider modules talking to in-memory fakes (no real payment, no network
// beyond localhost). A "crash" = every app object is dropped and rebuilt;
// only the device's files and the server remain.
//
// Skipped unless PAYMENT_RECOVERY_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/paymentRecoveryE2eServer.js (local test DB only).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/offline/offline_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final cfgPath = Platform.environment['PAYMENT_RECOVERY_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs PAYMENT_RECOVERY_E2E_CONFIG (buskit-web test/pos/e2e/paymentRecoveryE2eServer.js)'
      : null;

  late Map<String, dynamic> cfg;
  late Directory root;
  String? token;
  late PosApiClient client;

  Future<void> control(String path) async {
    final r = await http.post(Uri.parse('${cfg['base_url']}/__e2e$path'));
    expect(r.statusCode, 200);
  }

  Future<Map<String, dynamic>> stats() async => asMap(
    jsonDecode(
      (await http.get(Uri.parse('${cfg['base_url']}/__e2e/stats'))).body,
    ),
  )!;

  /// A fresh "app": new client, controllers and storage objects (same files).
  ({
    CartController cart,
    OfflineStorageService storage,
    PaymentRecoveryService recovery,
    PaymentTerminalService terminal,
  })
  app() {
    client = PosApiClient(
      baseUrl: cfg['base_url'] as String,
      tokenProvider: () => token,
    );
    return (
      cart: CartController(ApiCartService(client)),
      storage: OfflineStorageService(root),
      recovery: ApiPaymentRecoveryService(client),
      terminal: ApiPaymentTerminalService(client),
    );
  }

  Future<int> stockOf(int pv) async => (asDouble(
    asMap(asMap(await client.get('/products/$pv'))!['stock'])!['current_stock'],
  )!).round();

  Future<int> paymentRows(int saleId) async =>
      asList(asMap(await client.get('/sales/$saleId'))!['payments']).length;

  /// Rings up [qty] of product 2 and starts a provider payment the way the
  /// pay screen does (reminder first, then the attempt).
  Future<({int saleId, PaymentAttempt attempt, int stockBefore})>
  sellWithProvider(
    ({
      CartController cart,
      OfflineStorageService storage,
      PaymentRecoveryService recovery,
      PaymentTerminalService terminal,
    })
    a, {
    required String provider,
    required String method,
    int qty = 2,
  }) async {
    final stockBefore = await stockOf(2);
    expect(
      await a.cart.addItem(2, qty),
      isTrue,
      reason: '${a.cart.error?.message}',
    );
    final sale = a.cart.sale!;
    final total = (sale.totals.grandTotal! * 1000).round();
    await a.storage.addPaymentRecoveryMarker(sale.id);
    final attempt = await a.terminal.start(
      saleId: sale.id,
      provider: provider,
      amountMilli: total,
      idempotencyKey: generateUuidV4(),
      method: method,
    );
    return (saleId: sale.id, attempt: attempt, stockBefore: stockBefore);
  }

  setUpAll(() async {
    if (cfgPath == null) return;
    cfg = asMap(jsonDecode(File(cfgPath).readAsStringSync()))!;
    root = await Directory.systemTemp.createTemp('pos_rec_e2e_');
    client = PosApiClient(
      baseUrl: cfg['base_url'] as String,
      tokenProvider: () => token,
    );
    final login = await client.post(
      '/auth/staff-login',
      body: {'salesman_id': cfg['salesman_id'], 'pin': cfg['pin']},
      token: cfg['device_token'] as String,
      notifyUnauthorized: false,
    );
    token = asString(asMap(login)!['token']);
    await client.post('/shifts/open', body: {'opening_amount': 0});
  });
  tearDownAll(() async {
    if (cfgPath != null) await root.delete(recursive: true);
  });

  group('payment recovery E2E', skip: skip, () {
    test('SCENARIO 1 — Pine Labs captured, app crashes, restart: recovery -> resume -> ONE sale, ONE payment, stock once, ONE terminal transaction', () async {
      var a = app();
      await a.storage.initialize();
      final s = await sellWithProvider(
        a,
        provider: 'PINE_LABS',
        method: 'CARD',
      );
      expect(s.attempt.status, AttemptStatus.pending);
      await control(
        '/pinelabs/approve-all',
      ); // the customer pays on the terminal
      // CRASH: nothing of the old app survives except its files.
      a = app();
      await a.storage.initialize();
      final markers = await a.storage.getPaymentRecoveryMarkers();
      expect(markers, [s.saleId]);
      final found = await a.recovery.fetch(refresh: true, saleIds: markers);
      final r = found.recoverable.singleWhere((x) => x.saleId == s.saleId);
      expect(r.state, RecoveryState.captured);
      expect(r.canComplete, isTrue);
      expect(r.completionPayments.single.paymentAttemptId, s.attempt.id);
      expect(a.cart.restoreRecoveredSale(r.sale), isTrue);
      expect(
        await a.cart.completeSale(r.completionPayments),
        isTrue,
        reason: '${a.cart.error?.message}',
      );
      await a.storage.removePaymentRecoveryMarker(s.saleId);
      expect(await paymentRows(s.saleId), 1);
      expect(await stockOf(2), s.stockBefore - 2);
      expect((await stats())['pine_labs_uploads'], 1);
      final again = await a.recovery.fetch(saleIds: [s.saleId]);
      expect(again.recoverable.where((x) => x.saleId == s.saleId), isEmpty);
      expect(again.resolved.single.completed, isTrue);
    });

    test('SCENARIO 2 — Razorpay QR captured, restart: recover -> complete -> one sale/payment/stock deduction, ONE QR', () async {
      var a = app();
      final before = (await stats())['razorpay_qr_creates'] as int;
      final s = await sellWithProvider(
        a,
        provider: 'RAZORPAY',
        method: 'QR',
        qty: 1,
      );
      await control('/razorpay/pay-all');
      a = app();
      final r = (await a.recovery.fetch(
        refresh: true,
        saleIds: [s.saleId],
      )).recoverable.singleWhere((x) => x.saleId == s.saleId);
      expect(r.state, RecoveryState.captured);
      expect(a.cart.restoreRecoveredSale(r.sale), isTrue);
      expect(
        await a.cart.completeSale(r.completionPayments),
        isTrue,
        reason: '${a.cart.error?.message}',
      );
      expect(await paymentRows(s.saleId), 1);
      expect(await stockOf(2), s.stockBefore - 1);
      expect((await stats())['razorpay_qr_creates'], before + 1);
    });

    test('SCENARIO 3 — payment still pending after restart: check -> still pending; no second payment can be started; cancel', () async {
      var a = app();
      final s = await sellWithProvider(
        a,
        provider: 'PINE_LABS',
        method: 'CARD',
        qty: 1,
      );
      final uploads = (await stats())['pine_labs_uploads'];
      a = app();
      for (var i = 0; i < 2; i++) {
        final r = (await a.recovery.fetch(refresh: true)).recoverable
            .singleWhere((x) => x.saleId == s.saleId);
        expect(r.state, RecoveryState.pending);
        expect(r.canComplete, isFalse);
      }
      expect(
        a.cart.restoreRecoveredSale(
          (await a.recovery.fetch()).recoverable
              .singleWhere((x) => x.saleId == s.saleId)
              .sale,
        ),
        isTrue,
      );
      final total = (a.cart.sale!.totals.grandTotal! * 1000).round();
      await expectLater(
        a.terminal.start(
          saleId: s.saleId,
          provider: 'PINE_LABS',
          amountMilli: total,
          idempotencyKey: generateUuidV4(),
        ),
        throwsA(anything),
        reason: 'the open payment reserves the balance: no double charge',
      );
      expect((await stats())['pine_labs_uploads'], uploads);
      await a.recovery.cancelAttempt(s.attempt.id);
      final after = (await a.recovery.fetch()).recoverable.singleWhere(
        (x) => x.saleId == s.saleId,
      );
      expect(after.state, RecoveryState.cancelled);
      a.cart.reset();
    });

    test('SCENARIO 4 — payment failed, restart: recover -> retry (new attempt) -> captured -> complete', () async {
      var a = app();
      await control('/pinelabs/reject-uploads');
      final stockBefore = await stockOf(2);
      expect(await a.cart.addItem(2, 1), isTrue);
      final saleId = a.cart.sale!.id;
      final total = (a.cart.sale!.totals.grandTotal! * 1000).round();
      await expectLater(
        a.terminal.start(
          saleId: saleId,
          provider: 'PINE_LABS',
          amountMilli: total,
          idempotencyKey: generateUuidV4(),
        ),
        throwsA(anything),
      );
      await control('/pinelabs/accept-uploads');
      a = app();
      final r = (await a.recovery.fetch()).recoverable.singleWhere(
        (x) => x.saleId == saleId,
      );
      expect(r.state, RecoveryState.failed);
      expect(r.completionPayments, isEmpty);
      expect(a.cart.restoreRecoveredSale(r.sale), isTrue);
      final retry = await a.terminal.start(
        saleId: saleId,
        provider: 'PINE_LABS',
        amountMilli: total,
        idempotencyKey: generateUuidV4(),
      );
      expect(retry.id, isNot(r.attempts.single.attempt.id));
      await control('/pinelabs/approve-all');
      final captured = await a.terminal.refresh(retry.id);
      expect(captured.status, AttemptStatus.captured);
      final ready = (await a.recovery.fetch()).recoverable.singleWhere(
        (x) => x.saleId == saleId,
      );
      expect(
        await a.cart.completeSale(ready.completionPayments),
        isTrue,
        reason: '${a.cart.error?.message}',
      );
      expect(await paymentRows(saleId), 1);
      expect(await stockOf(2), stockBefore - 1);
    });

    test('SCENARIO 5 — two concurrent completions of the recovered sale: exactly one sale, one payment, one stock deduction', () async {
      final a = app();
      final s = await sellWithProvider(
        a,
        provider: 'PINE_LABS',
        method: 'CARD',
        qty: 3,
      );
      await control('/pinelabs/approve-all');
      final r = (await a.recovery.fetch(refresh: true)).recoverable
          .singleWhere((x) => x.saleId == s.saleId);
      final c1 = app().cart;
      final c2 = app().cart;
      expect(
        c1.restoreRecoveredSale(r.sale) && c2.restoreRecoveredSale(r.sale),
        isTrue,
      );
      final results = await Future.wait([
        c1.completeSale(r.completionPayments),
        c2.completeSale(r.completionPayments),
      ]);
      expect(
        results.where((ok) => ok).length,
        1,
        reason: 'one wins; the other is refused (already completed)',
      );
      expect(await paymentRows(s.saleId), 1);
      expect(await stockOf(2), s.stockBefore - 3);
      final completed = asList(
        await client.get('/sales', query: {'status': 'completed'}),
      );
      expect(completed.where((x) => asMap(x)!['id'] == s.saleId).length, 1);
    });
  });
}
