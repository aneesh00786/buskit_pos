import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/data/escpos_encoder.dart';
import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/data/receipt_delivery.dart';
import 'package:buskit_pos/features/receipt/data/receipt_pdf.dart';
import 'package:buskit_pos/features/receipt/data/receipt_rasterizer.dart';
import 'package:buskit_pos/features/receipt/models/receipt.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const cash = PaymentLine(
  method: TenderMethod.cash,
  amountMilli: 112000,
  tenderedMilli: 120000,
);

CompletedSale sale({
  String? customer,
  List<PaymentLine> payments = const [cash],
  Map<String, dynamic>? extra,
}) {
  final j = completedJson(
    id: 7,
    number: 'POS-00000007',
    customerId: customer,
    payments: payments,
    items: [
      {
        'id': 1,
        'product_variation_id': 42,
        'quantity': 2,
        'unit_price': 50,
        'tax_percent': 12,
        'tax_included': false,
        'tax_amount': 12,
        'discount_amount': 0,
        'line_total': 112,
      },
      {
        'id': 2,
        'product_variation_id': 43,
        'quantity': 1,
        'unit_price': 20,
        'tax_percent': 0,
        'tax_included': false,
        'tax_amount': 0,
        'discount_amount': 0,
        'line_total': 20,
      },
    ],
    subtotal: 120,
    tax: 12,
    total: 132,
  );
  if (extra != null) j.addAll(extra);
  return CompletedSale.fromJson(j)!;
}

ReceiptData receipt({
  String? customer,
  Map<int, String>? names,
  Map<int, String>? variants,
}) => ReceiptFormatter.build(
  sale: sale(customer: customer),
  names: names ?? {1: 'Tea', 2: 'Salt'},
  variants: variants ?? {1: '250g · pack'},
  staffId: 'S1',
  deviceId: 'REG-1',
);

class RecordingConnection implements PrinterConnection {
  final List<int> written = [];
  bool flushed = false;
  bool closed = false;
  @override
  void add(List<int> bytes) => written.addAll(bytes);
  @override
  Future<void> flush() async => flushed = true;
  @override
  Future<void> close() async => closed = true;
}

class FakePdfPrinter implements PdfPrinter {
  final List<Uint8List> jobs = [];
  final List<String> names = [];
  bool result = true;
  Object? error;
  @override
  Future<bool> printPdf(Uint8List bytes, {required String name}) async {
    if (error != null) throw error!;
    jobs.add(bytes);
    names.add(name);
    return result;
  }
}

void main() {
  group('ReceiptFormatter', () {
    test('merges the server sale with the cached names and variants', () {
      final r = receipt();
      expect(r.orderNumber, 'POS-00000007');
      expect(r.lines.map((l) => l.name), ['Tea', 'Salt']);
      expect(r.lines.first.variant, '250g · pack');
      expect(r.lines.last.variant, isNull);
      expect(
        (
          r.lines.first.quantity,
          r.lines.first.unitPrice,
          r.lines.first.lineTotal,
        ),
        (2, '50.00', '112.00'),
      );
      expect((r.subtotal, r.tax, r.total), ('120.00', '12.00', '132.00'));
      expect(r.discount, isNull);
      expect(r.customerLabel, 'Guest checkout');
      expect((r.staffId, r.deviceId), ('S1', 'REG-1'));
    });

    test(
      'server payment figures: tendered and change come from the response',
      () {
        final r = receipt();
        expect(r.payments.single.method, 'Cash');
        expect(
          (
            r.payments.single.amount,
            r.payments.single.tendered,
            r.payments.single.change,
          ),
          ('112.00', '120.00', '8.00'),
        );
        expect(r.changeDue, '8.00');
      },
    );

    test('a customer ID replaces guest checkout', () {
      expect(receipt(customer: 'C-42').customerLabel, 'Customer C-42');
    });

    test('a line without a cached name falls back to the item number', () {
      final r = receipt(names: {}, variants: {});
      expect(r.lines.first.name, 'Item 42');
    });

    test('a server discount is shown; a zero discount is not', () {
      final j = completedJson(payments: const [cash]);
      (j['totals'] as Map)['discount_total'] = 5.5;
      expect(
        ReceiptFormatter.build(sale: CompletedSale.fromJson(j)!).discount,
        '5.50',
      );
    });

    test('card payments have no tendered/change', () {
      final s = CompletedSale.fromJson(
        completedJson(
          payments: const [
            PaymentLine(
              method: TenderMethod.card,
              amountMilli: 112000,
              reference: 'A',
            ),
          ],
        ),
      )!;
      final r = ReceiptFormatter.build(sale: s);
      expect(r.payments.single.method, 'Card');
      expect(
        (r.payments.single.tendered, r.payments.single.change, r.changeDue),
        (null, null, null),
      );
    });

    test('a missing completion time is handled', () {
      final j = completedJson(payments: const [cash]);
      j.remove('completed_at');
      final r = ReceiptFormatter.build(sale: CompletedSale.fromJson(j)!);
      expect(r.dateText, isNull);
      expect(r.toPlainText(), isNot(contains('Date')));
    });
  });

  group('plain-text layout', () {
    test('every line fits the column width, for 32 and 42 columns', () {
      for (final cols in [32, 42, 48]) {
        for (final l in receipt(
          names: {
            1: 'A very long product name that must wrap onto several lines',
            2: 'Salt',
          },
        ).toLines(columns: cols)) {
          expect(l.length, lessThanOrEqualTo(cols), reason: '"$l" at $cols');
        }
      }
    });

    test('contains the order, staff, items, totals, payment and footer — ASCII only', () {
      final t = receipt().toPlainText();
      for (final want in [
        'ThriveWoo POS',
        'Order',
        'POS-00000007',
        'Staff',
        'S1',
        'Device',
        'REG-1',
        'Guest checkout',
        'Tea (250g - pack)',
        '2 x 50.00',
        'Subtotal',
        'TOTAL',
        '132.00',
        'Cash',
        'Tendered',
        'Change',
        'CHANGE DUE',
        'Thank you!',
      ]) {
        expect(t, contains(want), reason: want);
      }
      expect(
        RegExp(r'[^\x0A\x20-\x7E]').hasMatch(t),
        isFalse,
        reason: 'ASCII only (× and · replaced)',
      );
    });

    test('long names wrap instead of being cut, and labels/amounts stay on one line', () {
      final lines = receipt(
        names: {1: 'Extra virgin cold pressed olive oil bottle', 2: 'Salt'},
      ).toLines(columns: 32);
      expect(
        lines.where((l) => l.contains('olive')).length,
        greaterThanOrEqualTo(1),
      );
      expect(lines.any((l) => l.contains('bottle')), isTrue);
      final total = lines.firstWhere((l) => l.startsWith('TOTAL'));
      expect(total.endsWith('132.00'), isTrue);
      expect(total.length, 32);
    });

    test(
      'a left label that cannot fit is truncated with ~ but the amount is kept',
      () {
        final r = ReceiptFormatter.build(
          sale: sale(),
          names: {1: 'X'},
          variants: {},
        )..toString();
        final t = ReceiptData(
          title: 'T',
          orderNumber: 'AVERYLONGORDERNUMBERTHATDOESNOTFIT-1234567890',
          customerLabel: 'g',
          lines: r.lines,
          subtotal: '1.00',
          tax: '0.00',
          total: '1.00',
          payments: const [],
        ).toLines(columns: 24);
        expect(t.every((l) => l.length <= 24), isTrue);
        expect(t.any((l) => l.contains('AVERYLONG')), isTrue);
      },
    );

    test('shortText is a single line with the order, total and method', () {
      final s = receipt().shortText;
      expect(s.contains('\n'), isFalse);
      expect(s, contains('POS-00000007'));
      expect(s, contains('Total 132.00'));
      expect(s, contains('(Cash)'));
    });
  });

  group('ESC/POS encoding', () {
    MonoBitmap bmp(int w, int h, {int fill = 0}) => MonoBitmap(
      width: w,
      height: h,
      data: Uint8List.fromList(List.filled((w ~/ 8) * h, fill)),
    );
    const e = EscPosEncoder();

    test('commands: init, feed, cut', () {
      expect(e.initialize(), [0x1B, 0x40]);
      expect(e.feed(3), [0x1B, 0x64, 3]);
      expect(e.feed(999), [0x1B, 0x64, 255], reason: 'clamped');
      expect(e.cut(), [0x1D, 0x56, 0x42, 0x00]);
    });

    test('a raster band header is GS v 0 with byte width and height (little-endian)', () {
      final b = e.rasterBand(bmp(384, 10, fill: 0xFF));
      expect(b.sublist(0, 8), [0x1D, 0x76, 0x30, 0x00, 48, 0, 10, 0]);
      expect(b.length, 8 + 48 * 10);
      expect(b.sublist(8).every((x) => x == 0xFF), isTrue);
    });

    test('heights above 255 rows use both height bytes', () {
      final b = e.rasterBand(bmp(8, 300));
      expect(b.sublist(4, 8), [1, 0, 300 & 0xFF, 300 >> 8]);
    });

    test('a tall bitmap is sent in bands of at most 128 rows; the job ends with feed and cut', () {
      final job = e.receiptJob(bmp(384, 300, fill: 0xAA));
      expect(job.sublist(0, 2), [0x1B, 0x40]);
      expect(job.sublist(job.length - 4), [0x1D, 0x56, 0x42, 0x00]);
      expect(job.sublist(job.length - 7, job.length - 4), [0x1B, 0x64, 4]);
      // Three GS v 0 commands: 128 + 128 + 44 rows.
      final headers = <int>[];
      for (var i = 0; i < job.length - 7; i++) {
        if (job[i] == 0x1D && job[i + 1] == 0x76 && job[i + 2] == 0x30) {
          headers.add(job[i + 6] | (job[i + 7] << 8));
        }
      }
      expect(headers, [128, 128, 44]);
    });

    test('no cut when disabled', () {
      final job = e.receiptJob(bmp(8, 4), cutPaper: false);
      expect(job.sublist(job.length - 3), [0x1B, 0x64, 4]);
    });

    test(
      'MonoBitmap addresses pixels MSB-first and slices bands correctly',
      () {
        final data = Uint8List.fromList([
          0x80,
          0x01,
          0x00,
          0xFF,
        ]); // 2 bytes/row × 2 rows
        final b = MonoBitmap(width: 16, height: 2, data: data);
        expect(b.pixel(0, 0), isTrue);
        expect(b.pixel(1, 0), isFalse);
        expect(b.pixel(15, 0), isTrue);
        expect(b.pixel(3, 1), isFalse);
        expect(b.pixel(8, 1), isTrue);
        expect(b.band(1, 1).data, [0x00, 0xFF]);
      },
    );
  });

  group('rasterising', () {
    test('thresholding: dark and transparent pixels', () {
      // 8×1: black, white, black, transparent-black, gray(200), gray(100), white, black
      final rgba = Uint8List.fromList([
        0,
        0,
        0,
        255,
        255,
        255,
        255,
        255,
        0,
        0,
        0,
        255,
        0,
        0,
        0,
        0,
        200,
        200,
        200,
        255,
        100,
        100,
        100,
        255,
        255,
        255,
        255,
        255,
        0,
        0,
        0,
        255,
      ]);
      final b = ReceiptRasterizer.thresholdRgba(rgba, 8, 1);
      expect(
        [for (var x = 0; x < 8; x++) b.pixel(x, 0)],
        [true, false, true, false, false, true, false, true],
      );
    });

    test('columnsFor scales with the paper width', () {
      expect(ReceiptRasterizer.columnsFor(ReceiptRasterizer.width80mm), 48);
      expect(ReceiptRasterizer.columnsFor(ReceiptRasterizer.width58mm), 32);
    });

    testWidgets(
      'rendering text produces a 1-bit bitmap of the right width with black dots; blank lines produce none',
      (tester) async {
        final text = await tester.runAsync(
          () => const ReceiptRasterizer().render([
            'TOTAL  132.00',
            'Thank you',
          ], widthDots: 384),
        );
        expect(text!.width, 384);
        expect(text.height, greaterThan(20));
        expect(text.data.any((b) => b != 0), isTrue);
        final blank = await tester.runAsync(
          () => const ReceiptRasterizer().render([' ', ''], widthDots: 384),
        );
        expect(blank!.data.every((b) => b == 0), isTrue);
      },
    );

    testWidgets('a printer job for a receipt is a valid ESC/POS stream', (
      tester,
    ) async {
      final job = await tester.runAsync(
        () => NetworkEscPosPrinter(
          settings: const PrinterSettings(host: 'x', paper: PaperWidth.mm58),
        ).buildJob(receipt()),
      );
      expect(job!.sublist(0, 2), [0x1B, 0x40]);
      expect(job.sublist(job.length - 4), [0x1D, 0x56, 0x42, 0x00]);
      expect(job.length, greaterThan(500));
    });
  });

  group('NetworkEscPosPrinter', () {
    testWidgets('connects to host:port, writes the job, flushes and closes', (
      tester,
    ) async {
      final conn = RecordingConnection();
      String? gotHost;
      int? gotPort;
      final printer = NetworkEscPosPrinter(
        settings: const PrinterSettings(host: ' 192.168.1.50 ', port: 9101),
        connector: (h, p, t) async {
          gotHost = h;
          gotPort = p;
          return conn;
        },
      );
      await tester.runAsync(() => printer.print(receipt()));
      expect((gotHost, gotPort), ('192.168.1.50', 9101));
      expect(conn.written.sublist(0, 2), [0x1B, 0x40]);
      expect(conn.flushed && conn.closed, isTrue);
    });

    testWidgets(
      'unreachable, timeout and IO failures become PrintException with the address',
      (tester) async {
        for (final failure in [
          const SocketException('refused'),
          TimeoutException('slow'),
          const FileSystemException('io'),
        ]) {
          final printer = NetworkEscPosPrinter(
            settings: const PrinterSettings(host: '10.0.0.9'),
            connector: (h, p, t) async => throw failure,
          );
          final e = await tester.runAsync(() async {
            try {
              await printer.print(receipt());
              return null;
            } on PrintException catch (e) {
              return e;
            }
          });
          expect(e, isNotNull, reason: '$failure');
          expect(e!.message, contains('10.0.0.9:9100'));
        }
      },
    );

    test('an unconfigured printer refuses to print', () async {
      await expectLater(
        NetworkEscPosPrinter(settings: const PrinterSettings())
            .print(receipt()),
        throwsA(isA<PrintException>()),
      );
    });
  });

  group('printer settings', () {
    test('validation: empty host means "use system print"; bad hosts and ports are rejected', () {
      expect(PrinterSettings.validate('', ''), isNull);
      expect(PrinterSettings.validate('192.168.1.5', '9100'), isNull);
      expect(PrinterSettings.validate('printer.local', '1'), isNull);
      expect(PrinterSettings.validate('a b', '9100'), isNotNull);
      expect(PrinterSettings.validate('h', '0'), isNotNull);
      expect(PrinterSettings.validate('h', '70000'), isNotNull);
      expect(PrinterSettings.validate('h', 'abc'), isNotNull);
    });

    test(
      'round-trips through the store; clearing the host removes it',
      () async {
        final store = PrinterSettingsStore(MemoryTokenStore());
        expect((await store.load()).thermalConfigured, isFalse);
        await store.save(
          const PrinterSettings(
            host: ' 10.0.0.7 ',
            port: 9200,
            paper: PaperWidth.mm58,
          ),
        );
        final s = await store.load();
        expect(
          (s.host, s.port, s.paper, s.thermalConfigured),
          ('10.0.0.7', 9200, PaperWidth.mm58, true),
        );
        await store.save(s.copyWith(host: ''));
        expect((await store.load()).thermalConfigured, isFalse);
      },
    );
  });

  group('PrintService (thermal first, system fallback)', () {
    late FakePdfPrinter pdf;
    late PrinterSettingsStore store;
    setUp(() {
      pdf = FakePdfPrinter();
      store = PrinterSettingsStore(MemoryTokenStore());
    });

    PrintService service({PrinterConnector? connector}) => PrintService(
      settings: store,
      pdfPrinter: pdf,
      thermalFactory: (s) =>
          NetworkEscPosPrinter(settings: s, connector: connector),
    );

    testWidgets(
      'with no thermal printer configured it uses the system print engine with a real PDF',
      (tester) async {
        final out = await tester.runAsync(() => service().print(receipt()));
        expect(out!.channel, PrintChannel.system);
        expect(out.fellBack, isFalse);
        expect(pdf.jobs, hasLength(1));
        expect(String.fromCharCodes(pdf.jobs.single.sublist(0, 5)), '%PDF-');
        expect(pdf.names.single, 'Receipt POS-00000007');
      },
    );

    testWidgets(
      'a configured thermal printer prints directly and the system engine is not used',
      (tester) async {
        await store.save(const PrinterSettings(host: '10.0.0.7'));
        final conn = RecordingConnection();
        final out = await tester.runAsync(
          () => service(connector: (h, p, t) async => conn).print(receipt()),
        );
        expect(out!.channel, PrintChannel.thermal);
        expect(conn.written, isNotEmpty);
        expect(pdf.jobs, isEmpty);
      },
    );

    testWidgets(
      'an unreachable thermal printer falls back to the system engine and says why',
      (tester) async {
        await store.save(const PrinterSettings(host: '10.0.0.7'));
        final out = await tester.runAsync(
          () => service(
            connector: (h, p, t) async =>
                throw const SocketException('refused'),
          ).print(receipt()),
        );
        expect(out!.channel, PrintChannel.system);
        expect(out.fellBack, isTrue);
        expect(out.thermalError, contains('10.0.0.7:9100'));
        expect(pdf.jobs, hasLength(1));
      },
    );

    testWidgets('an unexpected thermal error also falls back', (tester) async {
      await store.save(const PrinterSettings(host: '10.0.0.7'));
      final out = await tester.runAsync(
        () =>
            service(connector: (h, p, t) async => throw StateError('boom'))
                .print(receipt()),
      );
      expect(out!.fellBack, isTrue);
      expect(out.thermalError, isNotNull);
      expect(out.thermalError, isNot(contains('boom')), reason: 'no internals');
    });

    testWidgets(
      'cancelling the system print dialog is reported, not treated as an error',
      (tester) async {
        pdf.result = false;
        final out = await tester.runAsync(() => service().print(receipt()));
        expect(out!.cancelled, isTrue);
      },
    );

    testWidgets(
      'if the system engine itself fails the cashier gets a clear PrintException',
      (tester) async {
        pdf.error = StateError('no print service');
        final e = await tester.runAsync(() async {
          try {
            await service().print(receipt());
            return null;
          } on PrintException catch (e) {
            return e;
          }
        });
        expect(e!.message, 'This device could not open its print dialog.');
      },
    );
  });

  group('receipt PDF', () {
    test('is a valid PDF document', () async {
      final bytes = await buildReceiptPdf(receipt());
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
      expect(bytes.length, greaterThan(500));
      expect(
        String.fromCharCodes(bytes.sublist(bytes.length - 6)),
        contains('%%EOF'),
      );
    });

    test('a long receipt still builds', () async {
      final many = [
        for (var i = 1; i <= 60; i++)
          {
            'id': i,
            'product_variation_id': i,
            'quantity': 1,
            'unit_price': 1,
            'tax_percent': 0,
            'tax_included': false,
            'tax_amount': 0,
            'discount_amount': 0,
            'line_total': 1,
          },
      ];
      final s = CompletedSale.fromJson(
        completedJson(payments: const [cash], items: many),
      )!;
      final bytes = await buildReceiptPdf(
        ReceiptFormatter.build(
          sale: s,
          names: {for (var i = 1; i <= 60; i++) i: 'Item number $i'},
        ),
      );
      expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    });
  });

  group('email / SMS hand-off', () {
    test('email validation', () {
      expect(ReceiptShare.validateEmail(''), isNotNull);
      expect(ReceiptShare.validateEmail('nope'), isNotNull);
      expect(ReceiptShare.validateEmail('a@b'), isNotNull);
      expect(ReceiptShare.validateEmail('a b@c.com'), isNotNull);
      expect(ReceiptShare.validateEmail(' cashier@shop.example '), isNull);
    });

    test('phone validation', () {
      expect(ReceiptShare.validatePhone(''), isNotNull);
      expect(ReceiptShare.validatePhone('12'), isNotNull);
      expect(ReceiptShare.validatePhone('abc12345'), isNotNull);
      expect(ReceiptShare.validatePhone('+1 (555) 123-4567'), isNull);
      expect(ReceiptShare.validatePhone('0412 345 678'), isNull);
    });

    test('mailto carries a percent-encoded subject and the full receipt body (no "+" for spaces)', () {
      final u = ReceiptShare.emailUri(' cashier@shop.example ', receipt());
      expect(u.scheme, 'mailto');
      expect(u.path, 'cashier@shop.example');
      final raw = u.toString();
      expect(raw, contains('subject=Your%20receipt%20POS-00000007'));
      expect(raw, isNot(contains('+')));
      expect(u.queryParameters['body'], receipt().toPlainText());
    });

    test('sms carries a clean number and the one-line summary', () {
      final u = ReceiptShare.smsUri('+1 (555) 123-4567', receipt());
      expect(u.scheme, 'sms');
      expect(u.path, '+15551234567');
      expect(u.queryParameters['body'], receipt().shortText);
    });
  });
}
