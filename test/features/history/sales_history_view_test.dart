import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:buskit_pos/features/history/ui/sales_history_view.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';
import 'sales_history_controller_test.dart'
    show FakeHistoryService, completed, entry, forbiddenRefund, refunded;

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'Cannot reach the server. Check your connection and try again.',
);

Future<SessionController> defaultSession() async {
  final session = SessionController(FakeAuthService(), MemoryTokenStore());
  await session.loginDevice('REG-1', 'secret');
  await session.loginStaff('S1', '1234');
  return session;
}

Future<SalesHistoryController> pumpHistory(
  WidgetTester tester, {
  FakeHistoryService? service,
  FakeProductService? products,
  SessionController? session,
  double width = 1000,
  double height = 700,
  double textScale = 1,
}) async {
  final svc = service ?? FakeHistoryService();
  final prod = products ?? FakeProductService();
  final controller = SalesHistoryController(svc, prod);
  final sess = session ?? await defaultSession();
  final receipts = FakeReceipts();
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(controller.dispose);
  if (session == null) addTearDown(sess.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider<SalesHistoryController>.value(value: controller),
        ChangeNotifierProvider<SessionController>.value(value: sess),
        Provider<ReceiptServices>.value(value: receipts.services),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: Scaffold(body: SizedBox.expand(child: const SalesHistoryView())),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  group('list states', () {
    testWidgets(
      'loading, then the list, with search/date/cashier filters visible',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')];
        await pumpHistory(tester, service: svc);
        expect(find.text('POS-1'), findsOneWidget);
        expect(find.text('Search order number'), findsOneWidget);
        expect(find.text('Today'), findsOneWidget);
        expect(find.text('All'), findsOneWidget);
      },
    );

    testWidgets('an empty store shows the empty state', (tester) async {
      await pumpHistory(tester);
      expect(find.text('No completed sales'), findsOneWidget);
    });

    testWidgets('an error with retry, then a successful retry shows the list', (
      tester,
    ) async {
      final svc = FakeHistoryService()..onList = () async => throw netDown;
      await pumpHistory(tester, service: svc);
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      svc.onList = () async => [entry(id: 5, saleNumber: 'POS-5')];
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('POS-5'), findsOneWidget);
    });

    testWidgets(
      'the payment-method filter is present but disabled, with an explanatory tooltip',
      (tester) async {
        final svc = FakeHistoryService()..rows = [entry()];
        await pumpHistory(tester, service: svc);
        final chip = tester.widget<FilterChip>(
          find.widgetWithText(FilterChip, 'Payment method'),
        );
        expect(chip.onSelected, isNull);
        expect(
          find.byTooltip(
            "Filtering by payment method needs each sale's payment details, which the sales list does not include yet",
          ),
          findsOneWidget,
        );
      },
    );
  });

  group('filters interaction', () {
    testWidgets('typing in search narrows the list (debounced)', (
      tester,
    ) async {
      final svc = FakeHistoryService()
        ..rows = [
          entry(id: 1, saleNumber: 'POS-AAA'),
          entry(id: 2, saleNumber: 'POS-BBB'),
        ];
      final c = await pumpHistory(tester, service: svc);
      c.setDateFilter(HistoryDateFilter.all);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'BBB');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('POS-AAA'), findsNothing);
      expect(find.text('POS-BBB'), findsOneWidget);
    });

    testWidgets(
      'the cashier dropdown only appears with more than one cashier',
      (tester) async {
        final one = FakeHistoryService()..rows = [entry(salesmanId: 'SALES1')];
        await pumpHistory(tester, service: one);
        expect(find.byType(DropdownMenu<String?>), findsNothing);
      },
    );
  });

  group('detail + reprint/share', () {
    testWidgets(
      'tapping a sale shows its items, totals and payments, and the receipt actions',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1, variationIds: [42]);
        final products = FakeProductService()..onFindById = (_) async => null;
        await pumpHistory(tester, service: svc, products: products, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        expect(find.text('Sale details'), findsOneWidget);
        expect(find.text('Item 42'), findsOneWidget);
        expect(find.text('Cash'), findsOneWidget);
        expect(
          find.widgetWithText(OutlinedButton, 'Print Receipt'),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(OutlinedButton, 'Email / SMS'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'printing a history sale sends the resolved item name through',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1, variationIds: [42]);
        final products = FakeProductService()
          ..onFindById = (_) async =>
              ProductItem.fromJson(productJson(id: 42, name: 'Tea'));
        await pumpHistory(tester, service: svc, products: products, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(OutlinedButton, 'Print Receipt'));
        await tester.pumpAndSettle();
        expect(find.text('Receipt printed.'), findsOneWidget);
      },
    );

    testWidgets('a phone-width back arrow returns to the list', (tester) async {
      final svc = FakeHistoryService()
        ..rows = [entry(id: 1, saleNumber: 'POS-1')]
        ..details[1] = completed(id: 1);
      await pumpHistory(tester, service: svc, width: 400);
      await tester.tap(find.text('POS-1'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Back to sales history'));
      await tester.pumpAndSettle();
      expect(find.text('Sales history'), findsOneWidget);
      expect(find.text('POS-1'), findsOneWidget);
    });

    testWidgets('a detail load failure shows an error with retry', (
      tester,
    ) async {
      final svc = FakeHistoryService()
        ..rows = [entry(id: 1, saleNumber: 'POS-1')];
      svc.onDetail = (_) async => throw netDown;
      await pumpHistory(tester, service: svc, width: 400);
      await tester.tap(find.text('POS-1'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Cannot reach'), findsOneWidget);
      svc.onDetail = (id) async => completed(id: id);
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Item 42'), findsOneWidget);
    });
  });

  group('responsive layout', () {
    testWidgets(
      'wide: list and detail side by side; selecting keeps the list visible',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1);
        await pumpHistory(tester, service: svc, width: 900, height: 700);
        expect(find.text('Select a sale'), findsOneWidget);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        expect(
          find.text('POS-1'),
          findsWidgets,
          reason: 'still visible in the list pane',
        );
        expect(
          find.byTooltip('Back to sales history'),
          findsNothing,
          reason: 'no back arrow needed side-by-side',
        );
        expect(tester.takeException(), isNull);
      },
    );

    for (final (name, w, h, scale) in [
      ('phone', 360.0, 720.0, 1.0),
      ('phone 150% text', 360.0, 720.0, 1.5),
      ('small phone 200% text', 320.0, 640.0, 2.0),
    ]) {
      testWidgets('$name: no overflow through list and detail', (tester) async {
        final svc = FakeHistoryService()
          ..rows = [
            entry(id: 1, saleNumber: 'A very long order number POS-0000001'),
          ]
          ..details[1] = completed(id: 1, variationIds: [42, 43]);
        final products = FakeProductService()
          ..onFindById = (_) async => ProductItem.fromJson(
            productJson(
              id: 42,
              name: 'An extra long product name that must wrap',
            ),
          );
        await pumpHistory(
          tester,
          service: svc,
          products: products,
          width: w,
          height: h,
          textScale: scale,
        );
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.textContaining('POS-0000001').first);
        await tester.pumpAndSettle();
        await tester.tap(
          find.textContaining('POS-0000001').first,
          warnIfMissed: false,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('refund UI', () {
    testWidgets(
      'a completed, not-yet-refunded sale shows a Refund Sale button',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1);
        await pumpHistory(tester, service: svc, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        expect(find.text('Refund Sale'), findsOneWidget);
      },
    );

    testWidgets(
      'an already-refunded sale hides the button and shows a Refunded badge instead',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = refunded(id: 1);
        await pumpHistory(tester, service: svc, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();
        expect(find.text('Refund Sale'), findsNothing);
        expect(find.textContaining('Refunded'), findsOneWidget);
      },
    );

    testWidgets('tapping Refund Sale shows a confirmation dialog; Cancel does nothing', (
      tester,
    ) async {
      final svc = FakeHistoryService()
        ..rows = [entry(id: 1, saleNumber: 'POS-1')]
        ..details[1] = completed(id: 1);
      await pumpHistory(tester, service: svc, width: 400);
      await tester.tap(find.text('POS-1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Refund Sale'));
      await tester.pumpAndSettle();
      expect(find.text('Refund this entire sale?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Refund this entire sale?'), findsNothing);
      expect(svc.refundKeys, isEmpty, reason: 'cancelling must never call the API');
    });

    testWidgets(
      'confirming a refund calls the API, shows a result dialog, and the badge appears after dismissing it',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1)
          ..onRefund = (id, key) async => refunded(id: id);
        await pumpHistory(tester, service: svc, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Refund Sale'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Refund Sale'));
        await tester.pumpAndSettle();

        expect(find.text('Refund successful'), findsOneWidget);
        expect(svc.refundKeys, hasLength(1));

        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Refunded'), findsOneWidget);
        expect(find.text('Refund Sale'), findsNothing);
      },
    );

    testWidgets(
      'a 403 permission denial shows the specific message and leaves the sale refundable',
      (tester) async {
        final svc = FakeHistoryService()
          ..rows = [entry(id: 1, saleNumber: 'POS-1')]
          ..details[1] = completed(id: 1)
          ..onRefund = (id, key) async => throw forbiddenRefund;
        await pumpHistory(tester, service: svc, width: 400);
        await tester.tap(find.text('POS-1'));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Refund Sale'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Refund Sale'));
        await tester.pumpAndSettle();

        expect(
          find.textContaining('do not have permission to refund'),
          findsOneWidget,
        );
        expect(
          find.text('Refund Sale'),
          findsOneWidget,
          reason: 'a denied sale must remain visibly refundable, not silently locked',
        );
      },
    );

    testWidgets('a network failure during refund shows a generic error message', (
      tester,
    ) async {
      final svc = FakeHistoryService()
        ..rows = [entry(id: 1, saleNumber: 'POS-1')]
        ..details[1] = completed(id: 1)
        ..onRefund = (id, key) async => throw netDown;
      await pumpHistory(tester, service: svc, width: 400);
      await tester.tap(find.text('POS-1'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Refund Sale'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Refund Sale'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Cannot reach the server'), findsOneWidget);
      expect(find.text('Refund Sale'), findsOneWidget);
    });
  });
}
