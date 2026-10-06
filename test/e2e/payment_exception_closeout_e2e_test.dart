// Phase 8 — END-TO-END Pine Labs manual refund close-out and the
// "capture status unknown" refusal: the real app code (PosApiClient,
// CartController, ApiPaymentTerminalService, ApiPaymentRecoveryService,
// ApiPaymentExceptionService) against the REAL backend routes on the
// isolated test database, with the REAL Pine Labs / Razorpay provider
// modules talking to in-memory fakes — no real payment or refund, no network
// beyond localhost. Two managers with their own PINs sign in on the cashier's
// device.
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
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
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

  int eventCount(Map<String, dynamic> s, String action) =>
      asInt(asMap(s['exception_events'])?[action]) ?? 0;

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

  Future<String?> saleStatus(int saleId) async =>
      asString(asMap(await cashier.get('/sales/$saleId'))!['status']);

  Future<String?> attemptStatus(int attemptId) async => asString(
    asMap(await cashier.get('/payment-attempts/$attemptId'))!['status'],
  );

  /// Cashier rings up 2 of product 2; the customer pays with [provider]
  /// ([pay] false: the payment is made but nobody has asked the provider
  /// yet); then stock drops to 1 before the sale is completed.
  Future<({int saleId, int attemptId, double total})> capturedStockConflict({
    required String provider,
    bool pay = true,
  }) async {
    await control('/stock/10');
    final cart = CartController(ApiCartService(cashier));
    expect(await cart.addItem(2, 2), isTrue, reason: '${cart.error?.message}');
    final sale = cart.sale!;
    final total = sale.totals.grandTotal!;
    final attempt = await ApiPaymentTerminalService(cashier).start(
      saleId: sale.id,
      provider: provider,
      amountMilli: (total * 1000).round(),
      idempotencyKey: generateUuidV4(),
      method: provider == 'RAZORPAY' ? 'QR' : 'CARD',
    );
    if (pay) {
      await control(
        provider == 'RAZORPAY' ? '/razorpay/pay-all' : '/pinelabs/approve-all',
      );
    }
    await control('/stock/1');
    return (saleId: sale.id, attemptId: attempt.id, total: total);
  }

  Future<RecoverableSale> recovered(PosApiClient c, int saleId) async =>
      (await ApiPaymentRecoveryService(c).fetch(
        refresh: true,
        saleIds: [saleId],
      )).recoverable.singleWhere((r) => r.saleId == saleId);

  /// A Pine Labs capture that cannot complete, flagged MANUAL_REFUND_REQUIRED.
  Future<({int saleId, int attemptId, double total})> flagged() async {
    final x = await capturedStockConflict(provider: 'PINE_LABS');
    expect((await recovered(manager1, x.saleId)).exception!.state, 'OPEN');
    final f = await ApiPaymentExceptionService(manager1)
        .flagManualRefund(x.attemptId);
    expect(f.state, 'MANUAL_REFUND_REQUIRED');
    return x;
  }

  setUpAll(() async {
    if (cfgPath == null) return;
    cfg = asMap(jsonDecode(File(cfgPath).readAsStringSync()))!;
    cashier = await signIn(cfg['salesman_id'] as String, cfg['pin'] as String);
    try {
      await cashier.post('/shifts/open', body: {'opening_amount': 0});
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.conflict) rethrow;
    }
    final managers = asList(cfg['managers']).cast<String>();
    manager1 = await signIn(managers[0], cfg['manager_pin'] as String);
    manager2 = await signIn(managers[1], cfg['manager_pin'] as String);
  });

  group('Pine Labs manual refund close-out E2E', skip: skip, () {
    test('SCENARIO 1 — Pine Labs captured, stock conflict, flagged; the manager refunds outside the POS and records the slip: payment REFUNDED, draft cancelled, no provider call, audited, no longer actionable', () async {
      final x = await flagged();
      final r = await recovered(manager2, x.saleId);
      expect(r.exception!.state, 'MANUAL_REFUND_REQUIRED');
      expect(r.exception!.viewerCanAct, isTrue);
      expect(r.exception!.originalCashier, cfg['salesman_id']);
      expect(r.exception!.capturedAt, isNotNull);
      final before = await stats();

      final v = await ApiPaymentExceptionService(manager2).completeManualRefund(
        x.attemptId,
        reference: 'PL-SLIP-E2E-1',
        note: 'refunded on the terminal',
      );
      expect(v.state, 'REFUNDED');
      expect(v.isManualRefund, isTrue);
      expect(v.manualRefundReference, 'PL-SLIP-E2E-1');
      expect(v.providerRefundId, isNull, reason: 'never a provider refund id');
      expect(v.manualRefundCompletedBy, asList(cfg['managers'])[1]);

      expect(await attemptStatus(x.attemptId), 'REFUNDED');
      expect(await saleStatus(x.saleId), 'canceled');
      final after = await stats();
      expect(
        after['pine_labs_requests'],
        before['pine_labs_requests'],
        reason: 'Pine Labs never called',
      );
      expect(after['pine_labs_refund_calls'], 0);
      expect(after['sold_count'], 0, reason: 'stock never deducted');
      expect(
        eventCount(after, 'MANUAL_REFUND_COMPLETED'),
        eventCount(before, 'MANUAL_REFUND_COMPLETED') + 1,
      );
      final again = await ApiPaymentRecoveryService(cashier)
          .fetch(saleIds: [x.saleId]);
      expect(again.recoverable.where((s) => s.saleId == x.saleId), isEmpty);
    });

    test('SCENARIO 2 — the original cashier cannot close it out (403 SELF_RESOLUTION, audited); a manager then can', () async {
      final x = await flagged();
      final before = await stats();
      await expectLater(
        ApiPaymentExceptionService(cashier)
            .completeManualRefund(x.attemptId, reference: 'PL-SELF'),
        throwsA(
          isA<ApiException>()
              .having((e) => e.statusCode, 'status', 403)
              .having(
                (e) => e.errorCode,
                'code',
                'POS_PAYMENT_EXCEPTION_SELF_RESOLUTION',
              ),
        ),
      );
      expect(await attemptStatus(x.attemptId), 'CAPTURED');
      expect(
        eventCount(await stats(), 'REJECTED'),
        eventCount(before, 'REJECTED') + 1,
      );
      final v = await ApiPaymentExceptionService(manager1)
          .completeManualRefund(x.attemptId, reference: 'PL-SLIP-E2E-2');
      expect(v.state, 'REFUNDED');
    });

    test('SCENARIO 3 — two managers submit at the same moment: ONE state transition; the other gets the existing result', () async {
      final x = await flagged();
      final before = await stats();
      final results = await Future.wait([
        ApiPaymentExceptionService(manager1)
            .completeManualRefund(x.attemptId, reference: 'PL-RACE-1'),
        ApiPaymentExceptionService(manager2)
            .completeManualRefund(x.attemptId, reference: 'PL-RACE-2'),
      ]);
      expect(results.where((r) => r.replayed).length, 1);
      expect(
        results.map((r) => r.manualRefundReference).toSet().length,
        1,
        reason: 'one reference recorded',
      );
      expect(
        eventCount(await stats(), 'MANUAL_REFUND_COMPLETED'),
        eventCount(before, 'MANUAL_REFUND_COMPLETED') + 1,
      );
    });

    test('SCENARIO 4 — the same request twice: one transition, the repeat is a safe replay', () async {
      final x = await flagged();
      final ex = ApiPaymentExceptionService(manager1);
      final a = await ex.completeManualRefund(x.attemptId, reference: 'PL-DUP');
      final b = await ex.completeManualRefund(x.attemptId, reference: 'PL-DUP');
      expect(a.replayed, isFalse);
      expect(b.replayed, isTrue);
      expect(b.manualRefundReference, 'PL-DUP');
      expect(await attemptStatus(x.attemptId), 'REFUNDED');
    });

    test('SCENARIO 5 — Razorpay keeps its provider refund flow; the manual close-out refuses it', () async {
      await control('/razorpay/refunds/ok');
      final x = await capturedStockConflict(provider: 'RAZORPAY');
      expect((await recovered(manager1, x.saleId)).exception!.state, 'OPEN');
      final ex = ApiPaymentExceptionService(manager1);
      await expectLater(
        ex.completeManualRefund(x.attemptId, reference: 'PL-NOPE'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorCode,
            'code',
            'POS_PAYMENT_EXCEPTION_MANUAL_CLOSEOUT_NOT_ALLOWED',
          ),
        ),
      );
      final before = await stats();
      final v = await ex.refund(x.attemptId);
      expect(v.state, 'REFUNDED');
      expect(v.refundMethod, 'PROVIDER');
      expect(v.providerRefundId, startsWith('rfnd_PX'));
      expect(
        (await stats())['razorpay_refunds'],
        before['razorpay_refunds'] + 1,
      );
    });

    test('SCENARIO 6 — capture not known to the server: clear refusal (CHECK_PAYMENT, no refund sent) -> Check Payment (refresh) -> captured -> refund works', () async {
      await control('/razorpay/refunds/ok');
      // The customer has paid, but nobody has asked Razorpay yet.
      final x = await capturedStockConflict(provider: 'RAZORPAY');
      final before = await stats();
      final ex = ApiPaymentExceptionService(manager1);
      await expectLater(
        ex.refund(x.attemptId),
        throwsA(
          isA<ApiException>()
              .having((e) => e.errorCode, 'code', captureStatusUnknownCode)
              .having(
                (e) => e.message,
                'message',
                contains('Check the payment status'),
              )
              .having(
                (e) => e.dataMap?['next_action'],
                'next',
                'CHECK_PAYMENT',
              ),
        ),
      );
      expect(
        (await stats())['razorpay_refund_posts'],
        before['razorpay_refund_posts'],
      );
      // "Check Payment": the recovery check with refresh.
      final r = await recovered(manager1, x.saleId);
      expect(r.state, RecoveryState.captured);
      expect(r.exception!.state, 'OPEN');
      final v = await ex.refund(x.attemptId);
      expect(v.state, 'REFUNDED');
    });

    test('SCENARIO 7 — background: a Pine Labs payment approved while the app was in the background is found on return (the resume check) as a manual-refund exception the manager can act on', () async {
      final x = await capturedStockConflict(provider: 'PINE_LABS');
      final onResume = await ApiPaymentRecoveryService(manager1)
          .fetch(refresh: true, saleIds: [x.saleId]);
      final r = onResume.recoverable.singleWhere((s) => s.saleId == x.saleId);
      expect(r.state, RecoveryState.captured);
      expect(r.canComplete, isFalse);
      expect(r.exception!.recommendedAction, 'MANUAL_REFUND');
      expect(r.exception!.viewerCanAct, isTrue);
      expect(r.attempts.single.attempt.status, AttemptStatus.captured);
    });
  });
}
