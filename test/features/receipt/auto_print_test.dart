// Phase 14B — "Auto print receipt" (local printer setting, off by default).
// When on: the receipt prints ONCE after a COMPLETED sale through the same
// print flow as the button. Never before completion, never for a failed or
// cancelled payment, never twice. A print failure leaves the sale complete
// and the manual button available. The Phase 14A drawer is independent.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:buskit_pos/features/receipt/ui/receipt_actions.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../checkout/pay_modal_test.dart'
    show completeBtn, openPay, pumpWithCart, typeInto;

const autoOn = PrinterSettings(autoPrint: true);

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> payCash(WidgetTester tester) async {
  await openPay(tester);
  await typeInto(tester, 'Amount tendered', '120');
  await tester.tap(completeBtn);
  await settle(tester);
}

void main() {
  test('setting: off by default, stored when turned on; the once-guard claims a sale once', () async {
    final store = PrinterSettingsStore(MemoryTokenStore());
    expect((await store.load()).autoPrint, isFalse);
    await store.save(autoOn);
    expect((await store.load()).autoPrint, isTrue);
    final ps = PrintService(settings: store);
    expect(ps.claimAutoPrint('sale:7'), isTrue);
    expect(ps.claimAutoPrint('sale:7'), isFalse);
    expect(ps.claimAutoPrint('sale:8'), isTrue);
  });

  testWidgets(
    'auto-print OFF: nothing prints by itself; the manual "Print Receipt" still works',
    (tester) async {
      final h = await pumpWithCart(tester);
      await payCash(tester);
      expect(find.text('Sale complete'), findsOneWidget);
      expect(h.receipts.print.printed, isEmpty);
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(h.receipts.print.printed, hasLength(1));
      expect(find.text('Receipt printed.'), findsOneWidget);
    },
  );

  testWidgets(
    'auto-print ON: exactly ONE print after the completed sale; rebuilds do not reprint; manual reprint still available',
    (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(() => h.receipts.settings.save(autoOn));
      await openPay(tester);
      expect(
        h.receipts.print.printed,
        isEmpty,
        reason: 'not before completion',
      );
      await typeInto(tester, 'Amount tendered', '120');
      await tester.tap(completeBtn);
      await settle(tester);
      expect(find.text('Sale complete'), findsOneWidget);
      expect(h.receipts.print.printed, hasLength(1));
      expect(h.receipts.print.printed.single.orderNumber, 'POS-00000007');
      await tester.pump();
      await settle(tester);
      expect(h.receipts.print.printed, hasLength(1), reason: 'rebuild');
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(h.receipts.print.printed, hasLength(2), reason: 'manual reprint');
    },
  );

  testWidgets(
    'a FAILED payment prints nothing; the successful retry prints once',
    (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(() => h.receipts.settings.save(autoOn));
      h.carts.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
      await payCash(tester);
      expect(find.text('Retry payment'), findsOneWidget);
      expect(h.receipts.print.printed, isEmpty);
      h.carts.onComplete = (c) async =>
          CompletedSale.fromJson(completedJson(payments: c.payments))!;
      await tester.tap(find.text('Retry payment'));
      await settle(tester);
      expect(h.carts.completeCalls, hasLength(2));
      expect(h.receipts.print.printed, hasLength(1));
    },
  );

  testWidgets('a CANCELLED payment (pay screen closed) prints nothing', (
    tester,
  ) async {
    final h = await pumpWithCart(tester);
    await tester.runAsync(() => h.receipts.settings.save(autoOn));
    await openPay(tester);
    await tester.tap(find.text('Cancel'));
    await settle(tester);
    expect(h.carts.completeCalls, isEmpty);
    expect(h.receipts.print.printed, isEmpty);
  });

  testWidgets(
    'a print FAILURE leaves the sale complete; the message shows and the button stays for a retry',
    (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(() => h.receipts.settings.save(autoOn));
      h.receipts.print.onPrint = (_) async =>
          throw const PrintException('The printer did not respond.');
      await payCash(tester);
      expect(find.text('Sale complete'), findsOneWidget);
      expect(h.carts.completeCalls, hasLength(1));
      expect(h.receipts.print.printed, hasLength(1));
      expect(find.textContaining('Could not print'), findsOneWidget);
      h.receipts.print.onPrint = null;
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(h.receipts.print.printed, hasLength(2));
    },
  );

  testWidgets(
    'the Phase 14A drawer is unchanged and separate: auto-print + drawer on = one print AND one drawer pulse (no receipt in the pulse)',
    (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(
        () => h.receipts.settings.save(
          const PrinterSettings(
            host: '10.0.0.9',
            cashDrawer: true,
            autoPrint: true,
          ),
        ),
      );
      await payCash(tester);
      expect(h.receipts.print.printed, hasLength(1));
      expect(h.receipts.drawerAdapter.jobs, hasLength(1));
      expect(h.receipts.drawerAdapter.jobs.single.lines, isEmpty);
    },
  );

  testWidgets(
    'auto-print on with no drawer set up: the receipt prints and no drawer pulse is sent',
    (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(() => h.receipts.settings.save(autoOn));
      await payCash(tester);
      expect(h.receipts.print.printed, hasLength(1));
      expect(h.receipts.drawerAdapter.jobs, isEmpty);
    },
  );

  testWidgets(
    'the sale-complete actions rebuilt from scratch (e.g. layout change) never auto-print the same sale twice',
    (tester) async {
      final receipts = FakeReceipts();
      await tester.runAsync(() => receipts.settings.save(autoOn));
      final receipt = ReceiptFormatter.build(
        sale: CompletedSale.fromJson(completedJson())!,
        names: const {1: 'Tea'},
      );
      Widget screen(Key key) => MaterialApp(
        home: Scaffold(
          body: Provider<ReceiptServices>.value(
            value: receipts.services,
            child: ReceiptActions(
              key: key,
              receipt: receipt,
              autoPrintKey: 'sale:7',
            ),
          ),
        ),
      );
      await tester.pumpWidget(screen(const ValueKey('first')));
      await settle(tester);
      await tester.pumpWidget(screen(const ValueKey('second'))); // new State
      await settle(tester);
      expect(receipts.print.printed, hasLength(1));
    },
  );
}
