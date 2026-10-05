// Provider refunds (e.g. Razorpay UPI) in sales history: parsing the server's
// provider_refunds, the "Check refund status" reconciliation, and the
// cashier wording for the new refund errors. Fakes only — no server.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/history/models/provider_refund.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import 'sales_history_controller_test.dart' show FakeHistoryService, entry;
import 'sales_history_view_test.dart' show pumpHistory;

Map<String, dynamic> providerRefundJson({int id = 1, String status = 'PENDING', double amount = 112}) => {
  'id': id,
  'source': 'FULL',
  'provider': 'RAZORPAY',
  'amount': amount,
  'currency': 'INR',
  'status': status,
  'provider_refund_id': status == 'PENDING' ? null : 'rfnd_X',
  'failure_code': status == 'FAILED' ? 'RAZORPAY_REJECTED' : null,
  'failure_message': status == 'FAILED' ? 'The payment provider could not refund this payment' : null,
};

CompletedSale saleWith(List<Map<String, dynamic>> providerRefunds, {int id = 1}) => CompletedSale.fromJson({
  ...completedJson(id: id, number: 'POS-$id'),
  'refund': {'refunded_by': 'S1', 'refund_amount': 112, 'refunded_at': '2026-10-05 10:00:00'},
  'refund_status': 'full',
  'provider_refunds': providerRefunds,
})!;

void main() {
  test('provider_refunds are parsed with their status; pending is detected; older servers without the field parse as none', () {
    final s = saleWith([providerRefundJson(status: 'PENDING'), providerRefundJson(id: 2, status: 'SUCCEEDED'), providerRefundJson(id: 3, status: 'FAILED')]);
    expect(s.providerRefunds.map((r) => r.status), [ProviderRefundStatus.pending, ProviderRefundStatus.succeeded, ProviderRefundStatus.failed]);
    expect(s.providerRefunds.first.providerLabel, 'UPI (Razorpay)');
    expect(s.hasPendingProviderRefunds, isTrue);
    expect(s.providerRefunds[2].statusText, 'Provider refund failed — return this amount another way');
    expect(CompletedSale.fromJson(completedJson())!.providerRefunds, isEmpty);
    expect(ProviderRefund.fromJson({'id': 1, 'provider': 'RAZORPAY', 'amount': 1, 'status': 'WEIRD'})!.status, ProviderRefundStatus.unknown);
  });

  test('refreshProviderRefunds asks the server to reconcile (refresh=true) and shows the new status; an error keeps the current view', () async {
    final svc = FakeHistoryService()..details = {1: saleWith([providerRefundJson()])};
    final c = SalesHistoryController(svc, FakeProductService());
    await c.selectSale(1);
    expect(c.detail!.hasPendingProviderRefunds, isTrue);
    svc.details[1] = saleWith([providerRefundJson(status: 'SUCCEEDED')]);
    await c.refreshProviderRefunds();
    expect(svc.refreshCalls, [1]);
    expect(c.detail!.providerRefunds.single.status, ProviderRefundStatus.succeeded);
    svc.onDetail = (_) async => throw const ApiException(kind: ApiErrorKind.network, message: 'down');
    await c.refreshProviderRefunds();
    expect(c.detail!.providerRefunds.single.status, ProviderRefundStatus.succeeded);
    expect(c.isRefreshingProviderRefunds, isFalse);
    c.dispose();
  });

  testWidgets('sale detail shows the UPI refund status and a "Check refund status" action while pending', (tester) async {
    final svc = FakeHistoryService()
      ..rows = [entry(id: 1, saleNumber: 'POS-1')]
      ..details = {1: saleWith([providerRefundJson()])};
    await pumpHistory(tester, service: svc, height: 1100);
    await tester.tap(find.text('POS-1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('provider-refunds')), findsOneWidget);
    expect(find.textContaining('Refund pending with the payment provider'), findsOneWidget);
    svc.details[1] = saleWith([providerRefundJson(status: 'SUCCEEDED')]);
    await tester.ensureVisible(find.byKey(const Key('check-provider-refunds')));
    await tester.tap(find.byKey(const Key('check-provider-refunds')));
    await tester.pumpAndSettle();
    expect(svc.refreshCalls, [1]);
    expect(find.textContaining('Refunded to the customer'), findsOneWidget);
    expect(find.byKey(const Key('check-provider-refunds')), findsNothing, reason: 'nothing left to check');
  });

  test('cashier wording for refund errors from provider-paid sales', () {
    expect(
      describeApiError(const ApiException(kind: ApiErrorKind.conflict, statusCode: 409, message: 'x', errorCode: 'POS_PAYMENT_REFUND_EXCEEDS_REMAINING')),
      "This refund is more than what is left to refund on the customer's original payment.",
    );
    expect(
      describeApiError(const ApiException(kind: ApiErrorKind.conflict, statusCode: 409, message: 'x', errorCode: 'POS_PAYMENT_PROVIDER_NOT_SUPPORTED')),
      'The payment provider for this payment is not available right now. Ask an administrator.',
    );
  });
}
