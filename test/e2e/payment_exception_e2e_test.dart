// Phase 7 — END-TO-END captured payment exceptions: the real app code
// (PosApiClient, CartController, ApiPaymentTerminalService,
// ApiPaymentRecoveryService, ApiPaymentExceptionService) against the REAL
// backend routes on the isolated test database, with the REAL Pine Labs /
// Razorpay provider modules (Razorpay refunds included) talking to in-memory
// fakes — no real payment or refund, no network beyond localhost. Two
// managers with their own PINs sign in on the cashier's device.
//
// Skipped unless PAYMENT_EXCEPTION_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/paymentExceptionE2eServer.js (local test DB only).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final cfgPath = Platform.environment['PAYMENT_EXCEPTION_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs PAYMENT_EXCEPTION_E2E_CONFIG (buskit-web test/pos/e2e/paymentExceptionE2eServer.js)'
      : null;

  late Map<String, dynamic> cfg;
  late PosApiClient cashier;
  late PosApiClient manager1;
  late PosApiClient manager2;

  Future<void> control(String path) async {
    final r = await http.post(Uri.parse('${cfg['base_url']}/__e2e$path'));
    expect(r.statusCode, 200);
  }

  Future<Map<String, dynamic>> stats() async => asMap(
    jsonDecode(
      (await http.get(Uri.parse('${cfg['base_url']}/__e2e/stats'))).body,
    ),
  )!;

  Future<PosApiClient> signIn(String salesmanId, String pin) async {
    String? token;
    final c = PosApiClient(
      baseUrl: cfg['base_url'] as String,
      tokenProvider: () => token,
    );
    final login = await c.post(
      '/auth/staff-login',
      body: {'salesman_id': salesmanId, 'pin': pin},
      token: cfg['device_token'] as String,
      notifyUnauthorized: false,
    );
    token = asString(asMap(login)!['token']);
    expect(token, isNotNull);
    return c;
  }

  Future<int> paymentRows(int saleId) async =>
      asList(asMap(await cashier.get('/sales/$saleId'))!['payments']).length;

  Future<String?> saleStatus(int saleId) async =>
      asString(asMap(await cashier.get('/sales/$saleId'))!['status']);

  /// Cashier rings up [qty] of product 2 and the customer pays with
  /// [provider]; then stock drops below [qty] before the sale is completed.
  Future<({int saleId, int attemptId, double total})> capturedStockConflict({
    required String provider,
    int qty = 2,
  }) async {
    await control('/stock/10');
    final cart = CartController(ApiCartService(cashier));
    expect(
      await cart.addItem(2, qty),
      isTrue,
      reason: '${cart.error?.message}',
    );
    final sale = cart.sale!;
    final total = sale.totals.grandTotal!;
    final attempt = await ApiPaymentTerminalService(cashier).start(
      saleId: sale.id,
      provider: provider,
      amountMilli: (total * 1000).round(),
      idempotencyKey: generateUuidV4(),
      method: provider == 'RAZORPAY' ? 'QR' : 'CARD',
    );
    await control(
      provider == 'RAZORPAY' ? '/razorpay/pay-all' : '/pinelabs/approve-all',
    );
    // Meanwhile the last units are sold elsewhere.
    await control('/stock/1');
    return (saleId: sale.id, attemptId: attempt.id, total: total);
  }

  Future<RecoverableSale> recovered(PosApiClient c, int saleId) async =>
      (await ApiPaymentRecoveryService(c).fetch(
        refresh: true,
        saleIds: [saleId],
      )).recoverable.singleWhere((r) => r.saleId == saleId);

  setUpAll(() async {
    if (cfgPath == null) return;
    cfg = asMap(jsonDecode(File(cfgPath).readAsStringSync()))!;
    cashier = await signIn(cfg['salesman_id'] as String, cfg['pin'] as String);
    try {
      await cashier.post('/shifts/open', body: {'opening_amount': 0});
    } on ApiException catch (e) {
      // Re-run against the same server: the shift is already open.
      if (e.kind != ApiErrorKind.conflict) rethrow;
    }
    final managers = asList(cfg['managers']).cast<String>();
    manager1 = await signIn(managers[0], cfg['manager_pin'] as String);
    manager2 = await signIn(managers[1], cfg['manager_pin'] as String);
  });

  group('captured payment exception E2E', skip: skip, () {
    test('SCENARIO 1 — Razorpay captured, stock conflict: completion refused, manager refunds in FULL once; no sale, no stock, draft cancelled', () async {
      await control('/razorpay/refunds/ok');
      final before = await stats();
      final x = await capturedStockConflict(provider: 'RAZORPAY');
      final r = await recovered(cashier, x.saleId);
      expect(r.state, RecoveryState.captured);
      expect(r.canComplete, isFalse);
      expect(r.blockedReason, 'STOCK_CONFLICT');
      expect(r.exception!.recommendedAction, 'REFUND_PAYMENT');

      // Completing anyway is refused by the server (no oversell).
      final cart = CartController(ApiCartService(cashier));
      expect(cart.restoreRecoveredSale(r.sale), isTrue);
      expect(
        await cart.completeSale([
          PaymentLine(
            method: TenderMethod.other,
            amountMilli: (x.total * 1000).round(),
            paymentAttemptId: x.attemptId,
          ),
        ]),
        isFalse,
      );
      cart.reset();

      final v = await ApiPaymentExceptionService(manager1).refund(x.attemptId);
      expect(v.state, 'REFUNDED');
      expect(v.refundAmount, x.total, reason: 'FULL captured amount');
      expect(v.providerRefundId, startsWith('rfnd_PX'));
      final after = await stats();
      expect(
        after['razorpay_refund_posts'],
        before['razorpay_refund_posts'] + 1,
      );
      expect(after['sold_count'], 0, reason: 'stock never deducted');
      expect(await paymentRows(x.saleId), 0, reason: 'no sale payment');
      expect(await saleStatus(x.saleId), isNot('completed'));
      final again = await ApiPaymentRecoveryService(cashier)
          .fetch(saleIds: [x.saleId]);
      expect(again.recoverable.where((s) => s.saleId == x.saleId), isEmpty);
      // Replays never refund twice.
      final replay = await ApiPaymentExceptionService(manager1)
          .refund(x.attemptId);
      expect(replay.state, 'REFUNDED');
      expect(replay.replayed, isTrue);
      expect(
        (await stats())['razorpay_refund_posts'],
        after['razorpay_refund_posts'],
      );
    });

    test('SCENARIO 2 — Pine Labs captured, stock conflict: MANUAL_REFUND_REQUIRED only; no provider refund call; never shown as refunded', () async {
      final x = await capturedStockConflict(provider: 'PINE_LABS', qty: 2);
      final r = await recovered(cashier, x.saleId);
      expect(r.exception!.recommendedAction, 'MANUAL_REFUND');
      final ex = ApiPaymentExceptionService(manager1);
      // A provider refund is refused: Pine Labs has no refund API here.
      await expectLater(
        ex.refund(x.attemptId),
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorCode,
            'code',
            'POS_PAYMENT_EXCEPTION_MANUAL_REFUND_ONLY',
          ),
        ),
      );
      final v = await ex.flagManualRefund(x.attemptId);
      expect(v.state, 'MANUAL_REFUND_REQUIRED');
      expect(v.resolution, 'MANUAL_REFUND');
      expect(v.state, isNot('REFUNDED'));
      final s = await stats();
      expect(s['pine_labs_refund_calls'], 0);
      expect(s['sold_count'], 0);
      expect(await paymentRows(x.saleId), 0);
      final again = await recovered(cashier, x.saleId);
      expect(again.exception!.state, 'MANUAL_REFUND_REQUIRED');
    });

    test('SCENARIO 3 — two managers resolve the same payment at once: exactly ONE refund at Razorpay, one exception', () async {
      await control('/razorpay/refunds/ok');
      final x = await capturedStockConflict(provider: 'RAZORPAY', qty: 2);
      // The recovery check (refresh) records the capture on the server.
      expect((await recovered(manager1, x.saleId)).exception, isNotNull);
      final before = await stats();
      final results = await Future.wait(
        [
          ApiPaymentExceptionService(manager1).refund(x.attemptId),
          ApiPaymentExceptionService(manager2).refund(x.attemptId),
        ].map((f) => f.then<Object>((v) => v, onError: (Object e) => e)),
      );
      final ok = results.whereType<PaymentExceptionView>().toList();
      expect(
        ok,
        isNotEmpty,
        reason: results
            .map(
              (e) => e is ApiException ? '${e.errorCode} ${e.message}' : '$e',
            )
            .join(' | '),
      );
      for (final v in ok) {
        expect(v.state, 'REFUNDED');
      }
      final after = await stats();
      expect(
        after['razorpay_refunds'],
        before['razorpay_refunds'] + 1,
        reason: 'never refund twice',
      );
      expect(after['sold_count'], 0);
    });

    test('SCENARIO 4 — the original cashier is refused (four-eyes, server-side); another manager then resolves; pending → check → refunded', () async {
      await control('/razorpay/refunds/pending');
      final x = await capturedStockConflict(provider: 'RAZORPAY', qty: 2);
      final mine = await recovered(cashier, x.saleId);
      expect(mine.exception!.viewerCanAct, isFalse);
      expect(mine.exception!.viewerBlockReason, 'SELF_RESOLUTION');
      final before = await stats();
      await expectLater(
        ApiPaymentExceptionService(cashier).refund(x.attemptId),
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorCode,
            'code',
            'POS_PAYMENT_EXCEPTION_SELF_RESOLUTION',
          ),
        ),
      );
      expect(
        (await stats())['razorpay_refund_posts'],
        before['razorpay_refund_posts'],
        reason: 'refused before any provider call',
      );
      final theirs = await recovered(manager2, x.saleId);
      expect(theirs.exception!.viewerCanAct, isTrue);

      final ex = ApiPaymentExceptionService(manager2);
      final pending = await ex.refund(x.attemptId);
      expect(pending.state, 'REFUND_PENDING');
      await control('/razorpay/refunds-process-all');
      final done = await ex.checkRefund(x.attemptId);
      expect(done.state, 'REFUNDED');
      final after = await stats();
      expect(after['razorpay_refunds'], before['razorpay_refunds'] + 1);
      final events = asMap(after['exception_events'])!;
      expect(events['REJECTED'], greaterThanOrEqualTo(1), reason: 'audited');
      expect(events['PROVIDER_REFUND_REQUESTED'], greaterThanOrEqualTo(1));
      expect(events['REFUND_STATUS_CHECKED'], greaterThanOrEqualTo(1));
      await control('/razorpay/refunds/ok');
    });

    test('SCENARIO 5 — app in the background while the customer pays: on return the check finds the captured payment as an exception (not completable); refund failure → retry', () async {
      // Background: the QR is paid while the POS app is not in front, and
      // the stock changes. Foreground: the same fetch the resume hook runs.
      await control('/razorpay/refunds/fail');
      final x = await capturedStockConflict(provider: 'RAZORPAY', qty: 2);
      final onResume = await ApiPaymentRecoveryService(cashier)
          .fetch(refresh: true, saleIds: [x.saleId]);
      final r = onResume.recoverable.singleWhere((s) => s.saleId == x.saleId);
      expect(r.state, RecoveryState.captured);
      expect(r.canComplete, isFalse);
      expect(r.completionPayments, isEmpty);
      expect(r.exception!.state, 'OPEN');

      final ex = ApiPaymentExceptionService(manager1);
      final failed = await ex.refund(x.attemptId);
      expect(failed.state, 'REFUND_FAILED');
      await control('/razorpay/refunds/ok');
      final retried = await ex.retryRefund(x.attemptId);
      expect(retried.state, 'REFUNDED');
      expect((await stats())['sold_count'], 0);
      expect(await paymentRows(x.saleId), 0);
    });
  });
}
