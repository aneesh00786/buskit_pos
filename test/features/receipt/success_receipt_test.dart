import 'dart:async';

import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/pump_page.dart';
import '../checkout/pay_modal_test.dart'
    show completeBtn, openPay, pumpWithCart;

Future<PageHarness> pumpSuccess(
  WidgetTester tester, {
  double width = 1400,
  double height = 900,
  double textScale = 1,
}) async {
  final h = await pumpWithCart(
    tester,
    width: width,
    height: height,
    textScale: textScale,
  );
  await h.signIn();
  await openPay(tester);
  if (!tester.any(find.text('Exact').hitTestable())) {
    await tester.scrollUntilVisible(
      find.text('Exact'),
      100,
      scrollable: find.byType(Scrollable).last,
    );
  }
  await tester.tap(find.text('Exact'));
  await tester.pump();
  await tester.tap(completeBtn);
  await tester.pumpAndSettle();
  expect(find.text('Sale complete'), findsOneWidget);
  return h;
}

Finder get printBtn => find.widgetWithText(OutlinedButton, 'Print Receipt');
Finder get sendBtn => find.widgetWithText(OutlinedButton, 'Email / SMS');
Finder get sendDialog => find.byType(AlertDialog);

void main() {
  group('Print Receipt', () {
    testWidgets(
      'builds the receipt from the server sale + cart names and prints it',
      (tester) async {
        final h = await pumpSuccess(tester);
        await tester.tap(printBtn);
        await tester.pumpAndSettle();
        final r = h.receipts.print.printed.single;
        expect(r.lines.first.name, 'Tea');
        expect(r.total, '112.00');
        expect(r.staffId, h.session.salesmanId);
        expect(r.deviceId, h.session.deviceIdentifier);
        expect(r.deviceId, isNotNull);
        expect(find.text('Receipt printed.'), findsOneWidget);
      },
    );

    testWidgets(
      'says when it went to the device printer, and why a thermal printer was skipped',
      (tester) async {
        final h = await pumpSuccess(tester);
        h.receipts.print.onPrint = (_) async => const PrintOutcome(
          channel: PrintChannel.system,
          fellBack: true,
          thermalError: 'Cannot reach the printer at 10.0.0.9:9100.',
        );
        await tester.tap(printBtn);
        await tester.pumpAndSettle();
        expect(
          find.text(
            'Cannot reach the printer at 10.0.0.9:9100. Sent to the device printer instead.',
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'plain system print and cancelled system print have their own messages',
      (tester) async {
        final h = await pumpSuccess(tester);
        h.receipts.print.onPrint = (_) async =>
            const PrintOutcome(channel: PrintChannel.system);
        await tester.tap(printBtn);
        await tester.pumpAndSettle();
        expect(
          find.text('Receipt sent to the device printer.'),
          findsOneWidget,
        );
        h.receipts.print.onPrint = (_) async =>
            const PrintOutcome(channel: PrintChannel.system, cancelled: true);
        await tester.tap(printBtn);
        await tester.pumpAndSettle();
        expect(find.text('Printing cancelled.'), findsOneWidget);
      },
    );

    testWidgets('errors are shown as a message and the button works again', (
      tester,
    ) async {
      final h = await pumpSuccess(tester);
      h.receipts.print.onPrint = (_) async => throw const PrintException(
        'This device could not open its print dialog.',
      );
      await tester.tap(printBtn);
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Could not print: This device could not open its print dialog.',
        ),
        findsOneWidget,
      );
      h.receipts.print.onPrint = (_) async => throw StateError('boom');
      await tester.tap(printBtn);
      await tester.pumpAndSettle();
      expect(find.text('Could not print the receipt.'), findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
      expect(tester.widget<OutlinedButton>(printBtn).onPressed, isNotNull);
    });

    testWidgets(
      'is disabled and shows progress while printing (no double print)',
      (tester) async {
        final h = await pumpSuccess(tester);
        final gate = Completer<PrintOutcome>();
        h.receipts.print.onPrint = (_) => gate.future;
        await tester.tap(printBtn);
        await tester.pump();
        expect(find.text('Printing…'), findsOneWidget);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, 'Printing…'),
              )
              .onPressed,
          isNull,
        );
        gate.complete(const PrintOutcome(channel: PrintChannel.thermal));
        await tester.pumpAndSettle();
        expect(h.receipts.print.printed, hasLength(1));
        expect(find.text('Print Receipt'), findsOneWidget);
      },
    );
  });

  group('Email / SMS dialog', () {
    testWidgets(
      'email: validates, then opens a mailto with the receipt and reports it',
      (tester) async {
        final h = await pumpSuccess(tester);
        await tester.tap(sendBtn);
        await tester.pumpAndSettle();
        expect(sendDialog, findsOneWidget);
        expect(find.text('Customer email'), findsOneWidget);

        await tester.tap(find.text('Open email'));
        await tester.pump();
        expect(h.receipts.delivery.opened, isEmpty);
        expect(find.text('Enter an email address.'), findsOneWidget);

        await tester.enterText(find.byType(TextFormField), 'nope');
        await tester.tap(find.text('Open email'));
        await tester.pump();
        expect(h.receipts.delivery.opened, isEmpty);

        await tester.enterText(
          find.byType(TextFormField),
          'buyer@shop.example',
        );
        await tester.tap(find.text('Open email'));
        await tester.pumpAndSettle();
        final uri = h.receipts.delivery.opened.single;
        expect(uri.scheme, 'mailto');
        expect(uri.path, 'buyer@shop.example');
        expect(uri.queryParameters['body'], contains('Tea'));
        expect(uri.queryParameters['body'], contains('112.00'));
        expect(sendDialog, findsNothing);
        expect(
          find.text('Email draft opened — send it from your mail app.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'SMS: switching channel clears the field and uses the phone rules',
      (tester) async {
        final h = await pumpSuccess(tester);
        await tester.tap(sendBtn);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField),
          'buyer@shop.example',
        );
        await tester.tap(find.text('SMS'));
        await tester.pumpAndSettle();
        expect(find.text('Customer phone'), findsOneWidget);
        expect(find.text('buyer@shop.example'), findsNothing);

        await tester.enterText(find.byType(TextFormField), 'abc');
        await tester.tap(find.text('Open messages'));
        await tester.pump();
        expect(h.receipts.delivery.opened, isEmpty);

        await tester.enterText(find.byType(TextFormField), '+1 555 123 4567');
        await tester.tap(find.text('Open messages'));
        await tester.pumpAndSettle();
        final uri = h.receipts.delivery.opened.single;
        expect(uri.scheme, 'sms');
        expect(uri.path, '+15551234567');
        expect(uri.queryParameters['body'], contains('112.00'));
        expect(
          find.text('Message opened — send it from your messaging app.'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'when no app can handle it the dialog stays open with a clear message',
      (tester) async {
        final h = await pumpSuccess(tester);
        h.receipts.delivery.result = false;
        await tester.tap(sendBtn);
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byType(TextFormField),
          'buyer@shop.example',
        );
        await tester.tap(find.text('Open email'));
        await tester.pumpAndSettle();
        expect(sendDialog, findsOneWidget);
        expect(
          find.text('No email app is available on this device.'),
          findsOneWidget,
        );
        // The cashier can correct the address and try again.
        h.receipts.delivery.result = true;
        await tester.tap(find.text('Open email'));
        await tester.pumpAndSettle();
        expect(sendDialog, findsNothing);
      },
    );

    testWidgets('Cancel closes it without opening anything', (tester) async {
      final h = await pumpSuccess(tester);
      await tester.tap(sendBtn);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sendDialog, findsNothing);
      expect(h.receipts.delivery.opened, isEmpty);
    });
  });

  group('Printer setup', () {
    Future<void> openSetup(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Printer setup'));
      await tester.pumpAndSettle();
    }

    testWidgets('saves the address, port and paper width', (tester) async {
      final h = await pumpSuccess(tester);
      await openSetup(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Printer address'),
        '192.168.1.50',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Port'),
        '9101',
      );
      await tester.tap(find.text('58 mm'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final s = await h.receipts.settings.load();
      expect(
        (s.host, s.port, s.paper),
        ('192.168.1.50', 9101, PaperWidth.mm58),
      );
      expect(find.text('Printer settings saved.'), findsOneWidget);
    });

    testWidgets('shows the saved values when reopened and rejects bad input', (
      tester,
    ) async {
      final h = await pumpSuccess(tester);
      await h.receipts.settings.save(
        const PrinterSettings(host: '10.1.1.1', port: 9200),
      );
      await openSetup(tester);
      expect(find.text('10.1.1.1'), findsOneWidget);
      expect(find.text('9200'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Printer address'),
        'bad host',
      );
      await tester.tap(find.text('Save'));
      await tester.pump();
      expect(
        find.text('Enter a valid printer address (IP or host name).'),
        findsOneWidget,
      );
      expect((await h.receipts.settings.load()).host, '10.1.1.1');
    });

    testWidgets('Test print without an address explains what to do', (
      tester,
    ) async {
      await pumpSuccess(tester);
      await openSetup(tester);
      await tester.tap(find.text('Test print'));
      await tester.pump();
      expect(
        find.text('Enter the printer address to test it.'),
        findsOneWidget,
      );
    });

    testWidgets('clearing the address returns to the device print dialog', (
      tester,
    ) async {
      final h = await pumpSuccess(tester);
      await h.receipts.settings.save(const PrinterSettings(host: '10.1.1.1'));
      await openSetup(tester);
      await tester.enterText(
        find.widgetWithText(TextFormField, 'Printer address'),
        '',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect((await h.receipts.settings.load()).thermalConfigured, isFalse);
    });
  });

  group('layout', () {
    for (final (name, w, hgt, scale) in [
      ('phone', 400.0, 800.0, 1.0),
      ('phone 150% text', 400.0, 800.0, 1.5),
      ('tablet 150% text', 1000.0, 800.0, 1.5),
      ('small phone 200% text', 320.0, 640.0, 2.0),
    ]) {
      testWidgets(
        '$name: success buttons and dialogs render without overflow',
        (tester) async {
          await pumpSuccess(tester, width: w, height: hgt, textScale: scale);
          expect(tester.takeException(), isNull);
          await tester.tap(sendBtn.hitTestable());
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(sendDialog, findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('Printer setup'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Save'), findsOneWidget);
        },
      );
    }
  });
}
