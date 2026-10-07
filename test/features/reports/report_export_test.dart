// Phase 14F-C — CSV export of the report on screen: the server's rows,
// totals, period and notes, unchanged (no recalculation, no invented GST
// columns or payment methods), RFC 4180 escaping, UTF-8, safe file names.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/reports/export/report_csv.dart';
import 'package:buskit_pos/features/reports/export/report_file_sharer.dart';
import 'package:buskit_pos/features/reports/models/retail_report.dart';
import 'package:buskit_pos/features/reports/state/reports_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../shift_close/shift_close_view_test.dart' show signedInSession;
import 'reports_test.dart'
    show
        FakeReportService,
        cashiersJson,
        moneyRow,
        productsJson,
        pumpReports,
        registersJson,
        report,
        taxJson,
        openTab;

class FakeSharer implements ReportFileSharer {
  final shared = <(String, Uint8List, String)>[];
  Completer<void>? gate;
  Object? error;

  @override
  Future<void> share({
    required String filename,
    required Uint8List bytes,
    required String mimeType,
    Rect? origin,
  }) async {
    shared.add((filename, bytes, mimeType));
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
  }
}

RetailReport parse(Map<String, dynamic> json) => RetailReport.fromJson(json)!;

List<String> lines(String csv) {
  expect(csv, endsWith('\r\n'));
  return csv.substring(0, csv.length - 2).split('\r\n');
}

/// The header row (first line after the metadata's blank line).
List<String> table(String csv) {
  final l = lines(csv);
  final start = l.indexOf('') + 1;
  return l.sublist(start, l.indexOf('', start));
}

List<String> totalsSection(String csv) {
  final l = lines(csv);
  return l.sublist(l.indexOf('Totals'));
}

const meta = [
  'Report,Product Sales',
  'From,2026-10-07',
  'To,2026-10-07',
  'Timezone,Australia/Sydney',
  'Basis,sales by completion date; refunds by refund date',
];

void main() {
  test('1. product CSV: metadata, header, every server row, totals', () {
    final csv = reportCsv(ReportKind.products, report(ReportKind.products));
    expect(lines(csv), [
      ...meta,
      '',
      'Product Variation ID,Product Name,Variation Name,SKU,Barcode,'
          'Sales Count,Quantity Sold,Quantity Refunded,Net Quantity,'
          'Gross Sales,Refunds,Net Sales,Tax,Refund Tax,Net Tax',
      '42,Basmati Rice,Loose,RICE-1,400638,3,1.250,0.250,1,'
          '25.00,5.00,20.00,2.50,0.50,2.00',
      '7,Tea,,,,2,4,0,4,12.00,0.00,12.00,1.20,0.00,1.20',
      '',
      'Totals',
      'Gross Sales,Refunds,Net Sales,Tax,Refund Tax,Net Tax',
      '999.50,9.00,990.50,99.00,1.00,98.00',
    ]);
  });

  test('2. WEIGHT quantities keep 3 decimals; money keeps a 3rd decimal; '
      'decimal strings are read exactly (no float rounding)', () {
    final json = productsJson();
    final row = (json['rows'] as List).first as Map<String, dynamic>;
    row['quantity_sold'] = '1.250';
    row['quantity_refunded'] = 0.001;
    row['net_quantity'] = 1.249;
    row['gross_sales'] = '0.355';
    row['refunds'] = 0.1 + 0.2; // 0.30000000000000004 from a float sum
    final t = table(reportCsv(ReportKind.products, parse(json)));
    final cells = t[1].split(',');
    expect(cells.sublist(6, 11), ['1.250', '0.001', '1.249', '0.355', '0.30']);
  });

  test('3. cashier CSV: the server\'s payment methods only, in its order', () {
    final json = cashiersJson();
    (json['rows'] as List).add({
      'staff_id': 'S2',
      'staff_name': 'Ben',
      ...moneyRow(),
      'payments': [
        {'method': 'cash', 'tendered': 5, 'refunded': 0, 'net': 5},
      ],
    });
    final csv = reportCsv(ReportKind.cashiers, parse(json));
    final t = table(csv);
    expect(
      t[0],
      'Staff ID,Staff Name,Sales Count,Refunds Count,Gross Sales,Refunds,'
      'Net Sales,Tax,Refund Tax,Net Tax,'
      'card Tendered,card Refunded,card Net,'
      'cash Tendered,cash Refunded,cash Net',
    );
    expect(
      t[1],
      'S1,Asha,5,1,100.00,10.00,90.00,10.00,1.00,9.00,'
      '60.00,0.00,60.00,40.50,10.00,30.50',
    );
    // Ben has no card payments: empty cells, not zeros.
    expect(t[2], endsWith(',9.00,,,,5.00,0.00,5.00'));
    expect(csv.toLowerCase(), isNot(contains('wallet')));
    // Server totals (with its sales_count); no payment totals invented.
    expect(totalsSection(csv), [
      'Totals',
      'Sales Count,Gross Sales,Refunds,Net Sales,Tax,Refund Tax,Net Tax',
      '5,100.00,10.00,90.00,10.00,1.00,9.00',
    ]);
  });

  test('4. register CSV fields and payment breakdown', () {
    final csv = reportCsv(ReportKind.registers, parse(registersJson()));
    final t = table(csv);
    expect(
      t[0],
      startsWith(
        'Register ID,Register Name,Register Code,Sales Count,Refunds Count,'
        'Gross Sales,Refunds,Net Sales,Tax,Refund Tax,Net Tax,card Tendered',
      ),
    );
    expect(t[1], startsWith('3,Front counter,REG-1,5,1,100.00,'));
    expect(t[1], endsWith(',40.50,10.00,30.50'));
    expect(lines(csv).first, 'Report,Register Sales');
  });

  test('5. tax CSV fields', () {
    final t = table(reportCsv(ReportKind.tax, report(ReportKind.tax)));
    expect(t, [
      'Tax Rate,Sales Count,Line Count,Taxable Amount,Tax Amount,'
          'Refund Line Count,Refund Taxable Amount,Refund Tax Amount,'
          'Net Taxable Amount,Net Tax Amount',
      '10,4,6,200.00,20.00,1,50.00,5.00,150.00,15.00',
    ]);
    final json = taxJson();
    json['rows'] = [
      {
        ...(json['rows'] as List).first as Map<String, dynamic>,
        'tax_rate': 12.5,
      },
    ];
    expect(
      table(reportCsv(ReportKind.tax, parse(json)))[1],
      startsWith('12.5,'),
    );
  });

  test(
    '6. tax_components null: no GST columns; the server notes as metadata',
    () {
      final csv = reportCsv(ReportKind.tax, report(ReportKind.tax));
      final t = table(csv);
      for (final gst in ['CGST', 'SGST', 'IGST', 'HSN']) {
        expect(t[0], isNot(contains(gst)), reason: gst);
        expect(totalsSection(csv).join('\n'), isNot(contains(gst)));
      }
      final notes = taxJson()['notes'] as List;
      final l = lines(csv);
      expect(l.sublist(5, 7), ['Note,${notes[0]}', 'Note,${notes[1]}']);
      expect(l[7], '', reason: 'notes stay in the metadata block');
    },
  );

  test('7. totals are the server\'s, exactly (not the sum of the rows)', () {
    final csv = reportCsv(ReportKind.products, report(ReportKind.products));
    // Rows sum to 37.00 gross; the server said 999.5.
    expect(totalsSection(csv).last, '999.50,9.00,990.50,99.00,1.00,98.00');
    final tax = reportCsv(ReportKind.tax, report(ReportKind.tax));
    expect(totalsSection(tax), [
      'Totals',
      'Taxable Amount,Tax Amount,Refund Taxable Amount,Refund Tax Amount,'
          'Net Taxable Amount,Net Tax Amount',
      '200.00,20.00,50.00,5.00,150.00,15.00',
    ]);
  });

  test(
    '8. escaping: commas, quotes, newlines; formula-like text is defused',
    () {
      final json = productsJson();
      final row = (json['rows'] as List).first as Map<String, dynamic>;
      row['product_name'] = 'Rice, "Premium"\nBag';
      row['variation_name'] = '=HYPERLINK("x")';
      row['sku'] = ' padded ';
      final t = table(reportCsv(ReportKind.products, parse(json)));
      // The newline stays inside the quoted field (rows end with CRLF).
      expect(
        t[1],
        '42,"Rice, ""Premium""\nBag","\'=HYPERLINK(""x"")"," padded ",'
        '400638,3,1.250,0.250,1,25.00,5.00,20.00,2.50,0.50,2.00',
      );
      final notes = parse({
        ...taxJson(),
        'notes': ['a, b', 'line1\r\nline2'],
      });
      final l = lines(reportCsv(ReportKind.tax, notes));
      expect(l[5], 'Note,"a, b"');
      expect(l.sublist(6, 8), ['Note,"line1', 'line2"'], reason: 'quoted CRLF');
    },
  );

  test('9. UTF-8 (with BOM) keeps non-ASCII text intact', () {
    final json = productsJson();
    final row = (json['rows'] as List).first as Map<String, dynamic>;
    row['product_name'] = 'അരി — Café ₹';
    final bytes = reportCsvBytes(ReportKind.products, parse(json));
    expect(bytes.sublist(0, 3), [0xEF, 0xBB, 0xBF]);
    final text = utf8.decode(bytes.sublist(3));
    expect(text, reportCsv(ReportKind.products, parse(json)));
    expect(text, contains('42,അരി — Café ₹,Loose'));
  });

  test('12. file names are built from the server period and sanitised', () {
    expect(
      reportFileName(ReportKind.products, report(ReportKind.products)),
      'retail_product_sales_2026-10-07_to_2026-10-07.csv',
    );
    RetailReport withPeriod(Object? from, Object? to) => parse({
      ...taxJson(),
      'period': {'from': from, 'to': to},
    });
    expect(
      reportFileName(ReportKind.tax, withPeriod('../../etc/x', 'a b\\c:d')),
      'retail_tax_______etc_x_to_a_b_c_d.csv',
    );
    expect(
      reportFileName(ReportKind.cashiers, withPeriod(null, null)),
      'retail_cashier_sales_today_to_today.csv',
    );
    final long = reportFileName(
      ReportKind.registers,
      withPeriod('9' * 200, '2026-10-07'),
    );
    expect(long, 'retail_register_sales_${'9' * 32}_to_2026-10-07.csv');
    expect(long, matches(RegExp(r'^[A-Za-z0-9_\-]+\.csv$')));
  });

  group('controller', () {
    test(
      '11. exports the selected report and applied period, with no new request',
      () async {
        final service = FakeReportService();
        // The server echoes the period it was asked for.
        service.onFetch = (k) async {
          final (_, from, to) = service.calls.last;
          final json = switch (k) {
            ReportKind.cashiers => cashiersJson(),
            _ => productsJson(),
          };
          return parse({
            ...json,
            'period': {
              'from': from ?? '2026-10-07',
              'to': to ?? '2026-10-07',
              'timezone': 'Asia/Kolkata',
              'basis': 'b',
            },
          });
        };
        final sharer = FakeSharer();
        final c = ReportsController(
          service,
          kinds: ReportKind.values,
          sharer: sharer,
        );
        await c.load();
        c.setFrom(DateTime(2026, 10, 1));
        c.setTo(DateTime(2026, 10, 7));
        await c.apply();
        await c.select(ReportKind.cashiers);
        final requests = service.calls.length;

        expect(await c.exportCsv(), isTrue);
        expect(service.calls, hasLength(requests), reason: 'no new request');
        final (name, bytes, mime) = sharer.shared.single;
        expect(name, 'retail_cashier_sales_2026-10-01_to_2026-10-07.csv');
        expect(mime, 'text/csv');
        final text = utf8.decode(bytes.sublist(3));
        expect(lines(text).sublist(0, 4), [
          'Report,Cashier Sales',
          'From,2026-10-01',
          'To,2026-10-07',
          'Timezone,Asia/Kolkata',
        ]);
        expect(text, reportCsv(ReportKind.cashiers, c.report!));
        c.dispose();
      },
    );

    test('10. an empty, loading or failed report cannot be exported', () async {
      final service = FakeReportService();
      final sharer = FakeSharer();
      final gate = Completer<RetailReport>();
      service.onFetch = (k) => gate.future;
      final c = ReportsController(
        service,
        kinds: ReportKind.values,
        sharer: sharer,
      );
      final loading = c.load();
      expect(c.canExport, isFalse, reason: 'loading');
      gate.complete(parse({...productsJson(), 'rows': <Object>[]}));
      await loading;
      expect(c.canExport, isFalse, reason: 'no rows');
      expect(await c.exportCsv(), isFalse);
      expect(sharer.shared, isEmpty);
      c.dispose();
    });
  });

  group('screen', () {
    late SessionController session;
    late FakeReportService service;
    late FakeSharer sharer;
    setUp(() async {
      service = FakeReportService();
      sharer = FakeSharer();
      session = await signedInSession();
    });
    tearDown(() => session.dispose());

    ButtonStyleButton exportButton(WidgetTester tester) => tester
        .widget<ButtonStyleButton>(find.byKey(const Key('report-export')));

    testWidgets('Export CSV shares the tab on screen; shows progress', (
      tester,
    ) async {
      sharer.gate = Completer<void>();
      await pumpReports(
        tester,
        service: service,
        session: session,
        sharer: sharer,
      );
      await openTab(tester, ReportKind.registers);
      final calls = service.calls.length;
      await tester.tap(find.byKey(const Key('report-export')));
      await tester.pump();
      expect(find.text('Exporting…'), findsOneWidget);
      expect(exportButton(tester).onPressed, isNull, reason: 'no double tap');
      sharer.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('Export CSV'), findsOneWidget);
      expect(
        sharer.shared.single.$1,
        'retail_register_sales_2026-10-07_to_2026-10-07.csv',
      );
      expect(service.calls, hasLength(calls));
    });

    testWidgets('10. disabled for an empty report', (tester) async {
      service.onFetch = (k) async =>
          parse({...productsJson(), 'rows': <Object>[]});
      await pumpReports(
        tester,
        service: service,
        session: session,
        sharer: sharer,
      );
      expect(exportButton(tester).onPressed, isNull);
      await tester.tap(find.byKey(const Key('report-export')));
      await tester.pumpAndSettle();
      expect(sharer.shared, isEmpty);
    });

    testWidgets('an export failure is shown; the report stays as it was', (
      tester,
    ) async {
      sharer.error = Exception('disk full');
      await pumpReports(
        tester,
        service: service,
        session: session,
        sharer: sharer,
      );
      await tester.tap(find.byKey(const Key('report-export')));
      await tester.pumpAndSettle();
      expect(
        find.text('The CSV could not be exported. Please try again.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('report-totals')), findsOneWidget);
      expect(find.byKey(const Key('report-row-0')), findsOneWidget);
    });
  });
}
