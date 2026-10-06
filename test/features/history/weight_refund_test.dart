// Phase 12C — selling-mode-aware partial refunds in the existing refund
// dialog. PIECE lines keep their whole-number steppers exactly as before; a
// WEIGHT line shows its exact refundable weight and takes a decimal refund
// (0.001+, at most 3 places, never more than refundable) through the
// existing quantity dialog, damaged weight included. Quantities are exact
// thousandths; the decimal reaches the existing API unchanged.
import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/history/data/sales_history_service.dart';
import 'package:buskit_pos/features/history/models/partial_refund.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:buskit_pos/features/history/ui/partial_refund_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart' show FakeProductService;
import 'sales_history_controller_test.dart' show FakeHistoryService;

/// A completed sale: 1.1 kg rice (WEIGHT) with 0.3 kg already refunded, and
/// 3 soap (PIECE). Figures as the server sends them (Phase 12A/12C view).
Map<String, dynamic> mixedSale({
  num riceRefunded = 0.3,
  num riceRefundable = 0.8,
}) => {
  'id': 5,
  'status': 'completed',
  'sale_number': 'POS-5',
  'items': [
    {
      'id': 51,
      'product_variation_id': 9801,
      'quantity': 1.1,
      'selling_mode': 'WEIGHT',
      'unit_price': 89.99,
      'tax_percent': 0,
      'tax_included': false,
      'tax_amount': 0,
      'discount_amount': 0,
      'line_total': 98.989,
      'refunded_quantity': riceRefunded,
      'refundable_quantity': riceRefundable,
    },
    {
      'id': 52,
      'product_variation_id': 42,
      'quantity': 3,
      'selling_mode': 'PIECE',
      'unit_price': 10,
      'tax_percent': 0,
      'tax_included': false,
      'tax_amount': 0,
      'discount_amount': 0,
      'line_total': 30,
      'refunded_quantity': 0,
      'refundable_quantity': 3,
    },
  ],
  'totals': {
    'subtotal': 128.989,
    'tax_total': 0,
    'discount_total': 0,
    'grand_total': 128.989,
  },
  'payments': [
    {'method': 'cash', 'amount': 128.989, 'status': 'completed'},
  ],
  'refund': null,
  'refund_status': 'partial',
  'refunded_total': 26.997,
  'refundable_total': 101.992,
  'refunds': const [],
};

RefundPreview preview() => RefundPreview.fromJson({
  'refund_amount': 10,
  'subtotal_amount': 10,
  'discount_amount': 0,
  'tax_amount': 0,
  'wallet_amount': 0,
  'payouts': [
    {'method': 'cash', 'amount': 10},
  ],
  'items': const [],
  'loyalty': const {},
  'fully_refunded_after': false,
})!;

void main() {
  late FakeHistoryService service;
  late SalesHistoryController controller;
  late CompletedSale sale;

  setUp(() {
    service = FakeHistoryService();
    service.onPreview = (id, lines) async => preview();
    controller = SalesHistoryController(service, FakeProductService());
    sale = CompletedSale.fromJson(mixedSale())!;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () => showRefundItemsDialog(
              context,
              sale: sale,
              names: const {9801: 'Loose Rice', 42: 'Soap'},
              controller: controller,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> enterWeight(
    WidgetTester tester,
    Finder button,
    String value,
  ) async {
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.text('Set weight'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, value);
    await tester.tap(find.text('Update'));
    await tester.pumpAndSettle();
  }

  test('model: exact refundable / refunded per line (decimal for WEIGHT, int for PIECE); refunds parse decimals', () {
    final rice = sale.items[0];
    final soap = sale.items[1];
    expect(rice.isWeight, isTrue);
    expect(sale.refundableQuantity(rice), 0.8);
    expect(sale.refundedQuantity(rice), 0.3);
    expect(sale.refundableQuantity(soap), 3);
    expect(
      sale.refundableQuantity(soap),
      isA<int>(),
      reason: 'PIECE unchanged',
    );
    final line = RefundLine.fromJson({
      'sale_item_id': 51,
      'quantity': 0.75,
      'damaged_quantity': 0.25,
      'restocked_quantity': 0.5,
      'refund_amount': 67.492,
    })!;
    expect(
      (line.quantity, line.damagedQuantity, line.restockedQuantity),
      (0.75, 0.25, 0.5),
    );
    const req = RefundRequestLine(
      saleItemId: 51,
      quantity: 0.75,
      damagedQuantity: 0.25,
    );
    expect(req.toJson(), {
      'sale_item_id': 51,
      'quantity': 0.75,
      'damaged_quantity': 0.25,
    });
  });

  testWidgets(
    '2/3/7/8. WEIGHT: refundable shown exactly (0.800); a valid decimal and a damaged weight are accepted and reach the preview request unchanged',
    (tester) async {
      await open(tester);
      expect(find.byKey(const Key('refund-weight-summary-51')), findsOneWidget);
      expect(
        find.text('Sold 1.100 · refunded 0.300 · refundable 0.800'),
        findsOneWidget,
      );
      await enterWeight(
        tester,
        find.byKey(const Key('refund-weight-51')),
        '0.75',
      );
      expect(find.text('0.750'), findsOneWidget);
      await enterWeight(
        tester,
        find.byKey(const Key('refund-weight-damaged-51')),
        '0.250',
      );
      expect(find.text('0.250'), findsOneWidget);
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
      final sent = service.previewCalls.single.single;
      expect(
        (sent.saleItemId, sent.quantity, sent.damagedQuantity),
        (51, 0.75, 0.25),
      );
      expect(sent.toJson(), {
        'sale_item_id': 51,
        'quantity': 0.75,
        'damaged_quantity': 0.25,
      });
    },
  );

  testWidgets(
    '4/5/6. WEIGHT rejects more than 3 decimals and zero (dialog), more than refundable, and a damaged weight above the refund — nothing is clamped or rounded',
    (tester) async {
      await open(tester);
      final weight = find.byKey(const Key('refund-weight-51'));
      for (final bad in ['0.1234', '0']) {
        await tester.tap(weight);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, bad);
        await tester.tap(find.text('Update'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('at most 3 decimal places'),
          findsOneWidget,
          reason: bad,
        );
        await tester.tap(find.text('Cancel').last);
        await tester.pumpAndSettle();
      }
      // A negative cannot even be typed (digits and one point only).
      await tester.tap(weight);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, '-0.5');
      expect(find.text('-0.5'), findsNothing);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      // More than refundable (0.8).
      await enterWeight(tester, weight, '0.801');
      expect(
        find.text('Only 0.800 of Loose Rice can still be refunded.'),
        findsOneWidget,
      );
      expect(find.text('Weight'), findsOneWidget, reason: 'nothing selected');
      // Exactly the refundable weight is fine; damaged cannot exceed it.
      await enterWeight(tester, weight, '0.800');
      expect(find.byKey(const Key('refund-weight-error')), findsNothing);
      await enterWeight(
        tester,
        find.byKey(const Key('refund-weight-damaged-51')),
        '0.9',
      );
      expect(
        find.textContaining(
          'damaged weight cannot be more than the refund weight',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
      final sent = service.previewCalls.single.single;
      expect((sent.quantity, sent.damagedQuantity), (0.8, 0));
    },
  );

  testWidgets(
    '1/9. PIECE line: unchanged whole-number stepper (no weight control); "Select all remaining" takes 3 pieces and the exact 0.8 kg',
    (tester) async {
      await open(tester);
      expect(find.byKey(const Key('refund-qty-inc-52')), findsOneWidget);
      expect(find.byKey(const Key('refund-weight-52')), findsNothing);
      expect(
        find.byKey(const Key('refund-qty-inc-51')),
        findsNothing,
        reason: 'WEIGHT has no stepper',
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('refund-qty-inc-52')));
        await tester.pumpAndSettle();
      }
      expect(
        tester.widget<Text>(find.byKey(const Key('refund-qty-value-52'))).data,
        '2',
      );
      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byKey(const Key('refund-qty-inc-52')));
        await tester.pumpAndSettle();
      }
      expect(
        tester.widget<Text>(find.byKey(const Key('refund-qty-value-52'))).data,
        '3',
        reason: 'capped at refundable',
      );
      await tester.tap(find.text('Select all remaining'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
      final sent = {
        for (final l in service.previewCalls.single) l.saleItemId: l,
      };
      expect(sent[52]!.quantity, 3);
      expect(sent[52]!.quantity, isA<int>());
      expect(sent[52]!.toJson(), {
        'sale_item_id': 52,
        'quantity': 3,
      }, reason: 'PIECE payload unchanged');
      expect(sent[51]!.quantity, 0.8);
    },
  );

  test('7. the existing API sends the decimal refund quantity unchanged (preview and refund)', () async {
    final seen = <http.Request>[];
    final api = ApiSalesHistoryService(
      PosApiClient(
        baseUrl: 'http://h',
        tokenProvider: () => 'tok',
        httpClient: MockClient((r) async {
          seen.add(r);
          return http.Response(
            jsonEncode({
              'status': true,
              'data': {'refund_amount': 1, 'items': []},
            }),
            200,
          );
        }),
      ),
    );
    const lines = [
      RefundRequestLine(saleItemId: 51, quantity: 0.75, damagedQuantity: 0.25),
      RefundRequestLine(saleItemId: 52, quantity: 2),
    ];
    await api.previewRefund(saleId: 5, lines: lines);
    await api.refundItems(
      saleId: 5,
      lines: lines,
      expectedRefundAmount: 1,
      idempotencyKey: 'k',
    );
    for (final r in seen) {
      final items = (jsonDecode(r.body) as Map)['items'] as List;
      expect(items, [
        {'sale_item_id': 51, 'quantity': 0.75, 'damaged_quantity': 0.25},
        {'sale_item_id': 52, 'quantity': 2},
      ]);
    }
    expect(seen.map((r) => r.url.path), [
      '/api/v1/pos/sales/5/refunds/preview',
      '/api/v1/pos/sales/5/refunds',
    ]);
  });
}
