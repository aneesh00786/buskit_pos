// Offline UI foundation: the global offline banner (driven by the API
// client's real server reachability) and the pay modal refusing provider
// payments (card terminal, UPI QR) while the server cannot be reached.
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/terminal_payment.dart';
import 'package:buskit_pos/features/offline/offline_payment_policy.dart';
import 'package:buskit_pos/features/shell/ui/pos_header.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';
import '../checkout/qr_payment_test.dart' show FakeQrService, razorpayJson;
import '../checkout/terminal_payment_test.dart'
    show FakeTerminalService, pineLabsJson;

Future<PageHarness> pumpPay(
  WidgetTester tester, {
  required String mode,
  required bool online,
}) async {
  final service = FakeTerminalService()
    ..providers = [
      PaymentProviderInfo.fromJson(pineLabsJson)!,
      PaymentProviderInfo.fromJson(razorpayJson)!,
    ];
  final h = PageHarness()..terminal = service;
  CartSale sale() => CartSaleFactory.sale(
    items: [lineJson(id: 1, quantity: 2, name: 'Tea')],
    total: 112,
  );
  h.carts.onAdd = (_) async => sale();
  h.carts.onGet = (_) async => sale();
  await pumpProductsPage(tester, h);
  await tester.tap(find.text('Add').first);
  await tester.pumpAndSettle();
  h.client.reachable.value = online;
  await tester.pumpAndSettle();
  await tester.tap(find.text('Pay'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(mode).last);
  await tester.pumpAndSettle();
  return h;
}

void main() {
  testWidgets(
    'offline banner: shown only when the server is unreachable; never claims anything was synced',
    (tester) async {
      final reachable = ValueNotifier<bool?>(null);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OfflineBanner(reachable: reachable)),
        ),
      );
      expect(
        find.byKey(const Key('offline-banner')),
        findsNothing,
        reason: 'unknown is not offline',
      );
      reachable.value = false;
      await tester.pump();
      expect(find.byKey(const Key('offline-banner')), findsOneWidget);
      expect(find.textContaining('OFFLINE'), findsOneWidget);
      expect(find.textContaining('synced'), findsNothing);
      reachable.value = true;
      await tester.pump();
      expect(find.byKey(const Key('offline-banner')), findsNothing);
    },
  );

  testWidgets(
    'the POS screen shows the offline banner when the API client marks the server unreachable',
    (tester) async {
      final h = PageHarness();
      await pumpProductsPage(tester, h);
      expect(find.byKey(const Key('offline-banner')), findsNothing);
      h.client.reachable.value = false;
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('offline-banner')), findsOneWidget);
    },
  );

  testWidgets(
    'offline: Pay on terminal (Pine Labs) is disabled with the internet-required message; nothing is sent',
    (tester) async {
      final h = await pumpPay(tester, mode: 'Card', online: false);
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.textContaining('Pay on terminal'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(
        find.text(OfflinePaymentPolicy.onlineRequiredMessage),
        findsOneWidget,
      );
      expect((h.terminal! as FakeTerminalService).startKeys, isEmpty);
      // Recording a manual card payment is still possible (existing flow).
      expect(
        find.widgetWithText(FilledButton, 'Complete Sale'),
        findsOneWidget,
      );

      h.client.reachable.value = true;
      await tester.pumpAndSettle();
      expect(
        find.text(OfflinePaymentPolicy.onlineRequiredMessage),
        findsNothing,
      );
      final enabled = tester.widget<FilledButton>(
        find.ancestor(
          of: find.textContaining('Pay on terminal'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(enabled.onPressed, isNotNull);
    },
  );

  testWidgets(
    'offline: UPI QR (Razorpay) is disabled with the internet-required message',
    (tester) async {
      await pumpPay(tester, mode: 'Other', online: false);
      final button = tester.widget<FilledButton>(
        find.ancestor(
          of: find.textContaining('UPI QR'),
          matching: find.byWidgetPredicate((w) => w is FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(
        find.text('Internet connection is required for this payment method.'),
        findsOneWidget,
      );
    },
  );

  test(
    'FakeQrService import guard',
    () => expect(FakeQrService().providers.single.isUsableQr, isTrue),
  );
}
