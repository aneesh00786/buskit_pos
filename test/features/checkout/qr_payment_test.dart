// UPI / QR payments (Razorpay) in the till: provider and attempt parsing, the
// QR states, and the pay-modal flow. The service is a fake — nothing here
// talks to a server, Razorpay or the network (the QR image request fails in
// tests and the dialog shows its fallback text, which is fine).
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/checkout/state/terminal_payment_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

final razorpayJson = {
  'name': 'RAZORPAY',
  'methods': ['QR'],
  'currencies': ['INR'],
  'capabilities': {'external': true, 'statusPolling': true, 'cancel': true, 'capture': false, 'refund': false, 'webhook': true, 'qr': true, 'cardTerminal': false},
};

Map<String, dynamic> qrJson(int id, String status, {String? failure, String expires = '2099-01-01T00:15:00.000Z'}) => {
  'id': id,
  'sale_id': 10,
  'method': 'QR',
  'provider': 'RAZORPAY',
  'amount': 112,
  'currency': 'INR',
  'status': status,
  'provider_reference': status == 'CAPTURED' ? 'pay_X' : null,
  'client_action': {'type': 'QR', 'qr_payload': null, 'image_url': 'https://rzp.io/i/qr_$id', 'expires_at': expires},
  'expires_at': expires,
  'failure_code': failure,
  'failure_message': null,
};
PaymentAttempt qr(int id, String status, {String? failure, String expires = '2099-01-01T00:15:00.000Z'}) =>
    PaymentAttempt.fromJson(qrJson(id, status, failure: failure, expires: expires))!;

class FakeQrService implements PaymentTerminalService {
  List<PaymentProviderInfo> providers = [PaymentProviderInfo.fromJson(razorpayJson)!];
  int nextId = 1;
  Future<PaymentAttempt> Function(String key) onStart = (_) async => throw UnimplementedError();
  Future<PaymentAttempt> Function(int id) onRefresh = (id) async => qr(id, 'PENDING');
  Future<PaymentAttempt> Function(int id) onCancel = (id) async => qr(id, 'CANCELLED', failure: 'CLOSED');
  final List<Map<String, Object>> starts = [];

  FakeQrService() {
    onStart = (_) async => qr(nextId++, 'PENDING');
  }

  @override
  Future<List<PaymentProviderInfo>> listProviders() async => providers;

  @override
  Future<PaymentAttempt> start({required int saleId, required String provider, required int amountMilli, required String idempotencyKey, String method = 'CARD'}) {
    starts.add({'provider': provider, 'method': method, 'amountMilli': amountMilli, 'key': idempotencyKey});
    return onStart(idempotencyKey);
  }

  @override
  Future<PaymentAttempt> refresh(int attemptId) => onRefresh(attemptId);

  @override
  Future<PaymentAttempt> cancel(int attemptId) => onCancel(attemptId);
}

Future<PageHarness> pumpOther(WidgetTester tester, FakeQrService service) async {
  final h = PageHarness()..terminal = service;
  CartSale sale() => CartSaleFactory.sale(items: [lineJson(id: 1, quantity: 2, name: 'Tea')], total: 112);
  h.carts.onAdd = (_) async => sale();
  h.carts.onGet = (_) async => sale();
  await pumpProductsPage(tester, h);
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pay'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Other').last);
  await tester.pumpAndSettle();
  return h;
}

Future<void> openQr(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('pay-by-qr')));
  await tester.pump();
  await tester.pump();
}

void main() {
  group('models', () {
    test('Razorpay is a usable QR provider (INR); a card terminal is not a QR provider', () {
      final p = PaymentProviderInfo.fromJson(razorpayJson)!;
      expect([p.label, p.isUsableQr, p.isUsableCardTerminal, p.currencies], ['Razorpay', true, false, ['INR']]);
    });

    test('a QR attempt carries the provider QR image (https only), expiry in UTC and the expired flag', () {
      final a = qr(3, 'PENDING');
      expect(a.qrImageUrl, 'https://rzp.io/i/qr_3');
      expect(a.expiresAt, DateTime.utc(2099, 1, 1, 0, 15));
      final insecure = PaymentAttempt.fromJson({...qrJson(4, 'PENDING'), 'client_action': {'type': 'QR', 'image_url': 'http://evil.example/qr.png'}})!;
      expect(insecure.qrImageUrl, isNull);
      expect(qr(5, 'CANCELLED', failure: 'EXPIRED').isExpired, isTrue);
      expect(qr(6, 'CANCELLED', failure: 'CLOSED').isExpired, isFalse);
    });

    test('the controller sends method QR and maps a provider expiry to the expired phase (retry allowed)', () async {
      final s = FakeQrService();
      s.onRefresh = (id) async => qr(id, 'CANCELLED', failure: 'EXPIRED');
      final c = TerminalPaymentController(s, saleId: 10, provider: 'RAZORPAY', amountMilli: 112000, method: 'QR', pollInterval: const Duration(milliseconds: 5));
      await c.start();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(s.starts.single['method'], 'QR');
      expect(c.phase, TerminalPhase.expired);
      expect(c.canRetry, isTrue);
      c.dispose();
    });
  });

  group('pay modal', () {
    testWidgets('Other mode offers UPI QR; the QR, amount and countdown show while waiting; payment received continues to completion automatically', (tester) async {
      final service = FakeQrService();
      final h = await pumpOther(tester, service);
      expect(find.text('UPI QR (Razorpay)'), findsOneWidget);
      await openQr(tester);
      expect(find.byKey(const Key('qr-phase-waitingForCard')), findsOneWidget);
      expect(find.byKey(const Key('qr-image')), findsOneWidget);
      expect(find.text('Waiting for customer payment…'), findsOneWidget);
      expect(find.textContaining('₹'), findsWidgets);
      expect(find.byKey(const Key('qr-countdown')), findsOneWidget);
      expect(find.text('Check payment status'), findsOneWidget);
      expect(find.text('Cancel'), findsWidgets);
      expect(h.carts.completeCalls, isEmpty, reason: 'pending never completes');

      service.onRefresh = (id) async => qr(id, 'CAPTURED');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('Payment received'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls.single.payments.single.toJson(), {'method': 'other', 'amount': 112.0, 'payment_attempt_id': 1});
    });

    testWidgets('a failed payment shows Payment failed; New QR starts a NEW request (new idempotency key); nothing completes until paid', (tester) async {
      final service = FakeQrService();
      service.onStart = (_) async => throw ApiException(
        kind: ApiErrorKind.unknown,
        statusCode: 402,
        message: 'x',
        errorCode: 'POS_PAYMENT_FAILED',
        data: {'payment_attempt': qrJson(1, 'FAILED', failure: 'PROVIDER_ERROR')},
      );
      final h = await pumpOther(tester, service);
      await openQr(tester);
      await tester.pumpAndSettle();
      expect(find.text('Payment failed'), findsOneWidget);
      service.onStart = (_) async => qr(2, 'PENDING');
      await tester.tap(find.text('New QR'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Waiting for customer payment…'), findsOneWidget);
      expect(service.starts.length, 2);
      expect(service.starts[0]['key'] == service.starts[1]['key'], isFalse);
      expect(h.carts.completeCalls, isEmpty);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
    });

    testWidgets('expiry: the provider-confirmed expiry shows QR expired and completes nothing', (tester) async {
      final service = FakeQrService();
      final h = await pumpOther(tester, service);
      await openQr(tester);
      service.onRefresh = (id) async => qr(id, 'CANCELLED', failure: 'EXPIRED');
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(find.text('QR expired'), findsOneWidget);
      expect(find.text('New QR'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls, isEmpty);
    });

    testWidgets('cancel closes the QR through the server and completes nothing', (tester) async {
      final service = FakeQrService();
      final h = await pumpOther(tester, service);
      await openQr(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Cancelled'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(h.carts.completeCalls, isEmpty);
    });

    testWidgets('without a QR provider the Other screen is unchanged', (tester) async {
      final service = FakeQrService()..providers = [];
      await pumpOther(tester, service);
      expect(find.byKey(const Key('pay-by-qr')), findsNothing);
    });
  });
}
