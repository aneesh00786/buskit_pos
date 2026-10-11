// Phases P1.1 / P1.2 — `sales.reprint`. Printing a receipt AGAIN needs the
// permission: every print from sales history, and any print after the first
// successful one on the sale-complete screen. The first print of a new sale
// (manual or auto) is always allowed. Printing is local, so the button AND the
// print action check it; "Test print" never prints a copy of the sale without
// it. A reprint FAILS CLOSED: it needs permissions that loaded successfully
// and include `sales.reprint` (not loaded / failed to load = refused).
import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/models/receipt.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:buskit_pos/features/receipt/ui/receipt_actions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import '../history/sales_history_controller_test.dart' show FakeHistoryService, completed, entry;
import '../history/sales_history_view_test.dart' show pumpHistory;

const saleReceipt = ReceiptData(
  title: 'ThriveWoo POS',
  orderNumber: 'POS-42',
  customerLabel: 'Walk-in',
  lines: [],
  subtotal: '100.00',
  tax: '0.00',
  total: '100.00',
  payments: [],
);

PosAuthContext contextWith(List<String> permissions) => PosAuthContext(
  staff: const StaffInfo(salesmanId: 'S1', role: StaffRole(id: 1, name: 'Cashier')),
  permissions: permissions,
);

/// A signed-in session whose loaded permissions are [permissions]; null =
/// the auth context never loaded. Returns the fake auth too, so a test can
/// change what the next load returns.
Future<(SessionController, FakeAuthService)> sessionAndAuth(List<String>? permissions) async {
  final auth = FakeAuthService()..onAuthContext = (t) async => permissions == null ? null : contextWith(permissions);
  final session = SessionController(auth, MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return (session, auth);
}

Future<SessionController> sessionWith(List<String>? permissions) async => (await sessionAndAuth(permissions)).$1;

Future<void> settle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
  await tester.pumpAndSettle();
}

Future<FakeReceipts> pumpActions(
  WidgetTester tester, {
  required SessionController session,
  bool reprint = false,
  String? autoPrintKey,
  FakeReceipts? receipts,
}) async {
  final r = receipts ?? FakeReceipts();
  addTearDown(session.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SessionController>.value(value: session),
        Provider<ReceiptServices>.value(value: r.services),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: ReceiptActions(receipt: saleReceipt, reprint: reprint, autoPrintKey: autoPrintKey),
          ),
        ),
      ),
    ),
  );
  await settle(tester);
  return r;
}

bool printEnabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.byKey(const Key('receipt-print'))).onPressed != null;

final deniedNotice = find.byKey(const Key('receipt-reprint-denied'));

/// Calls the print action directly — as if the disabled button were bypassed.
Future<void> printDirectly(WidgetTester tester) async {
  await tester.state<ReceiptActionsState>(find.byType(ReceiptActions)).printReceipt();
  await settle(tester);
}

void main() {
  group('reprint decision (fails closed)', () {
    test('allowed only with LOADED permissions that include sales.reprint', () async {
      expect(reprintRefusal(null), reprintUnverifiedMessage, reason: 'no session');
      expect(reprintRefusal(await sessionWith(null)), reprintUnverifiedMessage, reason: 'not loaded');
      expect(reprintRefusal(await sessionWith(['sales.view'])), reprintDeniedMessage);
      expect(reprintRefusal(await sessionWith(['sales.reprint'])), isNull);
    });

    test('a failed permission load is refused, never allowed', () async {
      final auth = FakeAuthService()..onAuthContext = (t) async => throw const ApiException(kind: ApiErrorKind.network, message: 'offline');
      final session = SessionController(auth, MemoryTokenStore());
      await session.loginDevice('REG-1', 'secret');
      await session.loginStaff('S1', '1234');
      expect(session.authContextError, isNotNull);
      expect(reprintRefusal(session), reprintUnverifiedMessage);
    });
  });

  group('sales history (every print is a reprint)', () {
    testWidgets('authorized: with sales.reprint the receipt is reprinted', (tester) async {
      final r = await pumpActions(tester, session: await sessionWith(['sales.view', 'sales.reprint']), reprint: true);
      expect(printEnabled(tester), isTrue);
      expect(deniedNotice, findsNothing);
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(r.print.printed, [saleReceipt]);
    });

    testWidgets('denied: without sales.reprint nothing prints; the reason is shown; Test print gets the test receipt, never the sale', (tester) async {
      final r = await pumpActions(tester, session: await sessionWith(['sales.view']), reprint: true);
      expect(printEnabled(tester), isFalse);
      expect(find.text(reprintDeniedMessage), findsOneWidget);
      await tester.tap(find.text('Print Receipt'), warnIfMissed: false);
      await settle(tester);
      expect(r.print.printed, isEmpty);
      await tester.tap(find.byTooltip('Printer setup'));
      await settle(tester);
      expect(tester.widget<PrinterSetupDialog>(find.byType(PrinterSetupDialog)).receipt, same(testPrintReceipt));
      expect(r.print.printed, isEmpty);
    });

    testWidgets('the print action itself refuses an unauthorized reprint when the button is bypassed', (tester) async {
      for (final perms in [null, ['sales.view']]) {
        final r = await pumpActions(tester, session: await sessionWith(perms), reprint: true);
        await printDirectly(tester);
        expect(r.print.printed, isEmpty, reason: '$perms');
        expect(find.text(perms == null ? reprintUnverifiedMessage : reprintDeniedMessage), findsWidgets);
        await tester.pumpWidget(const SizedBox());
      }
      final ok = await pumpActions(tester, session: await sessionWith(['sales.reprint']), reprint: true);
      await printDirectly(tester);
      expect(ok.print.printed, [saleReceipt], reason: 'the direct path still prints when authorized');
    });

    testWidgets('the print action re-checks at call time: a permission removed after the screen was built is refused', (tester) async {
      final (session, auth) = await sessionAndAuth(['sales.reprint']);
      final r = await pumpActions(tester, session: session, reprint: true);
      expect(printEnabled(tester), isTrue);
      auth.onAuthContext = (t) async => contextWith(['sales.view']);
      await tester.runAsync(session.refreshAuthContext);
      // No rebuild yet: the stale button is still wired; the action decides.
      await tester.state<ReceiptActionsState>(find.byType(ReceiptActions)).printReceipt();
      await settle(tester);
      expect(r.print.printed, isEmpty);
      expect(printEnabled(tester), isFalse);
    });

    testWidgets('permission loading: refused (with its own reason) until permissions load; allowed once they do', (tester) async {
      final (session, auth) = await sessionAndAuth(null);
      final r = await pumpActions(tester, session: session, reprint: true);
      expect(printEnabled(tester), isFalse);
      expect(find.text(reprintUnverifiedMessage), findsOneWidget);
      await tester.tap(find.byTooltip('Printer setup'));
      await settle(tester);
      expect(tester.widget<PrinterSetupDialog>(find.byType(PrinterSetupDialog)).receipt, same(testPrintReceipt));
      await tester.tap(find.text('Cancel'));
      await settle(tester);
      auth.onAuthContext = (t) async => contextWith(['sales.reprint']);
      await tester.runAsync(session.refreshAuthContext);
      await settle(tester);
      expect(printEnabled(tester), isTrue);
      expect(deniedNotice, findsNothing);
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(r.print.printed, [saleReceipt]);
    });

    for (final (perms, enabled) in [(['sales.view'], false), (['sales.view', 'sales.reprint'], true)]) {
      testWidgets('history screen: the sale detail gates its Print Receipt on sales.reprint ($perms)', (tester) async {
        final session = await sessionWith(perms);
        addTearDown(session.dispose);
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1);
        await pumpHistory(tester, service: svc, session: session, width: 400, height: 1400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.byKey(const Key('receipt-print')));
        expect(printEnabled(tester), enabled);
        expect(deniedNotice, enabled ? findsNothing : findsOneWidget);
      });
    }
  });

  group('sale-complete screen (the first print is the original — never gated)', () {
    for (final perms in [null, ['sales.view']]) {
      testWidgets('first print allowed without sales.reprint (permissions ${perms ?? 'not loaded'}); printing again is refused', (tester) async {
        final r = await pumpActions(tester, session: await sessionWith(perms));
        expect(printEnabled(tester), isTrue);
        expect(deniedNotice, findsNothing);
        await tester.tap(find.text('Print Receipt'));
        await settle(tester);
        expect(r.print.printed, hasLength(1));
        expect(printEnabled(tester), isFalse);
        expect(deniedNotice, findsOneWidget);
        await printDirectly(tester);
        expect(r.print.printed, hasLength(1), reason: 'no second copy, even directly');
      });
    }

    testWidgets('authorized: printing again works', (tester) async {
      final r = await pumpActions(tester, session: await sessionWith(['sales.reprint']));
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(r.print.printed, hasLength(2));
      expect(deniedNotice, findsNothing);
    });

    testWidgets('failed-print retry: a cancelled or failed first print is not a print, so trying again needs no permission', (tester) async {
      final r = FakeReceipts();
      var n = 0;
      r.print.onPrint = (_) async {
        n++;
        if (n == 1) return const PrintOutcome(channel: PrintChannel.system, cancelled: true);
        if (n == 2) throw const PrintException('Printer offline');
        return const PrintOutcome(channel: PrintChannel.thermal);
      };
      await pumpActions(tester, session: await sessionWith(null), receipts: r);
      for (var i = 0; i < 3; i++) {
        expect(printEnabled(tester), isTrue, reason: 'attempt ${i + 1}');
        await tester.tap(find.text('Print Receipt'));
        await settle(tester);
      }
      expect(r.print.printed, hasLength(3));
      expect(printEnabled(tester), isFalse, reason: 'printed now; a further print is a reprint');
    });

    for (final perms in [null, ['sales.view']]) {
      testWidgets('auto-print prints the original once (permissions ${perms ?? 'not loaded'}); a manual print afterwards is a refused reprint', (tester) async {
        final r = FakeReceipts();
        await tester.runAsync(() => r.settings.save(const PrinterSettings(autoPrint: true)));
        await pumpActions(tester, session: await sessionWith(perms), receipts: r, autoPrintKey: 'sale:42');
        await settle(tester);
        expect(r.print.printed, hasLength(1), reason: 'the original');
        expect(printEnabled(tester), isFalse);
        await printDirectly(tester);
        expect(r.print.printed, hasLength(1));
      });
    }

    testWidgets('auto-print, authorized: the manual reprint afterwards prints', (tester) async {
      final r = FakeReceipts();
      await tester.runAsync(() => r.settings.save(const PrinterSettings(autoPrint: true)));
      await pumpActions(tester, session: await sessionWith(['sales.reprint']), receipts: r, autoPrintKey: 'sale:42');
      await settle(tester);
      await tester.tap(find.text('Print Receipt'));
      await settle(tester);
      expect(r.print.printed, hasLength(2));
    });
  });
}
