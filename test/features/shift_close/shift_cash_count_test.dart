// Phase 14C-B2 — Shift Close cash count by notes & coins + X/Z shift report.
// The count is sent to the EXISTING close endpoint (Phase 14C-B1); the
// server's figures (expected, counted, variance, stored count) are what the
// Z report shows. Local arithmetic is exact (thousandths) and only a preview.
import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/shift_close/data/shift_close_service.dart';
import 'package:buskit_pos/features/shift_close/models/cash_denominations.dart';
import 'package:buskit_pos/features/shift_close/models/shift_summary.dart';
import 'package:buskit_pos/features/shift_close/state/shift_close_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'shift_close_view_test.dart'
    show
        FakeShiftCloseService,
        closedResult,
        pumpHost,
        signedInSession,
        summaryJson,
        valueOf;

/// 100×2 + 50×3 + 20×1 + 0.50×3 + 0.05×7 = 371.85 (expected 375 → −3.15).
const counts = {100000: '2', 50000: '3', 20000: '1', 500: '3', 50: '7'};

Map<String, dynamic> cashCountJson() => {
  'currency': 'AUD',
  'counted': 371.85,
  'denominations': [
    {'value': 100, 'quantity': 2, 'line_total': 200},
    {'value': 50, 'quantity': 3, 'line_total': 150},
    {'value': 20, 'quantity': 1, 'line_total': 20},
    {'value': 0.5, 'quantity': 3, 'line_total': 1.5},
    {'value': 0.05, 'quantity': 7, 'line_total': 0.35},
  ],
};

void main() {
  group('service (existing POST /shifts/:id/close)', () {
    test('sends the non-zero count as exact decimal text plus the exact counted amount; reads back the stored cash_count', () async {
      final sent = <Map<String, dynamic>>[];
      final client = PosApiClient(
        baseUrl: 'http://pos.test',
        httpClient: MockClient((r) async {
          sent.add(jsonDecode(r.body) as Map<String, dynamic>);
          final data = {...closedJson(), 'cash_count': cashCountJson()};
          return http.Response(jsonEncode({'status': true, 'data': data}), 200);
        }),
        tokenProvider: () => 't',
      );
      final r = await ApiShiftCloseService(client).close(
        shiftId: 123,
        closingAmount: 371.85,
        denominations: const [
          DenominationCount(valueMilli: 100000, quantity: 2),
          DenominationCount(valueMilli: 50, quantity: 7),
        ],
      );
      expect(sent.single, {
        'closing_amount': 371.85,
        'denominations': [
          {'value': '100.000', 'quantity': 2},
          {'value': '0.050', 'quantity': 7},
        ],
      });
      final c = r.cashCount!;
      expect((c.currency, c.countedMilli), ('AUD', 371850));
      expect(c.lines.map((l) => (l.valueMilli, l.quantity, l.lineMilli)), [
        (100000, 2, 200000),
        (50000, 3, 150000),
        (20000, 1, 20000),
        (500, 3, 1500),
        (50, 7, 350),
      ]);
      // Without a count the request is exactly as before.
      await ApiShiftCloseService(client).close(shiftId: 123, closingAmount: 10);
      expect(sent.last, {'closing_amount': 10});
    });
  });

  group('controller', () {
    late FakeShiftCloseService service;
    late ShiftCloseController c;
    setUp(() async {
      service = FakeShiftCloseService();
      c = ShiftCloseController(service);
      await c.load();
    });
    tearDown(() => c.dispose());

    test('quantities, exact line totals and total; empty/zero quantities = 0 and are not sent', () async {
      expect(c.denominationsMilli, cashDenominationsFor('AUD'));
      expect(c.countingByDenomination, isFalse);
      counts.forEach(c.setQuantity);
      c.setQuantity(10000, ''); // empty
      c.setQuantity(5000, '0'); // zero
      expect(c.lineTotalMilli(500), 1500);
      expect(c.lineTotalMilli(50), 350);
      expect(c.denominationTotalMilli, 371850);
      expect(c.countingByDenomination, isTrue);
      expect(c.countedMilli, 371850);
      expect(c.varianceMilli, -3150);
      expect(c.denominationCounts.map((d) => (d.valueMilli, d.quantity)), [
        (100000, 2),
        (50000, 3),
        (20000, 1),
        (500, 3),
        (50, 7),
      ]);
      await c.close();
      expect(service.closeCalls.single, '123:371.85');
      expect(service.denominationCalls.single!.length, 5);
    });

    test('negative / fractional / non-numeric quantities block the close', () {
      for (final bad in ['-1', '1.5', 'x', '1e3']) {
        c.setQuantity(100000, bad);
        expect(c.quantityIsValid(100000), isFalse, reason: bad);
        expect(c.countedMilli, isNull, reason: bad);
        expect(c.canSubmit, isFalse, reason: bad);
      }
      c.setQuantity(100000, '1');
      expect(c.canSubmit, isTrue);
    });

    test('with no count, the existing counted-amount entry works unchanged (no denominations sent)', () async {
      c.setCounted('380');
      expect(c.countingByDenomination, isFalse);
      expect(c.countedMilli, 380000);
      await c.close();
      expect(service.denominationCalls.single, isNull);
    });
  });

  group('screen', () {
    late SessionController session;
    late FakeShiftCloseService service;
    setUp(() async {
      service = FakeShiftCloseService();
      session = await signedInSession();
    });
    tearDown(() => session.dispose());

    Future<void> enterCounts(WidgetTester tester) async {
      for (final e in counts.entries) {
        await tester.enterText(find.byKey(Key('denom-qty-${e.key}')), e.value);
      }
      await tester.pump();
    }

    testWidgets(
      'counting notes & coins updates line totals, the total, expected and variance; the amount field yields to the count',
      (tester) async {
        await pumpHost(tester, service: service, session: session);
        expect(find.text('Count notes & coins'), findsOneWidget);
        await enterCounts(tester);
        expect(valueOf(tester, 'denom-line-100000'), '200.00');
        expect(valueOf(tester, 'denom-line-50'), '0.35');
        expect(valueOf(tester, 'denom-total'), '371.85');
        expect(valueOf(tester, 'shift-expected-cash'), '375.00');
        expect(valueOf(tester, 'shift-variance'), '−3.15');
        final field = tester.widget<TextField>(
          find.byKey(const Key('shift-counted-cash')),
        );
        expect(field.enabled, isFalse);
        expect(find.byKey(const Key('denom-counted-note')), findsOneWidget);
      },
    );

    testWidgets(
      'closing sends the count; the Z report shows the server figures and the stored breakdown',
      (tester) async {
        service.onClose = (id, amount) async => closedResult(
          counted: 371.85,
          variance: -3.15,
        ).withCashCount(ShiftCashCount.fromJson(cashCountJson()));
        await pumpHost(tester, service: service, session: session);
        await enterCounts(tester);
        await tester.tap(find.byKey(const Key('shift-close-submit')));
        await tester.pumpAndSettle();
        expect(find.text('Counted cash (notes & coins)'), findsOneWidget);
        await tester.tap(find.byKey(const Key('shift-close-confirm')));
        await tester.pumpAndSettle();

        expect(service.closeCalls.single, '123:371.85');
        expect(
          service.denominationCalls.single!.map(
            (d) => (d.valueMilli, d.quantity),
          ),
          [(100000, 2), (50000, 3), (20000, 1), (500, 3), (50, 7)],
        );
        expect(find.byKey(const Key('shift-closed-title')), findsOneWidget);
        expect(find.text('Shift Closing Report (Z Report)'), findsOneWidget);
        expect(valueOf(tester, 'report-status'), 'Closed');
        expect(valueOf(tester, 'report-expected'), '375.00');
        expect(valueOf(tester, 'report-counted'), '371.85');
        expect(valueOf(tester, 'shift-final-variance'), '−3.15');
        expect(find.text('Cash count (AUD)'), findsOneWidget);
        expect(find.text('100.00 × 2'), findsOneWidget);
        expect(valueOf(tester, 'report-denom-50'), '0.35');
        expect(valueOf(tester, 'report-count-total'), '371.85');
      },
    );

    testWidgets(
      'a server validation error is shown and the shift stays open for correction',
      (tester) async {
        service.onClose = (id, amount) async => throw ApiException.fromStatus(
          422,
          message: 'denominations must be in the store currency (INR)',
        );
        await pumpHost(tester, service: service, session: session);
        await enterCounts(tester);
        await tester.tap(find.byKey(const Key('shift-close-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shift-close-confirm')));
        await tester.pumpAndSettle();
        expect(
          valueOf(tester, 'shift-close-error'),
          'denominations must be in the store currency (INR)',
        );
        expect(find.byKey(const Key('shift-close-submit')), findsOneWidget);
        expect(service.closeCalls, hasLength(1), reason: 'no automatic retry');
      },
    );

    testWidgets(
      'a shift closed without a count (or before counts existed) shows no breakdown',
      (tester) async {
        await pumpHost(tester, service: service, session: session);
        await tester.enterText(
          find.byKey(const Key('shift-counted-cash')),
          '380',
        );
        await tester.pump();
        await tester.tap(find.byKey(const Key('shift-close-submit')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shift-close-confirm')));
        await tester.pumpAndSettle();
        expect(service.denominationCalls.single, isNull);
        expect(find.text('Shift Closing Report (Z Report)'), findsOneWidget);
        expect(valueOf(tester, 'shift-final-variance'), '+5.00');
        expect(find.textContaining('Cash count'), findsNothing);
        expect(find.byKey(const Key('report-count-total')), findsNothing);
      },
    );

    testWidgets(
      'X report: the open shift\'s information, cash, payments and sales (on screen)',
      (tester) async {
        await pumpHost(tester, service: service, session: session);
        await tester.tap(find.byKey(const Key('shift-x-report')));
        await tester.pumpAndSettle();
        expect(find.text('Shift Report (X Report)'), findsOneWidget);
        expect(valueOf(tester, 'report-shift-id'), '#123');
        expect(valueOf(tester, 'report-status'), 'Open');
        expect(valueOf(tester, 'report-expected'), '375.00');
        expect(
          find.byKey(const Key('report-counted')),
          findsNothing,
          reason: 'not counted yet',
        );
        expect(valueOf(tester, 'report-payment-cash'), '520.00');
        expect(valueOf(tester, 'report-payment-card'), '250.00');
        expect(valueOf(tester, 'report-sales-count'), '5');
        expect(
          valueOf(tester, 'report-net'),
          '500.00',
        ); // 800 gross − 300 refunds
        await tester.tap(find.byKey(const Key('x-report-close')));
        await tester.pumpAndSettle();
        expect(find.text('Shift Report (X Report)'), findsNothing);
      },
    );
  });
}

Map<String, dynamic> closedJson() => {
  'summary': summaryJson(
    status: 'closed',
    closable: false,
    cashExtra: {'counted': 371.85, 'variance': -3.15},
  ),
};
