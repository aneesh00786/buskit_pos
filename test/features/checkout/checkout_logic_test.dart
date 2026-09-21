import 'dart:convert';
import 'dart:math';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/utils/money.dart';
import 'package:buskit_pos/core/utils/uuid.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/checkout/state/payment_plan.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';

int m(String s) => parseMilli(s)!;

void main() {
  group('UUID v4 (idempotency key)', () {
    final v4 = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
    );

    test('has the RFC 4122 version-4 shape and fits the backend window (8–64 chars)', () {
      for (var i = 0; i < 200; i++) {
        final u = generateUuidV4();
        expect(u, matches(v4));
        expect(u.length, inInclusiveRange(8, 64));
        expect(u.length, 36);
      }
    });

    test('is unique across many generations', () {
      final seen = {for (var i = 0; i < 5000; i++) generateUuidV4()};
      expect(seen, hasLength(5000));
    });

    test('is deterministic for a seeded generator (so tests can pin it) and differs across seeds', () {
      expect(generateUuidV4(Random(1)), generateUuidV4(Random(1)));
      expect(generateUuidV4(Random(1)), isNot(generateUuidV4(Random(2))));
      expect(generateUuidV4(Random(1)), matches(v4));
    });
  });

  group('money helpers (milli-units)', () {
    test('parseMilli accepts whole numbers and up to 3 decimals', () {
      expect(parseMilli('20'), 20000);
      expect(parseMilli('20.5'), 20500);
      expect(parseMilli('20.50'), 20500);
      expect(parseMilli('0.001'), 1);
      expect(parseMilli(' 7.125 '), 7125);
      expect(parseMilli('0'), 0);
    });

    test('parseMilli rejects anything the backend would reject', () {
      for (final bad in [
        '',
        ' ',
        '-1',
        '1.2345',
        '1,5',
        'abc',
        '1.',
        '.5',
        '1e3',
        '+2',
        '1 000',
      ]) {
        expect(parseMilli(bad), isNull, reason: '"$bad"');
      }
    });

    test('formatMilli keeps 2 decimals, a third only when needed', () {
      expect(formatMilli(11200), '11.20');
      expect(formatMilli(0), '0.00');
      expect(formatMilli(7125), '7.125');
      expect(formatMilli(500), '0.50');
      expect(formatMilli(-2500), '-2.50');
    });

    test('no floating-point drift: 0.1 + 0.2 style totals stay exact', () {
      expect(m('0.1') + m('0.2'), m('0.3'));
      expect(milliFromDouble(133.28), 133280);
      expect(milliFromDouble(0.1 + 0.2), 300);
      expect(milliToJson(11200), 11.2);
    });
  });

  group('PaymentPlan — cash', () {
    PaymentPlan cash(String tendered, {String total = '112'}) => PaymentPlan(
      totalMilli: m(total),
      mode: PayMode.cash,
      cashReceivedMilli: parseMilli(tendered),
    );

    test('exact tender: valid, no change', () {
      final p = cash('112');
      expect(p.isValid, isTrue);
      expect(p.changeDueMilli, 0);
      expect(p.shortByMilli, 0);
      expect(p.payments.single.method, TenderMethod.cash);
      expect(
        (p.payments.single.amountMilli, p.payments.single.tenderedMilli),
        (112000, 112000),
      );
    });

    test('over-tender: change due is tendered minus total (preview), the applied amount stays the total', () {
      final p = cash('120');
      expect(p.changeDueMilli, 8000);
      expect(p.payments.single.amountMilli, 112000);
      expect(p.payments.single.tenderedMilli, 120000);
    });

    test('under-tender: invalid, shows the shortfall, no payment lines', () {
      final p = cash('100');
      expect(p.isValid, isFalse);
      expect(p.problem, 'Amount tendered is less than the total.');
      expect(p.shortByMilli, 12000);
      expect(p.changeDueMilli, 0);
      expect(p.payments, isEmpty);
    });

    test('nothing entered: invalid, prompts for the amount', () {
      final p = PaymentPlan(totalMilli: m('112'), mode: PayMode.cash);
      expect(p.problem, 'Enter the amount tendered.');
      expect(p.shortByMilli, 112000);
    });

    test('a nothing-to-pay total is invalid', () {
      expect(
        PaymentPlan(
          totalMilli: 0,
          mode: PayMode.cash,
          cashReceivedMilli: 0,
        ).isValid,
        isFalse,
      );
    });

    test('quick cash offers only denominations that cover the due amount', () {
      expect(PaymentPlan.quickCash(m('8.5')), [10000, 20000, 50000, 100000]);
      expect(PaymentPlan.quickCash(m('30')), [50000, 100000]);
      expect(PaymentPlan.quickCash(m('100')), [100000]);
      expect(PaymentPlan.quickCash(m('112')), isEmpty);
    });
  });

  group('PaymentPlan — card / other (recorded only)', () {
    test('card pays the whole total, no tendered amount, optional trimmed reference', () {
      final p = PaymentPlan(
        totalMilli: m('112'),
        mode: PayMode.card,
        reference: '  AUTH-9  ',
      );
      expect(p.isValid, isTrue);
      final line = p.payments.single;
      expect(
        (line.method, line.amountMilli, line.tenderedMilli, line.reference),
        (TenderMethod.card, 112000, null, 'AUTH-9'),
      );
      expect(line.toJson().containsKey('tendered_amount'), isFalse);
      expect(line.toJson()['reference'], 'AUTH-9');
    });

    test('no reference means the key is omitted', () {
      final p = PaymentPlan(
        totalMilli: m('5'),
        mode: PayMode.other,
        reference: '   ',
      );
      expect(p.payments.single.toJson().containsKey('reference'), isFalse);
    });

    test('a reference over 255 characters is rejected', () {
      final p = PaymentPlan(
        totalMilli: m('5'),
        mode: PayMode.card,
        reference: 'x' * 256,
      );
      expect(p.isValid, isFalse);
      expect(p.problem, contains('255'));
      expect(
        PaymentPlan(
          totalMilli: m('5'),
          mode: PayMode.card,
          reference: 'x' * 255,
        ).isValid,
        isTrue,
      );
    });
  });

  group('PaymentPlan — split tender', () {
    PaymentPlan split({
      String? applied,
      String? received,
      String total = '112',
      TenderMethod secondary = TenderMethod.card,
      String? ref,
    }) => PaymentPlan(
      totalMilli: m(total),
      mode: PayMode.split,
      cashAppliedMilli: applied == null ? null : parseMilli(applied),
      cashReceivedMilli: received == null
          ? (applied == null ? null : parseMilli(applied))
          : parseMilli(received),
      secondary: secondary,
      reference: ref,
    );

    test('cash for part, card for the remainder — the lines sum to the total exactly', () {
      final p = split(applied: '50');
      expect(p.isValid, isTrue);
      expect(p.remainderMilli, 62000);
      expect(
        p.payments.map((l) => (l.method, l.amountMilli, l.tenderedMilli)),
        [(TenderMethod.cash, 50000, 50000), (TenderMethod.card, 62000, null)],
      );
      expect(p.payments.fold<int>(0, (a, l) => a + l.amountMilli), 112000);
    });

    test(
      'cash received above the cash amount gives change on the cash line only',
      () {
        final p = split(applied: '45.5', received: '50');
        expect(p.changeDueMilli, 4500);
        expect(p.payments.first.amountMilli, 45500);
        expect(p.payments.first.tenderedMilli, 50000);
        expect(
          p.payments.fold<int>(0, (a, l) => a + l.amountMilli),
          112000,
          reason: 'sum is unaffected by change',
        );
      },
    );

    test('the secondary can be Other, with a reference', () {
      final p = split(
        applied: '12',
        secondary: TenderMethod.other,
        ref: 'VOUCHER-3',
      );
      expect(p.payments.last.method, TenderMethod.other);
      expect(p.payments.last.reference, 'VOUCHER-3');
      expect(p.payments.last.amountMilli, 100000);
    });

    test('cash amount must be more than zero and less than the total', () {
      expect(split().problem, 'Enter the cash amount.');
      expect(
        split(applied: '0').problem,
        'The cash amount must be more than zero.',
      );
      expect(
        split(applied: '112').problem,
        'For a split, the cash amount must be less than the total.',
      );
      expect(
        split(applied: '200').problem,
        'For a split, the cash amount must be less than the total.',
      );
      expect(split(applied: '111.999').isValid, isTrue);
      expect(split(applied: '0.001').isValid, isTrue);
    });

    test('cash received below the cash amount is invalid', () {
      final p = split(applied: '50', received: '40');
      expect(p.problem, 'Cash received is less than the cash amount.');
      expect(p.shortByMilli, 10000);
      expect(p.payments, isEmpty);
    });

    test('remainder is exact in milli-units (no drift)', () {
      final p = split(applied: '33.333', total: '100');
      expect(p.remainderMilli, 66667);
      expect(p.payments.fold<int>(0, (a, l) => a + l.amountMilli), 100000);
    });
  });

  group('PaymentLine wire format', () {
    test(
      'cash carries tendered_amount; amounts are JSON numbers with ≤3 decimals',
      () {
        final j = const PaymentLine(
          method: TenderMethod.cash,
          amountMilli: 11200,
          tenderedMilli: 20000,
        ).toJson();
        expect(j, {'method': 'cash', 'amount': 11.2, 'tendered_amount': 20});
        expect(
          const PaymentLine(
            method: TenderMethod.cash,
            amountMilli: 133280,
            tenderedMilli: 133280,
          ).toJson()['amount'],
          133.28,
        );
      },
    );

    test(
      'canonical text distinguishes methods, amounts, tendered and reference',
      () {
        const a = PaymentLine(
          method: TenderMethod.cash,
          amountMilli: 1000,
          tenderedMilli: 1000,
        );
        const b = PaymentLine(
          method: TenderMethod.cash,
          amountMilli: 1000,
          tenderedMilli: 2000,
        );
        const c = PaymentLine(
          method: TenderMethod.card,
          amountMilli: 1000,
          reference: 'x',
        );
        expect({a.canonical, b.canonical, c.canonical}, hasLength(3));
      },
    );
  });

  group('API service requests (verified backend contract)', () {
    late List<http.Request> seen;
    late ApiCartService service;
    late http.Response Function(http.Request) respond;

    setUp(() {
      seen = [];
      respond = (r) => http.Response(
        jsonEncode({'status': true, 'data': saleJson(id: 7, version: 2)}),
        200,
      );
      service = ApiCartService(
        PosApiClient(
          baseUrl: 'http://h',
          tokenProvider: () => 'staff-tok',
          httpClient: MockClient((r) async {
            seen.add(r);
            return respond(r);
          }),
        ),
      );
    });

    const cash = PaymentLine(
      method: TenderMethod.cash,
      amountMilli: 112000,
      tenderedMilli: 120000,
    );
    const card = PaymentLine(
      method: TenderMethod.card,
      amountMilli: 50000,
      reference: 'AUTH-1',
    );

    test('complete: POST /sales/:id/complete with expected_version, idempotency_key and payments — in the BODY', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': completedJson(id: 7, payments: [cash]),
        }),
        200,
      );
      final sale = await service.completeSale(
        saleId: 7,
        expectedVersion: 3,
        idempotencyKey: '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
        payments: const [cash],
      );
      final r = seen.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/api/v1/pos/sales/7/complete');
      expect(jsonDecode(r.body), {
        'expected_version': 3,
        'idempotency_key': '3f2b8c1e-9a4d-4e7b-8c2a-1d5e6f7a8b9c',
        'payments': [
          {'method': 'cash', 'amount': 112, 'tendered_amount': 120},
        ],
      });
      expect(r.headers['Authorization'], 'Bearer staff-tok');
      expect(
        r.headers.keys.map((k) => k.toLowerCase()),
        isNot(contains('idempotency-key')),
        reason: 'the backend reads the body, not a header',
      );
      expect(sale.displayNumber, 'POS-00000007');
    });

    test('complete sends NO price, tax, total, status, customer or scope — only what the server asked for', () async {
      respond = (r) => http.Response(
        jsonEncode({'status': true, 'data': completedJson()}),
        200,
      );
      await service.completeSale(
        saleId: 7,
        expectedVersion: 3,
        idempotencyKey: 'abcdefgh-1234',
        payments: const [cash, card],
      );
      final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {
        'expected_version',
        'idempotency_key',
        'payments',
      });
      for (final forbidden in [
        'total',
        'grand_total',
        'subtotal',
        'tax',
        'price',
        'status',
        'customer_id',
        'company_id',
        'store_id',
        'shift_id',
      ]) {
        expect(body.containsKey(forbidden), isFalse, reason: forbidden);
      }
      final payments = body['payments'] as List;
      expect(payments.last, {
        'method': 'card',
        'amount': 50,
        'reference': 'AUTH-1',
      });
      expect((payments.last as Map).containsKey('tendered_amount'), isFalse);
    });

    test('the completed sale is parsed: number, time, items, totals and the server payments/change', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': completedJson(
            id: 12,
            number: 'POS-00000012',
            customerId: 'C-9',
            payments: [cash],
          ),
        }),
        200,
      );
      final s = await service.completeSale(
        saleId: 12,
        expectedVersion: 1,
        idempotencyKey: 'abcdefgh-1234',
        payments: const [cash],
      );
      expect(
        (s.id, s.status, s.displayNumber, s.customerId),
        (12, 'completed', 'POS-00000012', 'C-9'),
      );
      expect(s.completedAt, DateTime.utc(2026, 9, 21, 15, 23, 52));
      expect(
        s.items.single.productName,
        isNull,
        reason: 'the completed view has no product names',
      );
      expect(
        (s.totals.subtotal, s.totals.taxTotal, s.totals.grandTotal),
        (100, 12, 112),
      );
      expect(s.payments.single.method, 'cash');
      expect(
        (s.payments.single.tendered, s.payments.single.changeDue),
        (120, 8),
      );
      expect(s.changeDue, 8);
    });

    test('a malformed completion response becomes a clean error', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': {'nope': 1},
        }),
        200,
      );
      await expectLater(
        service.completeSale(
          saleId: 1,
          expectedVersion: 1,
          idempotencyKey: 'abcdefgh',
          payments: const [cash],
        ),
        throwsA(isA<ApiException>()),
      );
    });

    test('errors keep error_code and data (insufficient stock, weight unit, version conflict)', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': false,
          'message': 'Insufficient stock',
          'error_code': 'POS_INSUFFICIENT_STOCK',
          'data': {
            'shortages': [
              {'item_id': 1, 'requested': 5, 'available': 2},
            ],
          },
        }),
        409,
      );
      try {
        await service.completeSale(
          saleId: 7,
          expectedVersion: 1,
          idempotencyKey: 'abcdefgh',
          payments: const [cash],
        );
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.errorCode, 'POS_INSUFFICIENT_STOCK');
        expect(e.dataMap!['shortages'], isNotEmpty);
        expect(e.isRetryable, isFalse);
      }
    });

    test('cancel: POST /sales/:id/cancel with only expected_version', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': saleJson(id: 7, version: 4, status: 'canceled'),
        }),
        200,
      );
      final s = await service.cancelSale(saleId: 7, expectedVersion: 3);
      final r = seen.single;
      expect((r.method, r.url.path), ('POST', '/api/v1/pos/sales/7/cancel'));
      expect(jsonDecode(r.body), {'expected_version': 3});
      expect((s.status, s.isDraft), ('canceled', false));
    });

    test('create sale: guest sends an empty body; a customer sends only customer_id', () async {
      await service.createSale();
      expect(jsonDecode(seen.last.body), <String, dynamic>{});
      await service.createSale(customerId: '  C-42 ');
      expect(jsonDecode(seen.last.body), {'customer_id': 'C-42'});
      await service.createSale(customerId: '   ');
      expect(
        jsonDecode(seen.last.body),
        <String, dynamic>{},
        reason: 'blank means guest',
      );
      expect(seen.every((r) => r.url.path == '/api/v1/pos/sales'), isTrue);
    });
  });
}
