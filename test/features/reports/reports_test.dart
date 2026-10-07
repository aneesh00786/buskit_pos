// Phase 14F-B — Retail POS Reports UI over the existing Phase 14F-A
// endpoints. Rows AND totals are the server's; WEIGHT quantities stay
// decimal; the tax tab shows no invented GST split; dates are both-or-none.
import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/reports/data/report_service.dart';
import 'package:buskit_pos/features/reports/export/report_file_sharer.dart';
import 'package:buskit_pos/features/reports/models/retail_report.dart';
import 'package:buskit_pos/features/reports/state/reports_controller.dart';
import 'package:buskit_pos/features/reports/ui/reports_view.dart';
import 'package:buskit_pos/features/shell/ui/pos_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import '../shift_close/shift_close_view_test.dart' show signedInSession;

class FakeReportService implements ReportService {
  final calls = <(ReportKind, String?, String?)>[];
  Future<RetailReport> Function(ReportKind kind)? onFetch;

  @override
  Future<RetailReport> fetch(ReportKind kind, {String? from, String? to}) {
    calls.add((kind, from, to));
    return onFetch?.call(kind) ?? Future.value(report(kind));
  }
}

Map<String, dynamic> period() => {
  'from': '2026-10-07',
  'to': '2026-10-07',
  'timezone': 'Australia/Sydney',
  'basis': 'sales by completion date; refunds by refund date',
};

Map<String, dynamic> productsJson() => {
  'period': period(),
  'rows': [
    {
      'product_variation_id': 42,
      'product_name': 'Basmati Rice',
      'variation_name': 'Loose',
      'sku': 'RICE-1',
      'barcode': '400638',
      'sales_count': 3,
      'quantity_sold': 1.25,
      'quantity_refunded': 0.25,
      'net_quantity': 1,
      'gross_sales': 25,
      'refunds': 5,
      'net_sales': 20,
      'tax': 2.5,
      'refund_tax': 0.5,
      'net_tax': 2,
    },
    {
      'product_variation_id': 7,
      'product_name': 'Tea',
      'variation_name': null,
      'sku': null,
      'barcode': null,
      'sales_count': 2,
      'quantity_sold': 4,
      'quantity_refunded': 0,
      'net_quantity': 4,
      'gross_sales': 12,
      'refunds': 0,
      'net_sales': 12,
      'tax': 1.2,
      'refund_tax': 0,
      'net_tax': 1.2,
    },
  ],
  // Deliberately NOT the sum of the rows: the UI must show these.
  'totals': {
    'gross_sales': 999.5,
    'refunds': 9,
    'net_sales': 990.5,
    'tax': 99,
    'refund_tax': 1,
    'net_tax': 98,
  },
};

Map<String, dynamic> moneyRow() => {
  'sales_count': 5,
  'refunds_count': 1,
  'gross_sales': 100,
  'refunds': 10,
  'net_sales': 90,
  'tax': 10,
  'refund_tax': 1,
  'net_tax': 9,
  'payments': [
    {'method': 'card', 'tendered': 60, 'refunded': 0, 'net': 60},
    {'method': 'cash', 'tendered': 40.5, 'refunded': 10, 'net': 30.5},
  ],
};

Map<String, dynamic> cashiersJson() => {
  'period': period(),
  'rows': [
    {'staff_id': 'S1', 'staff_name': 'Asha', ...moneyRow()},
  ],
  'totals': {
    'sales_count': 5,
    'gross_sales': 100,
    'refunds': 10,
    'net_sales': 90,
    'tax': 10,
    'refund_tax': 1,
    'net_tax': 9,
  },
};

Map<String, dynamic> registersJson() => {
  'period': period(),
  'rows': [
    {
      'register_id': 3,
      'register_name': 'Front counter',
      'register_code': 'REG-1',
      ...moneyRow(),
    },
  ],
  'totals': cashiersJson()['totals'],
};

Map<String, dynamic> taxJson() => {
  'period': period(),
  'rows': [
    {
      'tax_rate': 10,
      'sales_count': 4,
      'line_count': 6,
      'taxable_amount': 200,
      'tax_amount': 20,
      'refund_line_count': 1,
      'refund_taxable_amount': 50,
      'refund_tax_amount': 5,
      'net_taxable_amount': 150,
      'net_tax_amount': 15,
    },
  ],
  'totals': {
    'taxable_amount': 200,
    'tax_amount': 20,
    'refund_taxable_amount': 50,
    'refund_tax_amount': 5,
    'net_taxable_amount': 150,
    'net_tax_amount': 15,
  },
  'tax_components': null,
  'notes': [
    'One combined tax rate per sale line (the POS stores no CGST/SGST/IGST split and no HSN code); a GST component report cannot be derived from the stored data.',
    'Taxable amount = line total − tax.',
  ],
};

RetailReport report(ReportKind k) => RetailReport.fromJson(switch (k) {
  ReportKind.products => productsJson(),
  ReportKind.cashiers => cashiersJson(),
  ReportKind.registers => registersJson(),
  ReportKind.tax => taxJson(),
})!;

String valueOf(WidgetTester tester, String key) =>
    tester.widget<Text>(find.byKey(Key(key))).data!;

Future<void> pumpReports(
  WidgetTester tester, {
  required FakeReportService service,
  required SessionController session,
  ReportFileSharer? sharer,
}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<SessionController>.value(
      value: session,
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () =>
                    showReports(context, service: service, sharer: sharer),
                child: const Text('Open reports'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open reports'));
  await tester.pumpAndSettle();
}

Future<void> openTab(WidgetTester tester, ReportKind k) async {
  await tester.tap(find.byKey(Key('report-tab-${k.path}')));
  await tester.pumpAndSettle();
}

void main() {
  late SessionController session;
  late FakeReportService service;
  setUp(() async {
    service = FakeReportService();
    session = await signedInSession();
  });
  tearDown(() => session.dispose());

  group('1. date range', () {
    test(
      'default = today (no dates sent); one date alone is refused with no call; '
      'To before From and more than 366 days are refused; both dates are sent',
      () async {
        final c = ReportsController(service, kinds: ReportKind.values);
        await c.load();
        expect(service.calls.single, (ReportKind.products, null, null));

        c.setFrom(DateTime(2026, 10, 1));
        await c.apply();
        expect(c.validation, contains('both a From and a To'));
        expect(service.calls, hasLength(1), reason: 'no API call');

        c.setTo(DateTime(2026, 9, 30));
        await c.apply();
        expect(c.validation, contains('must not be before'));
        expect(service.calls, hasLength(1));

        c.setFrom(DateTime(2025, 10, 1));
        c.setTo(DateTime(2026, 10, 2)); // 367 days inclusive
        await c.apply();
        expect(c.validation, contains('366 days'));
        expect(service.calls, hasLength(1));

        c.setTo(DateTime(2026, 10, 1)); // 366 days inclusive
        await c.apply();
        expect(c.validation, isNull);
        expect(service.calls.last, (
          ReportKind.products,
          '2025-10-01',
          '2026-10-01',
        ));

        await c.today();
        expect(service.calls.last, (ReportKind.products, null, null));
        c.dispose();
      },
    );

    test('the API client sends both dates or neither', () async {
      final urls = <Uri>[];
      final client = PosApiClient(
        baseUrl: 'http://pos.test',
        httpClient: MockClient((r) async {
          urls.add(r.url);
          return http.Response.bytes(
            utf8.encode(jsonEncode({'status': true, 'data': taxJson()})),
            200,
          );
        }),
        tokenProvider: () => 't',
      );
      final s = ApiReportService(client);
      await s.fetch(ReportKind.tax);
      await s.fetch(ReportKind.cashiers, from: '2026-10-01', to: '2026-10-07');
      expect(urls[0].path, endsWith('/reports/tax'));
      expect(urls[0].queryParameters, isEmpty);
      expect(urls[1].path, endsWith('/reports/cashiers'));
      expect(urls[1].queryParameters, {
        'from': '2026-10-01',
        'to': '2026-10-07',
      });
    });

    testWidgets('a one-sided range shows the message on screen', (
      tester,
    ) async {
      await pumpReports(tester, service: service, session: session);
      await tester.tap(find.byKey(const Key('report-from')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('report-apply')));
      await tester.pumpAndSettle();
      expect(valueOf(tester, 'report-validation'), contains('both a From'));
      expect(service.calls, hasLength(1), reason: 'only the initial load');
    });
  });

  testWidgets('2. product sales render (name, SKU/barcode, counts, money)', (
    tester,
  ) async {
    await pumpReports(tester, service: service, session: session);
    expect(find.text('Product Sales'), findsOneWidget);
    expect(valueOf(tester, 'report-0-title'), 'Basmati Rice — Loose');
    expect(valueOf(tester, 'report-0-subtitle'), 'SKU RICE-1 · Barcode 400638');
    expect(valueOf(tester, 'report-0-sales_count'), '3');
    expect(valueOf(tester, 'report-0-gross_sales'), '25.00');
    expect(valueOf(tester, 'report-0-refunds'), '5.00');
    expect(valueOf(tester, 'report-0-net_sales'), '20.00');
    expect(valueOf(tester, 'report-0-tax'), '2.50');
    expect(valueOf(tester, 'report-0-net_tax'), '2.00');
    expect(valueOf(tester, 'report-1-title'), 'Tea');
    expect(find.byKey(const Key('report-1-subtitle')), findsNothing);
    expect(valueOf(tester, 'report-period'), contains('Australia/Sydney'));
  });

  testWidgets('3. WEIGHT quantities stay decimal; PIECE stays whole', (
    tester,
  ) async {
    await pumpReports(tester, service: service, session: session);
    expect(valueOf(tester, 'report-0-quantity_sold'), '1.250');
    expect(valueOf(tester, 'report-0-quantity_refunded'), '0.250');
    expect(valueOf(tester, 'report-0-net_quantity'), '1');
    expect(valueOf(tester, 'report-1-quantity_sold'), '4');
  });

  testWidgets(
    '4. cashier sales show the payment breakdown exactly as returned',
    (tester) async {
      await pumpReports(tester, service: service, session: session);
      await openTab(tester, ReportKind.cashiers);
      expect(service.calls.last.$1, ReportKind.cashiers);
      expect(valueOf(tester, 'report-0-title'), 'Asha');
      expect(valueOf(tester, 'report-0-refunds_count'), '1');
      expect(
        valueOf(tester, 'report-0-pay-cash'),
        'cash: tendered 40.50 · refunded 10.00 · net 30.50',
      );
      expect(
        valueOf(tester, 'report-0-pay-card'),
        'card: tendered 60.00 · refunded 0.00 · net 60.00',
      );
      expect(find.textContaining('wallet'), findsNothing, reason: 'none sent');
    },
  );

  testWidgets('5. register sales render', (tester) async {
    await pumpReports(tester, service: service, session: session);
    await openTab(tester, ReportKind.registers);
    expect(valueOf(tester, 'report-0-title'), 'Front counter');
    expect(valueOf(tester, 'report-0-subtitle'), 'REG-1');
    expect(valueOf(tester, 'report-0-sales_count'), '5');
    expect(valueOf(tester, 'report-0-net_sales'), '90.00');
    expect(find.byKey(const Key('report-0-pay-cash')), findsOneWidget);
  });

  testWidgets('6. tax report renders every rate field', (tester) async {
    await pumpReports(tester, service: service, session: session);
    await openTab(tester, ReportKind.tax);
    expect(valueOf(tester, 'report-0-title'), 'Tax rate 10%');
    final expected = {
      'sales_count': '4',
      'line_count': '6',
      'taxable_amount': '200.00',
      'tax_amount': '20.00',
      'refund_line_count': '1',
      'refund_taxable_amount': '50.00',
      'refund_tax_amount': '5.00',
      'net_taxable_amount': '150.00',
      'net_tax_amount': '15.00',
    };
    expected.forEach((k, v) => expect(valueOf(tester, 'report-0-$k'), v));
  });

  testWidgets(
    '7. no fake GST: only the server note mentions CGST/SGST/IGST; no HSN',
    (tester) async {
      await pumpReports(tester, service: service, session: session);
      await openTab(tester, ReportKind.tax);
      expect(valueOf(tester, 'report-tax-note'), taxJson()['notes'][0]);
      // The words appear only inside the backend's note.
      expect(find.textContaining('CGST'), findsOneWidget);
      expect(find.textContaining('IGST'), findsOneWidget);
      expect(find.text('CGST'), findsNothing);
      expect(find.text('SGST'), findsNothing);
      expect(find.text('HSN'), findsNothing);
      expect(find.byKey(const Key('report-0-cgst')), findsNothing);
    },
  );

  testWidgets('8. a backend error is shown with Retry; retry reloads', (
    tester,
  ) async {
    var fail = true;
    service.onFetch = (k) async {
      if (fail) {
        throw ApiException.fromStatus(500, message: 'Database unavailable');
      }
      return report(k);
    };
    await pumpReports(tester, service: service, session: session);
    expect(find.byKey(const Key('report-error')), findsOneWidget);
    expect(find.byKey(const Key('report-totals')), findsNothing);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('report-error')), findsNothing);
    expect(find.byKey(const Key('report-totals')), findsOneWidget);
  });

  testWidgets('9. an empty period says so (server zero totals still shown)', (
    tester,
  ) async {
    service.onFetch = (k) async => RetailReport.fromJson({
      ...cashiersJson(),
      'rows': <Object>[],
      'totals': {
        'sales_count': 0,
        'gross_sales': 0,
        'refunds': 0,
        'net_sales': 0,
        'tax': 0,
        'refund_tax': 0,
        'net_tax': 0,
      },
    })!;
    await pumpReports(tester, service: service, session: session);
    expect(find.byKey(const Key('report-empty')), findsOneWidget);
    expect(find.byKey(const Key('report-row-0')), findsNothing);
    expect(valueOf(tester, 'report-total-net_sales'), '0.00');
  });

  testWidgets('10. totals are the API\'s totals, never a sum of the rows', (
    tester,
  ) async {
    await pumpReports(tester, service: service, session: session);
    // Rows sum to 37 gross; the server said 999.5.
    expect(valueOf(tester, 'report-total-gross_sales'), '999.50');
    expect(valueOf(tester, 'report-total-refunds'), '9.00');
    expect(valueOf(tester, 'report-total-net_sales'), '990.50');
    expect(valueOf(tester, 'report-total-tax'), '99.00');
    expect(valueOf(tester, 'report-total-net_tax'), '98.00');
    await openTab(tester, ReportKind.cashiers);
    expect(valueOf(tester, 'report-total-sales_count'), '5');
  });

  group('11. permissions', () {
    testWidgets('a 403 from the server shows the permission message', (
      tester,
    ) async {
      service.onFetch = (k) async => throw ApiException.fromStatus(
        403,
        errorCode: PosErrorCodes.permissionDenied,
        data: {'permission': 'reports.product'},
      );
      await pumpReports(tester, service: service, session: session);
      expect(
        find.text('You do not have permission to view product sales reports.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('report-totals')), findsNothing);
    });

    testWidgets('tabs known to be denied are hidden; the first allowed loads', (
      tester,
    ) async {
      session.dispose();
      session = await signedInSession(
        permissions: ['reports.cashier', 'reports.tax'],
      );
      await pumpReports(tester, service: service, session: session);
      expect(find.byKey(const Key('report-tab-products')), findsNothing);
      expect(find.byKey(const Key('report-tab-registers')), findsNothing);
      expect(find.byKey(const Key('report-tab-cashiers')), findsOneWidget);
      expect(find.byKey(const Key('report-tab-tax')), findsOneWidget);
      expect(service.calls.single.$1, ReportKind.cashiers);
    });

    testWidgets('no report permission at all: a notice and no request', (
      tester,
    ) async {
      session.dispose();
      session = await signedInSession(permissions: ['sales.create']);
      await pumpReports(tester, service: service, session: session);
      expect(find.text('No reports available'), findsOneWidget);
      expect(service.calls, isEmpty);
    });
  });

  group('sidebar', () {
    Widget sidebar({VoidCallback? onOpenReports}) => MaterialApp(
      home: Scaffold(
        body: PosSidebar(
          collapsed: false,
          brandTitle: 'POS',
          onOpenReports: onOpenReports,
        ),
      ),
    );

    testWidgets('Reports appears only when wired and opens it', (tester) async {
      tester.view.physicalSize = const Size(400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(sidebar());
      expect(find.text('Reports'), findsNothing);
      var opened = 0;
      await tester.pumpWidget(sidebar(onOpenReports: () => opened++));
      await tester.tap(find.text('Reports'));
      expect(opened, 1);
    });
  });
}
