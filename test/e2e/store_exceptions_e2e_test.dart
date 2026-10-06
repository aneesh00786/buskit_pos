// Phase 9 — END-TO-END store-wide payment exceptions and the manual refund
// reconciliation report: the real app code (PosApiClient, CartController,
// ApiPaymentTerminalService, ApiStoreExceptionService,
// ApiPaymentExceptionService) against the REAL backend routes on the
// isolated test database, with the REAL Pine Labs / Razorpay provider modules
// talking to in-memory fakes, and the REAL admin API for the report. The
// cashier sells on register A; managers sign in with their own PINs on
// register B of the same store, or on a device of ANOTHER store.
//
// Skipped unless STORE_EXCEPTIONS_E2E_CONFIG points at the JSON written by
// buskit-web/test/pos/e2e/storeExceptionE2eServer.js (local test DB only).
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/json_read.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/payment_exceptions/data/store_exception_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

void main() {
  final cfgPath = Platform.environment['STORE_EXCEPTIONS_E2E_CONFIG'];
  final skip = cfgPath == null
      ? 'needs STORE_EXCEPTIONS_E2E_CONFIG (buskit-web test/pos/e2e/storeExceptionE2eServer.js)'
      : null;

  late Map<String, dynamic> cfg;
  late PosApiClient cashier; // register A
  late PosApiClient managerB1; // register B, same store
  late PosApiClient managerB2; // register B, same store
  late PosApiClient managerOther; // another store
  final closedOut = <({String reference, double amount, String manager})>[];

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

  Future<http.Response> admin(String path) => http.get(
    Uri.parse('${cfg['admin_base_url']}$path'),
    headers: {'Authorization': 'Bearer ${cfg['admin_token']}'},
  );

  Future<PosApiClient> signIn(String deviceToken, String id, String pin) async {
    String? token;
    final c = PosApiClient(
      baseUrl: cfg['base_url'] as String,
      tokenProvider: () => token,
    );
    final login = await c.post(
      '/auth/staff-login',
      body: {'salesman_id': id, 'pin': pin},
      token: deviceToken,
      notifyUnauthorized: false,
    );
    token = asString(asMap(login)!['token']);
    expect(token, isNotNull);
    return c;
  }

  /// Register A: 2 of product 2, paid with [provider] (and the payment
  /// polled, as the pay screen does); then stock drops to 1.
  Future<({int saleId, int attemptId, double total})> capturedOnA(
    String provider,
  ) async {
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
    await control(
      provider == 'RAZORPAY' ? '/razorpay/pay-all' : '/pinelabs/approve-all',
    );
    await cashier.get(
      '/payment-attempts/${attempt.id}',
      query: {'refresh': 'true'},
    );
    await control('/stock/1');
    return (saleId: sale.id, attemptId: attempt.id, total: total);
  }

  Future<List<StoreExceptionItem>> all(
    PosApiClient c, {
    String state = 'ALL',
  }) async {
    final s = ApiStoreExceptionService(c);
    final out = <StoreExceptionItem>[];
    int? before;
    do {
      final p = await s.list(state: state, beforeId: before, limit: 100);
      out.addAll(p.items);
      before = p.nextBeforeId;
    } while (before != null);
    return out;
  }

  setUpAll(() async {
    if (cfgPath == null) return;
    cfg = asMap(jsonDecode(File(cfgPath).readAsStringSync()))!;
    cashier = await signIn(
      cfg['device_token'] as String,
      cfg['salesman_id'] as String,
      cfg['pin'] as String,
    );
    try {
      await cashier.post('/shifts/open', body: {'opening_amount': 0});
    } on ApiException catch (e) {
      if (e.kind != ApiErrorKind.conflict) rethrow;
    }
    final managers = asList(cfg['managers']).cast<String>();
    final pin = cfg['manager_pin'] as String;
    managerB1 = await signIn(cfg['device_b_token'] as String, managers[0], pin);
    managerB2 = await signIn(cfg['device_b_token'] as String, managers[1], pin);
    managerOther = await signIn(
      cfg['device_other_store_token'] as String,
      managers[0],
      pin,
    );
  });

  group('store-wide payment exceptions E2E', skip: skip, () {
    test('SCENARIO 1 — Pine Labs captured on register A, sale blocked; a manager on register B finds it in Payment Exceptions, opens it and closes out the manual refund: one transition, no provider refund call, audited', () async {
      final x = await capturedOnA('PINE_LABS');
      final listed = (await all(
        managerB1,
        state: 'UNRESOLVED',
      )).singleWhere((i) => i.paymentAttemptId == x.attemptId);
      expect(listed.registerId, cfg['register_a']);
      expect(listed.state, 'OPEN');
      expect(listed.viewerCanAct, isTrue);
      final d = await ApiStoreExceptionService(managerB1).detail(x.attemptId);
      expect(d.isException, isTrue);
      expect(d.sale!.sale.items.single.quantity, 2);

      final before = await stats();
      final ex = ApiPaymentExceptionService(managerB1);
      expect(
        (await ex.flagManualRefund(x.attemptId)).state,
        'MANUAL_REFUND_REQUIRED',
      );
      final v = await ex.completeManualRefund(
        x.attemptId,
        reference: 'PL-E2E9-1',
        note: 'refunded on the terminal',
      );
      expect(v.state, 'REFUNDED');
      expect(v.isManualRefund, isTrue);
      closedOut.add((
        reference: 'PL-E2E9-1',
        amount: x.total,
        manager: asList(cfg['managers'])[0] as String,
      ));
      final after = await stats();
      expect(
        after['pine_labs_requests'],
        before['pine_labs_requests'],
        reason: 'no Pine Labs call',
      );
      expect(after['pine_labs_refund_calls'], 0);
      expect(
        eventCount(after, 'MANUAL_REFUND_COMPLETED'),
        eventCount(before, 'MANUAL_REFUND_COMPLETED') + 1,
      );
      expect(after['sold_count'], 0);

      final closed = await ApiStoreExceptionService(managerB1)
          .detail(x.attemptId);
      expect(closed.exceptionState, 'REFUNDED');
      expect(closed.paymentStatus, 'REFUNDED');
      expect(closed.saleStatus, 'canceled');
      expect(
        closed.events.map((e) => e.action),
        contains('MANUAL_REFUND_COMPLETED'),
      );
      expect(
        (await all(
          managerB1,
          state: 'UNRESOLVED',
        )).where((i) => i.paymentAttemptId == x.attemptId),
        isEmpty,
        reason: 'no longer actionable',
      );
    });

    test('SCENARIO 2 — a manager of ANOTHER store neither sees nor opens nor resolves this store\'s exception', () async {
      final x = await capturedOnA('PINE_LABS');
      expect(
        (await all(managerOther))
            .where((i) => i.paymentAttemptId == x.attemptId),
        isEmpty,
      );
      await expectLater(
        ApiStoreExceptionService(managerOther).detail(x.attemptId),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      await expectLater(
        ApiPaymentExceptionService(managerOther).flagManualRefund(x.attemptId),
        throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 404)),
      );
      // Still open for this store's managers; close it out for the report.
      final ex = ApiPaymentExceptionService(managerB2);
      await ex.flagManualRefund(x.attemptId);
      await ex.completeManualRefund(x.attemptId, reference: 'PL-E2E9-2');
      closedOut.add((
        reference: 'PL-E2E9-2',
        amount: x.total,
        manager: asList(cfg['managers'])[1] as String,
      ));
    });

    test('SCENARIO 3 — Razorpay captured on register A, refunded from register B: one provider refund, closed, audited', () async {
      await control('/razorpay/refunds/ok');
      final x = await capturedOnA('RAZORPAY');
      expect(
        (await all(managerB1, state: 'OPEN')).map((i) => i.paymentAttemptId),
        contains(x.attemptId),
      );
      final before = await stats();
      final v = await ApiPaymentExceptionService(managerB1).refund(x.attemptId);
      expect(v.state, 'REFUNDED');
      expect(v.refundMethod, 'PROVIDER');
      final after = await stats();
      expect(after['razorpay_refunds'], before['razorpay_refunds'] + 1);
      final d = await ApiStoreExceptionService(managerB1).detail(x.attemptId);
      expect(
        d.events.map((e) => e.action),
        contains('PROVIDER_REFUND_REQUESTED'),
      );
      expect(d.exceptionState, 'REFUNDED');
    });

    test('SCENARIO 4 — two managers on register B open the same exception and close it out at the same moment: ONE state transition', () async {
      final x = await capturedOnA('PINE_LABS');
      await ApiStoreExceptionService(managerB1).detail(x.attemptId);
      await ApiStoreExceptionService(managerB2).detail(x.attemptId);
      await ApiPaymentExceptionService(managerB1).flagManualRefund(x.attemptId);
      final before = await stats();
      final results = await Future.wait([
        ApiPaymentExceptionService(managerB1)
            .completeManualRefund(x.attemptId, reference: 'PL-E2E9-4'),
        ApiPaymentExceptionService(managerB2)
            .completeManualRefund(x.attemptId, reference: 'PL-E2E9-4B'),
      ]);
      expect(results.where((r) => r.replayed).length, 1);
      final winner = results.firstWhere((r) => !r.replayed);
      expect(
        eventCount(await stats(), 'MANUAL_REFUND_COMPLETED'),
        eventCount(before, 'MANUAL_REFUND_COMPLETED') + 1,
      );
      closedOut.add((
        reference: winner.manualRefundReference!,
        amount: x.total,
        manager: winner.manualRefundCompletedBy!,
      ));
    });

    test('SCENARIO 5 — the admin reconciliation report (date + store + provider + manual) shows exactly these manual refunds with the right count, total, references, managers and audit; the CSV holds all of them', () async {
      expect(closedOut.length, 3);
      final today = DateTime.now().toIso8601String().substring(0, 10);
      final q =
          '?date_from=$today&date_to=$today&store_id=${cfg['store_id']}&provider=PINE_LABS&refund_method=MANUAL&status=REFUNDED';
      final r = await admin('/reconciliation/refunds$q&limit=1');
      expect(r.statusCode, 200, reason: r.body);
      final data = asMap(asMap(jsonDecode(r.body))!['data'])!;
      final totals = asMap(data['totals'])!;
      expect(
        totals['count'],
        3,
        reason: 'totals over the full set, not the 1-row page',
      );
      final expected = closedOut.fold<double>(0, (s, c) => s + c.amount);
      expect(
        asDouble(asMap(asList(totals['by_currency']).single)!['amount']),
        closeTo(expected, 0.001),
      );
      // Walk every page: the references and managers match what the POS did.
      final rows = <Map<String, dynamic>>[];
      int? before;
      do {
        final page = asMap(
          asMap(
            jsonDecode(
              (await admin(
                '/reconciliation/refunds$q&limit=1${before == null ? '' : '&before_id=$before'}',
              )).body,
            ),
          )!['data'],
        )!;
        rows.addAll(
          asList(page['items']).map(asMap).whereType<Map<String, dynamic>>(),
        );
        before = asInt(page['next_before_id']);
      } while (before != null);
      expect(
        rows.map((i) => '${i['refund_reference']}|${i['refunded_by']}').toSet(),
        closedOut.map((c) => '${c.reference}|${c.manager}').toSet(),
      );
      expect(
        rows.every(
          (i) =>
              i['refund_method'] == 'MANUAL' && i['confirmed_by'] == 'MANAGER',
        ),
        isTrue,
      );
      expect(rows.every((i) => i['register_id'] == cfg['register_a']), isTrue);
      // Audit for one of them.
      final detail = asMap(
        asMap(
          jsonDecode(
            (await admin(
              '/reconciliation/refunds/${rows.first['exception_id']}',
            )).body,
          ),
        )!['data'],
      )!;
      expect(
        asList(detail['events']).map((e) => asMap(e)!['action']),
        contains('MANUAL_REFUND_COMPLETED'),
      );
      // The CSV: every filtered row (paging ignored).
      final csv = await admin('/reconciliation/refunds.csv$q&limit=1');
      expect(csv.statusCode, 200);
      final lines = csv.body.replaceFirst('﻿', '').trim().split('\r\n');
      expect(lines.length, 1 + 3);
      for (final c in closedOut) {
        expect(csv.body, contains('"${c.reference}"'));
      }
      expect(csv.body.contains('PLTOKEN'), isFalse, reason: 'no secrets');
    });
  });
}
