import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:buskit_pos/features/held_sales/state/held_sales_controller.dart';
import 'package:buskit_pos/features/held_sales/ui/held_sales_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../../support/fakes.dart';

late FakeHeldSalesService list;
late FakeCartService service;
late HeldSalesController held;
late CartController cart;

HeldSaleSummary row(
  int id, {
  int version = 2,
  String? number,
  double? total,
  String salesman = 'S1',
}) => HeldSaleSummary.fromJson(
  heldRowJson(
    id: id,
    version: version,
    saleNumber: number,
    total: total,
    salesman: salesman,
  ),
)!;

CartSale view(
  int id, {
  int version = 5,
  String status = 'held',
  List<Map<String, dynamic>>? items,
}) => CartSale.fromJson(
  saleJson(
    id: id,
    version: version,
    status: status,
    items:
        items ??
        [
          lineJson(
            id: 1,
            quantity: 2,
            name: 'Tea',
            unitPrice: 10,
            tax: 1.2,
            lineTotal: 21.2,
          ),
        ],
    subtotal: 20,
    tax: 1.2,
    total: 21.2,
  ),
)!;

Widget host({required Widget child}) => MultiProvider(
  providers: [
    ChangeNotifierProvider<HeldSalesController>.value(value: held),
    ChangeNotifierProvider<CartController>.value(value: cart),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

Future<void> pumpView(
  WidgetTester tester, {
  double width = 420,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(host(child: const HeldSalesView()));
  await tester.pump();
}

/// Opens the list through the real entry point (dialog on tablets, sheet on phones).
Future<void> pumpEntry(
  WidgetTester tester, {
  required double width,
  double height = 800,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    host(
      child: Builder(
        builder: (ctx) => Center(
          child: ElevatedButton(
            onPressed: () => showHeldSales(ctx),
            child: const Text('Open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    list = FakeHeldSalesService();
    service = FakeCartService();
    held = HeldSalesController(list, service);
    cart = CartController(service, onHeldSalesChanged: () => held.refresh());
  });
  tearDown(() {
    held.dispose();
    cart.dispose();
  });

  group('list states', () {
    testWidgets(
      'loading, then rows with sale number, staff and times from the server',
      (tester) async {
        final gate = Completer<List<HeldSaleSummary>>();
        list.onList = () => gate.future;
        await pumpView(tester);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        gate.complete([
          row(12, number: 'POS-00000012', salesman: 'SALES1', total: 56.5),
          row(9),
        ]);
        await tester.pumpAndSettle();
        expect(find.text('POS-00000012'), findsOneWidget);
        expect(find.text('Sale #9'), findsOneWidget);
        expect(find.text('Staff: SALES1'), findsOneWidget);
        expect(find.textContaining('Held '), findsWidgets);
        expect(find.textContaining('Started '), findsWidgets);
        expect(
          find.text('56.50'),
          findsOneWidget,
          reason: 'a total is shown only when the server sends one',
        );
      },
    );

    testWidgets('empty list', (tester) async {
      await pumpView(tester);
      await tester.pumpAndSettle();
      expect(find.text('No held sales'), findsOneWidget);
    });

    testWidgets(
      'retryable error: friendly text (no server internals) and Retry reloads',
      (tester) async {
        list.onList = () async =>
            throw apiError(500, message: 'ER_X at /srv/app.js');
        await pumpView(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('went wrong on the server'), findsOneWidget);
        expect(find.textContaining('/srv/app.js'), findsNothing);
        list.onList = () async => [row(1)];
        await tester.tap(find.text('Retry'));
        await tester.pumpAndSettle();
        expect(find.text('Sale #1'), findsOneWidget);
      },
    );

    testWidgets('network error offers Retry; a non-retryable error does not', (
      tester,
    ) async {
      list.onList = () async => throw const ApiException(
        kind: ApiErrorKind.network,
        message:
            'Cannot reach the server. Check your connection and try again.',
      );
      await pumpView(tester);
      await tester.pumpAndSettle();
      expect(find.text('Retry'), findsOneWidget);

      list.onList = () async => throw apiError(403, message: 'Forbidden here');
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Forbidden here'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets(
      'an expired session (401) shows the sign-in message and no Retry',
      (tester) async {
        list.onList = () async => throw apiError(401);
        await pumpView(tester);
        await tester.pumpAndSettle();
        expect(find.textContaining('session has expired'), findsOneWidget);
        expect(find.text('Retry'), findsNothing);
      },
    );

    testWidgets('a failed refresh keeps the rows visible with a banner', (
      tester,
    ) async {
      list.onList = () async => [row(1)];
      await pumpView(tester);
      await tester.pumpAndSettle();
      list.onList = () async => throw apiError(500);
      await tester.tap(find.byTooltip('Refresh held sales'));
      await tester.pumpAndSettle();
      expect(find.text('Sale #1'), findsOneWidget);
      expect(find.textContaining('went wrong on the server'), findsOneWidget);
    });

    testWidgets('opening the list makes exactly one request', (tester) async {
      list.onList = () async => [row(1)];
      await pumpView(tester);
      await tester.pumpAndSettle();
      expect(list.calls, 1);
    });

    testWidgets(
      'the refresh button is disabled while loading (no duplicate requests)',
      (tester) async {
        final gate = Completer<List<HeldSaleSummary>>();
        list.onList = () => gate.future;
        await pumpView(tester);
        await tester.pump();
        expect(
          tester
              .widget<IconButton>(
                find.widgetWithIcon(IconButton, Icons.refresh),
              )
              .onPressed,
          isNull,
        );
        gate.complete([]);
        await tester.pumpAndSettle();
      },
    );
  });

  group('detail and resume', () {
    Future<void> openFirst(WidgetTester tester, {CartSale? detail}) async {
      list.onList = () async => [row(12, version: 3)];
      service.onGet = (id) async => detail ?? view(id);
      await pumpView(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sale #12'));
      await tester.pumpAndSettle();
    }

    testWidgets('tapping a row shows items and server totals', (tester) async {
      await openFirst(tester);
      expect(find.text('Held sale'), findsOneWidget);
      expect(find.text('Tea'), findsOneWidget);
      expect(find.text('2 × 10.00'), findsOneWidget);
      expect(find.text('21.20'), findsWidgets);
      expect(find.text('Resume sale'), findsOneWidget);
    });

    testWidgets('a detail load error is shown; non-retryable has no Retry', (
      tester,
    ) async {
      list.onList = () async => [row(12)];
      service.onGet = (_) async => throw apiError(
        403,
        message: 'This sale belongs to a different store',
      );
      await pumpView(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sale #12'));
      await tester.pumpAndSettle();
      expect(find.textContaining('different store'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
    });

    testWidgets('back returns to the list', (tester) async {
      await openFirst(tester);
      await tester.tap(find.byTooltip('Back to held sales'));
      await tester.pumpAndSettle();
      expect(find.text('Held sales'), findsOneWidget);
      expect(find.text('Sale #12'), findsOneWidget);
    });

    testWidgets(
      'Resume uses the sale id and the FRESH version from the detail, applies the sale and confirms',
      (tester) async {
        await openFirst(tester);
        service.onResume = (c) async =>
            view(c.saleId, version: c.expectedVersion + 1, status: 'draft');
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();
        final c = service.resumeCalls.single;
        expect(
          (c.saleId, c.expectedVersion),
          (12, 5),
          reason: 'detail version 5, not the list-time version 3',
        );
        expect(cart.sale!.id, 12);
        expect(cart.sale!.isDraft, isTrue);
        expect(find.text('Sale #12 resumed'), findsOneWidget);
      },
    );

    testWidgets('the resumed sale disappears from the list', (tester) async {
      await openFirst(tester);
      service.onResume = (c) async =>
          view(c.saleId, version: 6, status: 'draft');
      list.onList = () async => [];
      await tester.tap(find.text('Resume sale'));
      await tester.pumpAndSettle();
      expect(held.sales, isEmpty);
    });

    testWidgets(
      'a version conflict shows the review message, keeps the sale visible in its current state, and does not retry',
      (tester) async {
        await openFirst(tester);
        service.onResume = (_) async => throw apiError(
          409,
          message: 'Sale has been modified since you last read it',
          data: {'current_version': 9, 'current_status': 'held'},
        );
        service.onGet = (id) async => view(
          id,
          version: 9,
          items: [
            lineJson(
              id: 1,
              quantity: 7,
              name: 'Tea',
              unitPrice: 10,
              lineTotal: 71.2,
            ),
          ],
        );
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();
        expect(find.text(CartController.conflictMessage), findsOneWidget);
        expect(
          find.text('7 × 10.00'),
          findsOneWidget,
          reason: 'the affected sale was reloaded for review',
        );
        expect(service.resumeCalls, hasLength(1));
        expect(cart.error!.currentVersion, 9);
        expect(
          list.calls,
          greaterThan(1),
          reason: 'the list was refreshed too',
        );
      },
    );

    testWidgets('a sale that is already an open draft is read-only here', (
      tester,
    ) async {
      await openFirst(tester, detail: view(12, status: 'draft'));
      expect(find.textContaining('already been resumed'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Resume sale'),
            )
            .onPressed,
        isNull,
      );
    });

    testWidgets('canceled and completed sales cannot be resumed', (
      tester,
    ) async {
      for (final status in ['canceled', 'completed']) {
        held.closeDetail();
        await openFirst(tester, detail: view(12, status: status));
        expect(
          find.textContaining('is $status and is read-only'),
          findsOneWidget,
          reason: status,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resume sale'),
              )
              .onPressed,
          isNull,
        );
      }
    });

    testWidgets(
      'an already-resumed/expired sale (409 not held) explains it and refreshes',
      (tester) async {
        await openFirst(tester);
        service.onResume = (_) async => throw apiError(
          409,
          message: 'Sale is not held (current status: draft)',
        );
        service.onGet = (id) async => view(id, status: 'draft');
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();
        expect(
          find.text(CartController.resumeUnavailableMessage),
          findsOneWidget,
        );
        expect(find.textContaining('already been resumed'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resume sale'),
              )
              .onPressed,
          isNull,
        );
      },
    );

    testWidgets(
      'network failure while resuming is shown, nothing is retried, Resume stays available',
      (tester) async {
        await openFirst(tester);
        service.onResume = (_) async => throw const ApiException(
          kind: ApiErrorKind.network,
          message:
              'Cannot reach the server. Check your connection and try again.',
        );
        await tester.tap(find.text('Resume sale'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Cannot reach the server'), findsOneWidget);
        expect(service.resumeCalls, hasLength(1));
        expect(
          tester
              .widget<FilledButton>(
                find.widgetWithText(FilledButton, 'Resume sale'),
              )
              .onPressed,
          isNotNull,
        );
      },
    );

    testWidgets(
      'double-tapping Resume sends one request; the button is disabled meanwhile',
      (tester) async {
        await openFirst(tester);
        final gate = Completer<CartSale>();
        service.onResume = (_) => gate.future;
        await tester.tap(find.text('Resume sale'));
        await tester.pump();
        expect(
          tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull,
        );
        await tester.tap(find.byType(FilledButton), warnIfMissed: false);
        await tester.pump();
        expect(service.resumeCalls, hasLength(1));
        gate.complete(view(12, version: 6, status: 'draft'));
        await tester.pumpAndSettle();
      },
    );
  });

  group('an open draft is never silently replaced', () {
    Future<void> openWithActiveDraft(WidgetTester tester) async {
      service.onAdd = (_) async => CartSale.fromJson(
        saleJson(
          id: 7,
          version: 2,
          items: [
            lineJson(id: 1, quantity: 2),
            lineJson(id: 2, variationId: 43),
          ],
        ),
      )!;
      await cart.addItem(42, 2);
      list.onList = () async => [row(12, version: 3)];
      service.onGet = (id) async => view(id);
      await pumpView(tester);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sale #12'));
      await tester.pumpAndSettle();
    }

    testWidgets('the action says the open sale will be held first', (
      tester,
    ) async {
      await openWithActiveDraft(tester);
      expect(find.text('Hold current & resume'), findsOneWidget);
      expect(find.textContaining('put on hold first'), findsOneWidget);
    });

    testWidgets(
      'Cancel in the confirmation changes nothing and sends nothing',
      (tester) async {
        await openWithActiveDraft(tester);
        await tester.tap(
          find.widgetWithText(FilledButton, 'Hold current & resume'),
        );
        await tester.pumpAndSettle();
        expect(find.text('You have an open sale'), findsOneWidget);
        expect(find.textContaining('3 items'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(service.holdCalls, isEmpty);
        expect(service.resumeCalls, isEmpty);
        expect(cart.sale!.id, 7);
      },
    );

    testWidgets(
      'confirming holds the current sale first and then resumes the selected one',
      (tester) async {
        await openWithActiveDraft(tester);
        service.onResume = (c) async =>
            view(c.saleId, version: 6, status: 'draft');
        await tester.tap(
          find.widgetWithText(FilledButton, 'Hold current & resume'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Hold current & resume'),
          ),
        );
        await tester.pumpAndSettle();
        expect(service.callLog, ['hold:7', 'resume:12']);
        expect(service.holdCalls.single.expectedVersion, 2);
        expect(cart.sale!.id, 12);
        expect(cart.lastHeldSaleId, 7);
      },
    );

    testWidgets(
      'if resuming fails after the hold, the error is shown and the held draft is safe',
      (tester) async {
        await openWithActiveDraft(tester);
        service.onResume = (_) async => throw apiError(
          409,
          message: 'Sale is not held (current status: draft)',
        );
        await tester.tap(
          find.widgetWithText(FilledButton, 'Hold current & resume'),
        );
        await tester.pumpAndSettle();
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.text('Hold current & resume'),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(CartController.resumeUnavailableMessage),
          findsOneWidget,
        );
        expect(cart.sale, isNull);
        expect(cart.lastHeldSaleId, 7, reason: 'sale 7 is safely on hold');
      },
    );
  });

  group('responsive', () {
    testWidgets('phone: opens as a bottom sheet', (tester) async {
      list.onList = () async => [row(1)];
      await pumpEntry(tester, width: 400);
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.byType(Dialog), findsNothing);
      expect(find.text('Sale #1'), findsOneWidget);
    });

    testWidgets('tablet: opens as a dialog', (tester) async {
      list.onList = () async => [row(1)];
      await pumpEntry(tester, width: 1200, height: 900);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Sale #1'), findsOneWidget);
    });

    testWidgets('Close dismisses it', (tester) async {
      await pumpEntry(tester, width: 400);
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Held sales'), findsNothing);
    });

    for (final size in const [
      Size(320, 568),
      Size(380, 800),
      Size(800, 1000),
      Size(1366, 768),
    ]) {
      testWidgets(
        'no overflow at ${size.width.toInt()}x${size.height.toInt()} (many rows, long names, conflict banner)',
        (tester) async {
          list.onList = () async => [
            for (var i = 1; i <= 12; i++)
              row(
                i,
                number: 'POS-0000000000$i',
                salesman: 'A-VERY-LONG-STAFF-IDENTIFIER-$i',
                total: 123456.789,
              ),
          ];
          service.onGet = (id) async => view(
            id,
            items: [
              for (var i = 1; i <= 8; i++)
                lineJson(
                  id: i,
                  name:
                      'A rather long product name that wraps onto several lines number $i',
                  unitPrice: 123456.789,
                  lineTotal: 1234567.891,
                ),
            ],
          );
          service.onResume = (_) async =>
              throw apiError(409, data: {'current_version': 9});
          await pumpView(tester, width: size.width, height: size.height);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('POS-00000000001'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(FilledButton));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text(CartController.conflictMessage), findsOneWidget);
        },
      );
    }

    testWidgets('touch targets are at least 48dp', (tester) async {
      list.onList = () async => [row(1)];
      await pumpView(tester);
      await tester.pumpAndSettle();
      for (final f in [
        find.byTooltip('Close'),
        find.byTooltip('Refresh held sales'),
      ]) {
        final s = tester.getSize(f);
        expect(s.width, greaterThanOrEqualTo(48));
        expect(s.height, greaterThanOrEqualTo(48));
      }
      expect(
        tester.getSize(find.byType(Card).first).height,
        greaterThanOrEqualTo(72),
      );
    });
  });
}
