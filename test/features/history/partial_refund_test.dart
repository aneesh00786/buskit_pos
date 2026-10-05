import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/history/data/sales_history_service.dart';
import 'package:buskit_pos/features/history/models/partial_refund.dart';
import 'package:buskit_pos/features/history/models/sale_history_entry.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:buskit_pos/features/history/ui/sales_history_view.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'sales_history_controller_test.dart' show FakeHistoryService, entry;

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

/// A completed sale as the Phase 17.8 server returns it. [lines]:
/// (sale item id, product variation id, sold qty, refunded qty).
Map<String, dynamic> saleJson({
  int id = 1,
  List<(int, int, int, int)> lines = const [(11, 42, 3, 0)],
  String refundStatus = 'none',
  List<Map<String, dynamic>> refunds = const [],
  List<Map<String, dynamic>> payments = const [
    {'method': 'cash', 'amount': 30, 'status': 'completed'},
  ],
  double refundedTotal = 0,
}) => {
  'id': id,
  'status': 'completed',
  'sale_number': 'POS-$id',
  'items': [
    for (final (itemId, pv, qty, refunded) in lines)
      {
        'id': itemId,
        'product_variation_id': pv,
        'quantity': qty,
        'unit_price': 10,
        'tax_percent': 0,
        'tax_included': false,
        'tax_amount': 0,
        'discount_amount': 0,
        'line_total': 10.0 * qty,
        'refunded_quantity': refunded,
        'refundable_quantity': qty - refunded,
      },
  ],
  'totals': {'subtotal': 30, 'tax_total': 0, 'discount_total': 0, 'grand_total': 30},
  'payments': payments,
  'refund': null,
  'refund_status': refundStatus,
  'refunded_total': refundedTotal,
  'refundable_total': 30 - refundedTotal,
  'refunds': refunds,
};

Map<String, dynamic> refundJson({int id = 1, int saleItemId = 11, int qty = 1, double amount = 10, String? reason}) => {
  'id': id,
  'refund_amount': amount,
  'subtotal_amount': amount,
  'discount_amount': 0,
  'tax_amount': 0,
  'wallet_amount': 0,
  'payouts': [
    {'method': 'cash', 'amount': amount},
  ],
  'items': [
    {'sale_item_id': saleItemId, 'quantity': qty, 'damaged_quantity': 0, 'restocked_quantity': 0, 'refund_amount': amount},
  ],
  'loyalty': {'points_earned_reversed': 0, 'points_redeemed_returned': 0, 'cashback_reversed': 0, 'wallet_returned': 0},
  'reason': reason,
  'refunded_by': 'S1',
  'refunded_at': '2026-10-03T10:00:00.000Z',
};

CompletedSale sale0([Map<String, dynamic>? json]) => CompletedSale.fromJson(json ?? saleJson())!;

Future<SessionController> sessionWith(List<String>? permissions) async {
  final auth = FakeAuthService();
  if (permissions != null) {
    auth.onAuthContext = (t) async => PosAuthContext(
      staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Role')),
      permissions: permissions,
    );
  }
  final session = SessionController(auth, MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return session;
}

Future<SalesHistoryController> pump(
  WidgetTester tester, {
  required FakeHistoryService service,
  List<String>? permissions,
}) async {
  final controller = SalesHistoryController(service, FakeProductService());
  final session = await sessionWith(permissions);
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SalesHistoryController>.value(value: controller),
        ChangeNotifierProvider<SessionController>.value(value: session),
        Provider<ReceiptServices>.value(value: FakeReceipts().services),
      ],
      child: const MaterialApp(home: Scaffold(body: SizedBox.expand(child: SalesHistoryView()))),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

Future<void> openSale(WidgetTester tester) async {
  await tester.tap(find.text('POS-1').first);
  await tester.pumpAndSettle();
}

FakeHistoryService serviceWith(Map<String, dynamic> json, {SaleRefundStatus listStatus = SaleRefundStatus.none}) {
  return FakeHistoryService()
    ..rows = [
      SaleHistoryEntry.fromJson({'id': 1, 'version': 1, 'sale_number': 'POS-1', 'grand_total': 30, 'refund_status': listStatus.name, 'completed_at': DateTime.now().toUtc().toIso8601String()})!,
    ]
    ..details[1] = CompletedSale.fromJson(json);
}

Finder inAlert(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

Future<void> openRefundItems(WidgetTester tester) async {
  await tester.tap(find.text('Refund items'));
  await tester.pumpAndSettle();
}

void main() {
  group('models', () {
    test('parses refund status, per-line progress and refund history', () {
      final s = sale0(saleJson(lines: [(11, 42, 3, 1)], refundStatus: 'partial', refunds: [refundJson(reason: 'Broken')], refundedTotal: 10));
      expect(s.refundStatus, SaleRefundStatus.partial);
      expect(s.refundedQuantity(s.items.single), 1);
      expect(s.refundableQuantity(s.items.single), 2);
      expect(s.refunds.single.reason, 'Broken');
      expect(s.refunds.single.payouts.single.method, 'cash');
      expect(s.refundedTotal, 10);
    });

    test('a pre-17.8 response falls back to the legacy refund field', () {
      final legacy = CompletedSale.fromJson({
        'id': 1,
        'status': 'completed',
        'items': [
          {'id': 11, 'product_variation_id': 42, 'quantity': 2, 'line_total': 20},
        ],
        'totals': {'grand_total': 20},
        'payments': [],
        'refund': {'refunded_by': 'S1', 'refund_amount': 20},
      })!;
      expect(legacy.refundStatus, SaleRefundStatus.full);
      expect(legacy.refundableQuantity(legacy.items.single), 0);
      final untouched = CompletedSale.fromJson({
        'id': 2,
        'status': 'completed',
        'items': [
          {'id': 12, 'product_variation_id': 42, 'quantity': 2, 'line_total': 20},
        ],
        'totals': {'grand_total': 20},
        'payments': [],
      })!;
      expect(untouched.refundStatus, SaleRefundStatus.none);
      expect(untouched.refundableQuantity(untouched.items.single), 2);
    });

    test('list rows carry refund_status', () {
      expect(SaleHistoryEntry.fromJson({'id': 1, 'version': 1, 'refund_status': 'partial'})!.refundStatus, SaleRefundStatus.partial);
      expect(SaleHistoryEntry.fromJson({'id': 1, 'version': 1})!.refundStatus, SaleRefundStatus.none);
    });

    test('request lines serialize quantity and only a non-zero damaged quantity', () {
      expect(const RefundRequestLine(saleItemId: 1, quantity: 2).toJson(), {'sale_item_id': 1, 'quantity': 2});
      expect(const RefundRequestLine(saleItemId: 1, quantity: 2, damagedQuantity: 1).toJson()['damaged_quantity'], 1);
    });
  });

  group('controller', () {
    const lines = [RefundRequestLine(saleItemId: 11, quantity: 1)];

    test('preview success and failure', () async {
      final svc = FakeHistoryService();
      final c = SalesHistoryController(svc, FakeProductService());
      final p = await c.previewRefund(1, lines, refundMethod: 'cash');
      expect(p!.refundAmount, 10);
      expect(svc.previewMethods.single, 'cash');
      svc.onPreview = (id, l) async => throw netDown;
      expect(await c.previewRefund(1, lines), isNull);
      expect(c.previewError, netDown);
      c.clearPreviewError();
      expect(c.previewError, isNull);
    });

    test('success re-fetches the sale from the server and refreshes the list', () async {
      final svc = FakeHistoryService()..details[1] = sale0();
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      final detailCallsBefore = svc.detailCalls.length;
      final listCallsBefore = svc.listCalls;
      svc.onPartialRefund = (call) async {
        svc.details[1] = sale0(saleJson(lines: [(11, 42, 3, 1)], refundStatus: 'partial', refunds: [refundJson()], refundedTotal: 10));
        return PartialRefundResult(refund: PartialRefund.fromJson(refundJson()), sale: null);
      };
      final ok = await c.refundItems(1, lines, expectedRefundAmount: 10, refundMethod: 'cash', reason: 'Broken');
      await Future<void>.delayed(Duration.zero);
      expect(ok, isTrue);
      expect(c.lastPartialRefund!.id, 1);
      expect(svc.detailCalls.length, detailCallsBefore + 1);
      expect(svc.listCalls, greaterThan(listCallsBefore));
      expect(c.detail!.refundStatus, SaleRefundStatus.partial, reason: 'shows the server state, not a local guess');
      final call = svc.partialCalls.single;
      expect(call.expected, 10);
      expect(call.method, 'cash');
      expect(call.reason, 'Broken');
    });

    test('identical retry after a failure reuses the key; any change gets a new one; success closes the attempt', () async {
      final svc = FakeHistoryService()..onPartialRefund = (c) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.refundItems(1, lines, expectedRefundAmount: 10);
      await c.refundItems(1, lines, expectedRefundAmount: 10);
      await c.refundItems(1, const [RefundRequestLine(saleItemId: 11, quantity: 2)], expectedRefundAmount: 20);
      await c.refundItems(1, const [RefundRequestLine(saleItemId: 11, quantity: 2)], expectedRefundAmount: 20, refundMethod: 'card');
      final keys = svc.partialCalls.map((p) => p.key).toList();
      expect(keys[0], keys[1]);
      expect(keys[2], isNot(keys[1]));
      expect(keys[3], isNot(keys[2]));
      expect(c.refundError, netDown);

      svc.onPartialRefund = null;
      await c.refundItems(1, lines, expectedRefundAmount: 10);
      await c.refundItems(1, lines, expectedRefundAmount: 10);
      final n = svc.partialCalls.length;
      expect(svc.partialCalls[n - 1].key, isNot(svc.partialCalls[n - 2].key));
    });

    test('only one refund in flight at a time (shared with the whole-sale refund)', () async {
      final gate = Completer<PartialRefundResult>();
      final svc = FakeHistoryService()..onPartialRefund = (c) => gate.future;
      final c = SalesHistoryController(svc, FakeProductService());
      final first = c.refundItems(1, lines, expectedRefundAmount: 10);
      expect(c.isRefunding, isTrue);
      expect(await c.refundItems(1, lines, expectedRefundAmount: 10), isFalse);
      expect(await c.refundSale(1), isFalse);
      gate.complete(const PartialRefundResult());
      await first;
      expect(c.isRefunding, isFalse);
      expect(svc.partialCalls, hasLength(1));
      expect(svc.refundKeys, isEmpty);
    });
  });

  group('permission visibility', () {
    testWidgets('positively denied -> no refund actions', (tester) async {
      await pump(tester, service: serviceWith(saleJson()), permissions: ['sales.view']);
      await openSale(tester);
      expect(find.text('Refund items'), findsNothing);
      expect(find.text('Refund Sale'), findsNothing);
    });

    testWidgets('context not loaded -> actions visible (backend decides)', (tester) async {
      await pump(tester, service: serviceWith(saleJson()));
      await openSale(tester);
      expect(find.text('Refund items'), findsOneWidget);
      expect(find.text('Refund Sale'), findsOneWidget);
    });

    testWidgets('granted -> actions visible', (tester) async {
      await pump(tester, service: serviceWith(saleJson()), permissions: ['payments.refund']);
      await openSale(tester);
      expect(find.text('Refund items'), findsOneWidget);
    });
  });

  group('partially / fully refunded states', () {
    testWidgets('partial: badges in list and detail, line progress, history; whole-sale refund hidden (D8)', (tester) async {
      final svc = serviceWith(
        saleJson(lines: [(11, 42, 3, 1)], refundStatus: 'partial', refunds: [refundJson(reason: 'Broken')], refundedTotal: 10),
        listStatus: SaleRefundStatus.partial,
      );
      await pump(tester, service: svc);
      expect(find.text('Partially refunded'), findsOneWidget, reason: 'list badge');
      await openSale(tester);
      expect(find.text('Partially refunded'), findsNWidgets(2), reason: 'list + detail badge');
      expect(find.text('Refunded 1 of 3'), findsOneWidget);
      expect(find.text('Refund history'), findsOneWidget);
      expect(find.text('Refund #1 · 10.00'), findsOneWidget);
      expect(find.text('Refund items'), findsOneWidget);
      expect(find.text('Refund Sale'), findsNothing);
      expect(find.text('Still refundable'), findsOneWidget);
    });

    testWidgets('full via partial refunds: no actions, fully refunded summary', (tester) async {
      final svc = serviceWith(
        saleJson(lines: [(11, 42, 3, 3)], refundStatus: 'full', refunds: [refundJson(qty: 3, amount: 30)], refundedTotal: 30),
        listStatus: SaleRefundStatus.full,
      );
      await pump(tester, service: svc);
      await openSale(tester);
      expect(find.text('Refund items'), findsNothing);
      expect(find.text('Refund Sale'), findsNothing);
      expect(find.text('Fully refunded 30.00'), findsOneWidget);
      expect(find.text('Refunded'), findsNWidgets(2), reason: 'list + detail badge');
    });

    testWidgets('history entry expands to the server breakdown and reason', (tester) async {
      await pump(tester, service: serviceWith(saleJson(lines: [(11, 42, 3, 1)], refundStatus: 'partial', refunds: [refundJson(reason: 'Broken')], refundedTotal: 10)));
      await openSale(tester);
      await tester.tap(find.text('Refund #1 · 10.00'));
      await tester.pumpAndSettle();
      expect(find.text('Broken'), findsOneWidget);
      expect(find.text('Refund to Cash'), findsOneWidget);
    });
  });

  group('item selection and quantity validation', () {
    testWidgets('only refundable lines; stepper capped at the refundable quantity; Review disabled until something is selected', (tester) async {
      await pump(tester, service: serviceWith(saleJson(lines: [(11, 42, 3, 1), (12, 43, 1, 1)], refundStatus: 'partial')));
      await openSale(tester);
      await openRefundItems(tester);

      expect(find.byKey(const ValueKey('refund-line-11')), findsOneWidget);
      expect(find.byKey(const ValueKey('refund-line-12')), findsNothing, reason: 'fully refunded line is not offered');
      expect(find.textContaining('refundable 2'), findsOneWidget);
      FilledButton review() => tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Review refund'));
      expect(review().onPressed, isNull);

      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const Key('refund-qty-inc-11')));
        await tester.pump();
      }
      expect(tester.widget<Text>(find.byKey(const Key('refund-qty-value-11'))).data, '2');
      expect(tester.widget<IconButton>(find.byKey(const Key('refund-qty-inc-11'))).onPressed, isNull);
      expect(review().onPressed, isNotNull);
    });

    testWidgets('damaged quantity is capped at the refund quantity and follows it down', (tester) async {
      await pump(tester, service: serviceWith(saleJson()));
      await openSale(tester);
      await openRefundItems(tester);
      expect(find.byKey(const Key('refund-damaged-inc-11')), findsNothing, reason: 'only shown once a quantity is chosen');
      await tester.tap(find.byKey(const Key('refund-qty-inc-11')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('refund-damaged-inc-11')));
      await tester.pump();
      expect(tester.widget<IconButton>(find.byKey(const Key('refund-damaged-inc-11'))).onPressed, isNull);
      await tester.tap(find.byKey(const Key('refund-qty-inc-11')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('refund-qty-dec-11')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('refund-qty-dec-11')));
      await tester.pump();
      expect(find.byKey(const Key('refund-damaged-inc-11')), findsNothing);
    });

    testWidgets('Select all remaining picks every refundable unit', (tester) async {
      final svc = serviceWith(saleJson(lines: [(11, 42, 3, 1), (12, 43, 2, 0)], refundStatus: 'partial'));
      await pump(tester, service: svc);
      await openSale(tester);
      await openRefundItems(tester);
      await tester.tap(find.text('Select all remaining'));
      await tester.pump();
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
      expect(svc.previewCalls.single.map((l) => l.canonical).toList(), ['11:2:0', '12:2:0']);
    });
  });

  group('preview, confirmation, processing, result', () {
    Future<void> selectOneAndReview(WidgetTester tester, {bool damaged = false, String? reason}) async {
      await openRefundItems(tester);
      await tester.tap(find.byKey(const Key('refund-qty-inc-11')));
      await tester.pump();
      if (damaged) {
        await tester.tap(find.byKey(const Key('refund-damaged-inc-11')));
        await tester.pump();
      }
      if (reason != null) await tester.enterText(find.byKey(const Key('refund-reason')), reason);
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
    }

    testWidgets('the confirmation shows the SERVER preview; Cancel writes nothing', (tester) async {
      final svc = serviceWith(saleJson())
        ..onPreview = (id, lines) async => RefundPreview.fromJson({
              'refund_amount': 9.5,
              'subtotal_amount': 10,
              'discount_amount': 0.5,
              'tax_amount': 0,
              'wallet_amount': 0,
              'payouts': [
                {'method': 'cash', 'amount': 9.5},
              ],
              'items': [
                {'sale_item_id': 11, 'quantity': 1, 'damaged_quantity': 1, 'refund_amount': 9.5},
              ],
              'loyalty': {'points_earned_reversed': 9},
            });
      await pump(tester, service: svc);
      await openSale(tester);
      await selectOneAndReview(tester, damaged: true, reason: 'Cracked');

      expect(find.text('Confirm refund'), findsNWidgets(2), reason: 'title + button');
      expect(inAlert(find.text('9.50')), findsWidgets);
      expect(find.text('Item 42 × 1 (1 damaged)'), findsOneWidget);
      expect(find.text('Points earned reversed'), findsOneWidget);
      expect(find.text('Cracked'), findsOneWidget);
      expect(svc.previewCalls.single.single.canonical, '11:1:1');

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(svc.partialCalls, isEmpty);
    });

    testWidgets('a preview error stays in the selection dialog', (tester) async {
      final svc = serviceWith(saleJson())
        ..onPreview = (id, l) async => throw const ApiException(
              kind: ApiErrorKind.validation,
              message: 'Refund quantity exceeds the refundable quantity for one or more items',
              errorCode: 'POS_REFUND_QUANTITY_EXCEEDED',
            );
      await pump(tester, service: svc);
      await openSale(tester);
      await selectOneAndReview(tester);
      expect(find.text('Refund items'), findsWidgets, reason: 'dialog still open');
      expect(find.text('Refund quantity exceeds the refundable quantity for one or more items'), findsOneWidget);
    });

    testWidgets('confirm -> processing state -> server result dialog, sent with the previewed amount', (tester) async {
      final gate = Completer<PartialRefundResult>();
      final svc = serviceWith(saleJson())..onPartialRefund = (c) => gate.future;
      await pump(tester, service: svc);
      await openSale(tester);
      await selectOneAndReview(tester, reason: 'Wrong size');
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm refund'));
      await tester.pump();

      expect(find.text('Processing refund…'), findsOneWidget);
      expect(tester.widget<OutlinedButton>(find.ancestor(of: find.text('Refund items'), matching: find.byWidgetPredicate((w) => w is OutlinedButton))).onPressed, isNull);

      svc.details[1] = sale0(saleJson(lines: [(11, 42, 3, 1)], refundStatus: 'partial', refunds: [refundJson(id: 7)], refundedTotal: 10));
      gate.complete(PartialRefundResult(refund: PartialRefund.fromJson(refundJson(id: 7, reason: 'Wrong size'))));
      await tester.pumpAndSettle();

      expect(find.text('Refund successful'), findsOneWidget);
      expect(find.text('Refund #7'), findsOneWidget);
      final call = svc.partialCalls.single;
      expect(call.expected, 10, reason: 'the previewed server amount is sent back');
      expect(call.reason, 'Wrong size');
      expect(call.method, 'cash');

      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Refunded 1 of 3'), findsOneWidget, reason: 'detail re-fetched from the server');
    });

    testWidgets('a stale-amount 409 and a 403 are shown clearly; nothing is assumed', (tester) async {
      final svc = serviceWith(saleJson())
        ..onPartialRefund = (c) async => throw const ApiException(
              kind: ApiErrorKind.conflict,
              message: 'The refund amount has changed since it was previewed. Review the new amount and confirm again.',
              errorCode: 'POS_REFUND_AMOUNT_CHANGED',
            );
      await pump(tester, service: svc);
      await openSale(tester);
      await selectOneAndReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm refund'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The refund amount has changed'), findsOneWidget);
      expect(find.text('Refund successful'), findsNothing);

      svc.onPartialRefund = (c) async => throw ApiException(
            kind: ApiErrorKind.forbidden,
            message: 'Forbidden',
            errorCode: PosErrorCodes.permissionDenied,
            data: const {'permission': 'payments.refund'},
          );
      await selectOneAndReview(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Confirm refund'));
      await tester.pumpAndSettle();
      expect(find.textContaining('do not have permission to refund'), findsOneWidget);
    });

    testWidgets('a network failure, then an identical retry reuses the idempotency key', (tester) async {
      final svc = serviceWith(saleJson())..onPartialRefund = (c) async => throw netDown;
      await pump(tester, service: svc);
      await openSale(tester);
      for (var i = 0; i < 2; i++) {
        await selectOneAndReview(tester);
        await tester.tap(find.widgetWithText(FilledButton, 'Confirm refund'));
        await tester.pumpAndSettle();
      }
      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      expect(svc.partialCalls, hasLength(2));
      expect(svc.partialCalls[0].key, svc.partialCalls[1].key);
    });

    testWidgets('split tender: only the sale\'s own methods are offered, and the choice is previewed', (tester) async {
      final svc = serviceWith(saleJson(payments: [
        {'method': 'cash', 'amount': 10, 'status': 'completed'},
        {'method': 'card', 'amount': 20, 'status': 'completed'},
      ]));
      await pump(tester, service: svc);
      await openSale(tester);
      await openRefundItems(tester);
      expect(find.text('Refund to'), findsOneWidget);
      expect(inAlert(find.text('Card')), findsOneWidget);
      expect(inAlert(find.text('Other')), findsNothing);
      await tester.tap(inAlert(find.text('Card')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('refund-qty-inc-11')));
      await tester.pump();
      await tester.tap(find.text('Review refund'));
      await tester.pumpAndSettle();
      expect(svc.previewMethods.single, 'card');
    });
  });

  test('entry helper still builds plain rows', () {
    expect(entry(id: 5).refundStatus, SaleRefundStatus.none);
  });
}
