// Phase 14A — cash drawer through the existing ESC/POS printer layer.
// Automatic: opened ONCE after a COMPLETED cash sale (never card / QR /
// other, never before or without success, never twice on retry). Manual
// "no sale": recorded on the server first (payments.cash_drawer), then
// opened. A drawer failure never undoes a sale. No hardware is used.
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/cash_movements/data/no_sale_service.dart';
import 'package:buskit_pos/features/cash_movements/state/no_sale_action.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_commands.dart';
import 'package:buskit_pos/features/receipt/printing/mock_printer_adapter.dart';
import 'package:buskit_pos/features/receipt/printing/printer_adapter.dart';
import 'package:buskit_pos/features/receipt/state/cash_drawer_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../checkout/pay_modal_test.dart'
    show completeBtn, openPay, pumpWithCart, typeInto;

const withDrawer = PrinterSettings(host: '10.0.0.9', cashDrawer: true);

class FakeNoSale implements NoSaleService {
  final keys = <String>[];
  Object? failWith;
  @override
  Future<void> recordNoSale({
    required String idempotencyKey,
    String? reason,
  }) async {
    keys.add(idempotencyKey);
    if (failWith != null) throw failWith!;
  }
}

void main() {
  group('CashDrawerService', () {
    late PrinterSettingsStore settings;
    late MockPrinterAdapter adapter;
    late CashDrawerService drawer;

    setUp(() {
      settings = PrinterSettingsStore(MemoryTokenStore());
      adapter = MockPrinterAdapter();
      drawer = CashDrawerService(
        settings: settings,
        adapterFactory: (_) => adapter,
      );
    });

    test('settings: "cash drawer connected" is stored and declared to the ESC/POS layer', () async {
      expect((await settings.load()).cashDrawer, isFalse, reason: 'default');
      await settings.save(withDrawer);
      final s = await settings.load();
      expect((s.cashDrawer, s.drawerConfigured), (true, true));
    });

    test('a cash sale opens the drawer ONCE: drawer-only job (ESC @ + ESC p), no receipt, no cut', () async {
      await settings.save(withDrawer);
      final a = await drawer.openForCashSale('sale:42');
      final b = await drawer.openForCashSale('sale:42');
      expect(a.status, DrawerOpenStatus.opened);
      expect(b.status, DrawerOpenStatus.alreadyOpened);
      expect(adapter.jobs, hasLength(1));
      final job = adapter.jobs.single;
      expect(job.drawerRequested, isTrue);
      expect(job.cutRequested, isFalse);
      expect(job.lines, isEmpty);
      expect(job.commands, ['initialize', 'drawer:0']);
      expect(job.bytes.sublist(2), EscPosCommands.drawerPulse());
      // Simultaneous calls for one sale still pulse once; another sale opens.
      await Future.wait([
        drawer.openForCashSale('sale:43'),
        drawer.openForCashSale('sale:43'),
      ]);
      expect(adapter.jobs, hasLength(2));
    });

    test('no drawer set up (no printer, or drawer not connected): nothing is sent, never pretended', () async {
      expect(
        (await drawer.openForCashSale('sale:1')).status,
        DrawerOpenStatus.notConfigured,
      );
      await settings.save(const PrinterSettings(host: '10.0.0.9'));
      final r = await drawer.open();
      expect(r.status, DrawerOpenStatus.notConfigured);
      expect(r.message, CashDrawerService.notConfiguredMessage);
      expect(adapter.jobs, isEmpty);
    });

    test('printer unreachable or failing: a safe "failed" result, never thrown, no address exposed', () async {
      await settings.save(withDrawer);
      adapter.available = false;
      final a = await drawer.openForCashSale('sale:9');
      expect(a.status, DrawerOpenStatus.failed);
      expect(a.message, isNot(contains('10.0.0.9')));
      adapter
        ..available = true
        ..failWith = PrintStatus.connectionFailure;
      expect((await drawer.open()).status, DrawerOpenStatus.failed);
      expect(adapter.jobs, isEmpty);
    });
  });

  group('manual "open drawer / no sale"', () {
    late PrinterSettingsStore settings;
    late MockPrinterAdapter adapter;
    late FakeNoSale server;
    late NoSaleAction action;

    setUp(() async {
      settings = PrinterSettingsStore(MemoryTokenStore());
      await settings.save(withDrawer);
      adapter = MockPrinterAdapter();
      server = FakeNoSale();
      var n = 0;
      action = NoSaleAction(
        service: server,
        drawer: CashDrawerService(
          settings: settings,
          adapterFactory: (_) => adapter,
        ),
        newKey: () => 'nosale-key-${++n}',
      );
    });

    test(
      'with permission: recorded on the server FIRST, then the drawer opens',
      () async {
        final r = await action.run();
        expect(r.outcome, NoSaleOutcome.opened);
        expect(server.keys, ['nosale-key-1']);
        expect(adapter.jobs.single.drawerRequested, isTrue);
        // Each tap is its own request (own key).
        await action.run();
        expect(server.keys, ['nosale-key-1', 'nosale-key-2']);
      },
    );

    test('without permission: the normal permission message and the drawer is NOT opened', () async {
      server.failWith = ApiException.fromStatus(
        403,
        errorCode: 'POS_PERMISSION_DENIED',
        data: {'permission': 'payments.cash_drawer'},
      );
      final r = await action.run();
      expect(r.outcome, NoSaleOutcome.refused);
      expect(
        r.message,
        'You do not have permission to open the cash drawer. Ask a manager.',
      );
      expect(adapter.jobs, isEmpty);
    });

    test(
      'no drawer set up: a clear message; nothing recorded and nothing sent',
      () async {
        await settings.save(const PrinterSettings(host: '10.0.0.9'));
        final r = await action.run();
        expect(r.outcome, NoSaleOutcome.notConfigured);
        expect(r.message, CashDrawerService.notConfiguredMessage);
        expect(server.keys, isEmpty);
        expect(adapter.jobs, isEmpty);
      },
    );

    test('recorded but the printer fails: says so (never claims the drawer opened)', () async {
      adapter.available = false;
      final r = await action.run();
      expect(r.outcome, NoSaleOutcome.recordedNotOpened);
      expect(
        r.message,
        startsWith('The no-sale was recorded, but the drawer did not open.'),
      );
    });
  });

  group('after payment (pay screen)', () {
    Future<void> enableDrawer(dynamic h) =>
        h.receipts.settings.save(withDrawer) as Future<void>;

    testWidgets(
      'a completed CASH sale opens the drawer once ("Cash drawer opened.")',
      (tester) async {
        final h = await pumpWithCart(tester);
        await tester.runAsync(() => enableDrawer(h));
        await openPay(tester);
        expect(
          h.receipts.drawerAdapter.jobs,
          isEmpty,
          reason: 'not just for opening the pay screen',
        );
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.receipts.drawerAdapter.jobs, hasLength(1));
        expect(find.byKey(const Key('cash-drawer-opened')), findsOneWidget);
        // Rebuilds of the success screen never pulse again.
        await tester.pump();
        await tester.pumpAndSettle();
        expect(h.receipts.drawerAdapter.jobs, hasLength(1));
      },
    );

    testWidgets('a CARD sale does not open the drawer', (tester) async {
      final h = await pumpWithCart(tester);
      await tester.runAsync(() => enableDrawer(h));
      await openPay(tester);
      await tester.tap(find.widgetWithText(ChoiceChip, 'Card'));
      await tester.pumpAndSettle();
      await tester.tap(completeBtn);
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Sale complete'), findsOneWidget);
      expect(h.receipts.drawerAdapter.jobs, isEmpty);
    });

    testWidgets(
      'a QR sale (tendered as "other" with a provider attempt) does not open the drawer',
      (tester) async {
        final h = await pumpWithCart(tester);
        await tester.runAsync(() => enableDrawer(h));
        // The server-confirmed tenders decide: what the QR path records.
        h.carts.onComplete = (c) async => CompletedSale.fromJson(
          completedJson(
            payments: const [
              PaymentLine(
                method: TenderMethod.other,
                amountMilli: 112000,
                paymentAttemptId: 5,
              ),
            ],
          ),
        )!;
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.receipts.drawerAdapter.jobs, isEmpty);
      },
    );

    testWidgets(
      'Phase 15G: a Pine Labs card sale (card tender with a provider attempt) does not open the drawer',
      (tester) async {
        final h = await pumpWithCart(tester);
        await tester.runAsync(() => enableDrawer(h));
        h.carts.onComplete = (c) async => CompletedSale.fromJson(
          completedJson(
            payments: const [
              PaymentLine(
                method: TenderMethod.card,
                amountMilli: 112000,
                paymentAttemptId: 9,
              ),
            ],
          ),
        )!;
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.receipts.drawerAdapter.jobs, isEmpty);
      },
    );

    testWidgets(
      'a FAILED cash payment does not open the drawer; the successful retry opens it exactly once',
      (tester) async {
        final h = await pumpWithCart(tester);
        await tester.runAsync(() => enableDrawer(h));
        h.carts.onComplete = (_) async => throw const ApiException(
          kind: ApiErrorKind.network,
          message:
              'Cannot reach the server. Check your connection and try again.',
        );
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        expect(find.text('Retry payment'), findsOneWidget);
        expect(h.receipts.drawerAdapter.jobs, isEmpty);

        // The retry reuses the same key; the server returns the (replayed) sale.
        h.carts.onComplete = (c) async =>
            CompletedSale.fromJson(completedJson(payments: c.payments))!;
        await tester.tap(find.text('Retry payment'));
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(h.carts.completeCalls, hasLength(2));
        expect(h.carts.completeCalls.first.key, h.carts.completeCalls.last.key);
        expect(h.receipts.drawerAdapter.jobs, hasLength(1));
      },
    );

    testWidgets(
      'a drawer failure never undoes the sale: "Sale complete" stays, with a warning',
      (tester) async {
        final h = await pumpWithCart(tester);
        await tester.runAsync(() => enableDrawer(h));
        h.receipts.drawerAdapter.available = false;
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.carts.completeCalls, hasLength(1));
        expect(h.carts.cancelCalls, isEmpty);
        expect(find.byKey(const Key('cash-drawer-failed')), findsOneWidget);
        expect(find.textContaining('The sale is complete.'), findsOneWidget);
      },
    );

    testWidgets(
      'no drawer set up: the cash sale completes normally and nothing is sent or shown',
      (tester) async {
        final h = await pumpWithCart(tester);
        await openPay(tester);
        await typeInto(tester, 'Amount tendered', '120');
        await tester.tap(completeBtn);
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Sale complete'), findsOneWidget);
        expect(h.receipts.drawerAdapter.jobs, isEmpty);
        expect(find.byKey(const Key('cash-drawer-failed')), findsNothing);
        expect(find.byKey(const Key('cash-drawer-opened')), findsNothing);
      },
    );
  });

  test('the cart sale model is untouched (sanity)', () {
    expect(CartSaleFactory.sale().isDraft, isTrue);
  });
}
