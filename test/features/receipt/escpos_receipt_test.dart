// Phase 11A — printer-independent ESC/POS receipt layer: the existing
// receipt (ReceiptFormatter from a server CompletedSale) laid out for 58 / 80
// mm paper as ESC/POS text commands, sent through a PrinterAdapter. Only the
// in-memory MockPrinterAdapter is used — no printer, no network, no drawer.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/data/receipt_pdf.dart';
import 'package:buskit_pos/features/receipt/models/receipt.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_commands.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_receipt_service.dart';
import 'package:buskit_pos/features/receipt/printing/mock_printer_adapter.dart';
import 'package:buskit_pos/features/receipt/printing/printer_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

const cash = PaymentLine(
  method: TenderMethod.cash,
  amountMilli: 132000,
  tenderedMilli: 200000,
);
const card = PaymentLine(method: TenderMethod.card, amountMilli: 132000);

Map<String, dynamic> saleJson({
  List<PaymentLine> payments = const [cash],
  String? customer,
  double discount = 0,
  List<Map<String, dynamic>>? items,
}) {
  final j = completedJson(
    id: 7,
    number: 'POS-00000007',
    customerId: customer,
    payments: payments,
    items:
        items ??
        [
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
            'barcode': '8901234567890',
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
    total: 132 - discount,
  );
  (j['totals'] as Map<String, dynamic>)['discount_total'] = discount;
  return j;
}

ReceiptData receiptOf(
  Map<String, dynamic> json, {
  Map<int, String> names = const {1: 'Basmati Rice', 2: 'Tea'},
}) => ReceiptFormatter.build(
  sale: CompletedSale.fromJson(json)!,
  names: names,
  variants: const {1: '1 kg'},
  title: 'ThriveWoo Supermarket',
  staffId: 'CASHIER-1',
  deviceId: 'REG-1',
  registerLabel: 'R-01',
  headerLines: const ['12 Market Road', 'Kochi 682001'],
);

/// The printable text the job carries (control bytes removed).
String printable(Uint8List bytes) => latin1.decode(
  bytes.where((b) => b == 0x0A || (b >= 0x20 && b <= 0x7E)).toList(),
);

bool hasBytes(Uint8List hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var ok = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        ok = false;
        break;
      }
    }
    if (ok) return true;
  }
  return false;
}

const cutBytes = [0x1D, 0x56, 0x42, 0x00];
const initBytes = [0x1B, 0x40];

void main() {
  late MockPrinterAdapter printer;

  EscPosReceiptService service({
    PaperWidth paper = PaperWidth.mm80,
    bool cut = true,
    EscPosCapabilities caps = const EscPosCapabilities(),
    int? columns,
  }) => EscPosReceiptService(
    adapter: printer,
    config: ReceiptPrinterConfig(
      paper: paper,
      cutEnabled: cut,
      capabilities: caps,
      columnsOverride: columns,
    ),
  );

  setUp(() => printer = MockPrinterAdapter());

  test('1. basic receipt: init first, store header, sale number, date, cashier, register, items, totals, payment, footer', () async {
    final r = await service().print(receiptOf(saleJson()));
    expect(r.ok, isTrue);
    final job = r.job!;
    expect(job.bytes.sublist(0, 2), initBytes);
    final text = printable(job.bytes);
    for (final s in [
      'ThriveWoo Supermarket',
      '12 Market Road',
      'Kochi 682001',
      'POS-00000007',
      'Date',
      'CASHIER-1',
      'R-01',
      'Basmati Rice (1 kg)',
      'Subtotal',
      'TOTAL',
      'Cash',
      'Thank you!',
    ]) {
      expect(text, contains(s), reason: s);
    }
    expect(job.reference, 'POS-00000007');
  });

  test('2/3. 58 mm and 80 mm: columns from the paper width (32 / 48), every line fits; a printer-specific override is honoured', () {
    for (final (paper, cols) in [
      (PaperWidth.mm58, 32),
      (PaperWidth.mm80, 48),
    ]) {
      final job = service(paper: paper).render(receiptOf(saleJson()));
      expect(job.columns, cols);
      expect(job.paper, paper);
      expect(
        job.lines.every((l) => l.length <= cols),
        isTrue,
        reason: '$paper',
      );
      expect(
        job.lines.any((l) => l.length == cols),
        isTrue,
        reason: 'rules use the full width',
      );
    }
    expect(ReceiptColumns.defaultFor(PaperWidth.mm58), 32);
    expect(ReceiptColumns.defaultFor(PaperWidth.mm80), 48);
    final custom = service(columns: 42).render(receiptOf(saleJson()));
    expect(custom.columns, 42, reason: 'e.g. a 512-dot 80 mm head');
    expect(
      ReceiptColumns.resolve(PaperWidth.mm80, override: 5),
      48,
      reason: 'nonsense overrides ignored',
    );
  });

  test('4. multiple line items: each name, its barcode when available, and "qty x unit price ... line total"', () {
    final job = service().render(receiptOf(saleJson()));
    final text = job.lines.join('\n');
    expect(text, contains('Basmati Rice (1 kg)'));
    expect(text, contains('8901234567890'));
    expect(text, contains('Tea'));
    expect(
      job.lines.where(
        (l) =>
            l.trimLeft().startsWith('2 x 50.00') &&
            l.trimRight().endsWith('112.00'),
      ),
      hasLength(1),
    );
    expect(
      job.lines.where(
        (l) =>
            l.trimLeft().startsWith('1 x 20.00') &&
            l.trimRight().endsWith('20.00'),
      ),
      hasLength(1),
    );
  });

  test('5. long product names wrap within the paper width (58 mm) and nothing is lost', () {
    final long =
        'Organic Cold Pressed Extra Virgin Coconut Oil Family Pack Value Edition';
    final job = service(paper: PaperWidth.mm58)
        .render(receiptOf(saleJson(), names: {1: long, 2: 'Tea'}));
    expect(job.lines.every((l) => l.length <= 32), isTrue);
    final joined = job.lines.join(' ').replaceAll(RegExp(r'\s+'), ' ');
    expect(joined, contains(long));
  });

  test('6. quantities are whole units (the POS sells by count) and money is the server figure to 2–3 decimals', () {
    final job = service().render(
      receiptOf(
        saleJson(
          items: [
            {
              'id': 1,
              'product_variation_id': 42,
              'quantity': 3,
              'unit_price': 33.335,
              'tax_percent': 0,
              'tax_included': false,
              'tax_amount': 0,
              'discount_amount': 0,
              'line_total': 100.005,
            },
          ],
        ),
      ),
    );
    final line = job.lines.firstWhere((l) => l.contains(' x '));
    expect(line.trimLeft(), startsWith('3 x 33.335'));
    expect(line.trimRight(), endsWith('100.005'));
    expect(
      job.lines.any((l) => l.startsWith('Subtotal') && l.endsWith('120.00')),
      isTrue,
    );
  });

  test(
    '7/8/9. discount, tax and grand total (bold) from the server totals',
    () {
      final job = service().render(receiptOf(saleJson(discount: 10)));
      expect(
        job.lines.any(
          (l) => l.startsWith('Total discounts') && l.endsWith('-10.00'),
        ),
        isTrue,
      );
      expect(
        job.lines.any((l) => l.startsWith('Tax') && l.endsWith('12.00')),
        isTrue,
      );
      final total = job.lines.firstWhere((l) => l.startsWith('TOTAL'));
      expect(total.trimRight(), endsWith('122.00'));
      // The TOTAL line is printed bold: ESC E 1, the line, ESC E 0.
      expect(
        hasBytes(job.bytes, [
          0x1B,
          0x45,
          0x01,
          ...ascii.encode(total),
          0x0A,
          0x1B,
          0x45,
          0x00,
        ]),
        isTrue,
      );
    },
  );

  test('10. cash payment with tendered amount and change', () {
    final job = service().render(receiptOf(saleJson()));
    final text = job.lines.join('\n');
    expect(
      job.lines.any((l) => l.startsWith('Cash') && l.endsWith('132.00')),
      isTrue,
    );
    expect(
      job.lines.any(
        (l) => l.trim().startsWith('Tendered') && l.endsWith('200.00'),
      ),
      isTrue,
    );
    expect(
      job.lines.any((l) => l.startsWith('CHANGE DUE') && l.endsWith('68.00')),
      isTrue,
    );
    expect(text, isNot(contains('—')));
  });

  test('11. card (or other manual) payment: method and amount, no tendered / change', () {
    final job = service().render(receiptOf(saleJson(payments: const [card])));
    expect(
      job.lines.any((l) => l.startsWith('Card') && l.endsWith('132.00')),
      isTrue,
    );
    expect(job.lines.join('\n'), isNot(contains('Tendered')));
    expect(job.lines.join('\n'), isNot(contains('CHANGE')));
  });

  test('12/13. with a customer the customer label is printed; without one it is a guest checkout', () {
    final withC = service().render(receiptOf(saleJson(customer: 'CUST-9')));
    expect(
      withC.lines.any(
        (l) => l.startsWith('Customer') && l.endsWith('Customer CUST-9'),
      ),
      isTrue,
    );
    final guest = service().render(receiptOf(saleJson()));
    expect(
      guest.lines.any(
        (l) => l.startsWith('Customer') && l.endsWith('Guest checkout'),
      ),
      isTrue,
    );
  });

  test('14. the mock printer receives exactly the rendered job', () async {
    final s = service();
    final receipt = receiptOf(saleJson());
    final r = await s.print(receipt);
    expect(r.status, PrintStatus.success);
    expect(printer.jobs, hasLength(1));
    expect(printer.lastJob!.bytes, s.render(receipt).bytes);
    expect(printer.lastJob!.reference, 'POS-00000007');
  });

  test('15. failures are returned, never thrown: printer unavailable, connection failure, adapter exception, invalid receipt, missing drawer', () async {
    final receipt = receiptOf(saleJson());
    printer.available = false;
    expect(
      (await service().print(receipt)).status,
      PrintStatus.printerUnavailable,
    );
    printer
      ..available = true
      ..failWith = PrintStatus.connectionFailure;
    final f = await service().print(receipt);
    expect(f.status, PrintStatus.connectionFailure);
    expect(f.message, isNotNull);
    expect(printer.jobs, isEmpty);
    final throwing = EscPosReceiptService(adapter: _ThrowingAdapter());
    expect(
      (await throwing.print(receipt)).status,
      PrintStatus.connectionFailure,
    );
    printer.failWith = null;
    final empty = ReceiptData(
      title: 'X',
      orderNumber: 'POS-1',
      customerLabel: 'Guest checkout',
      lines: const [],
      subtotal: '0.00',
      tax: '0.00',
      total: '0.00',
      payments: const [],
    );
    expect((await service().print(empty)).status, PrintStatus.invalidReceipt);
    expect(
      (await service().print(receipt, openDrawer: true)).status,
      PrintStatus.unsupportedCapability,
    );
    expect(printer.jobs, isEmpty);
  });

  test('16. printing is output only: the completed sale and the receipt data are unchanged; nothing but the adapter is used', () async {
    final json = saleJson();
    final before = jsonEncode(json);
    final sale = CompletedSale.fromJson(json)!;
    final receipt = ReceiptFormatter.build(
      sale: sale,
      names: const {1: 'Rice'},
    );
    final linesBefore = receipt.lines
        .map((l) => '${l.name}|${l.quantity}|${l.lineTotal}')
        .toList();
    await service().print(receipt);
    await service(paper: PaperWidth.mm58).print(receipt);
    expect(jsonEncode(json), before);
    expect(
      receipt.lines
          .map((l) => '${l.name}|${l.quantity}|${l.lineTotal}')
          .toList(),
      linesBefore,
    );
    expect(receipt.total, '132.00');
    expect(sale.payments.single.amount, 132);
    expect(printer.jobs, hasLength(2));
  });

  test('17. cut: sent after the feed when enabled and the printer has a cutter; never when disabled or not supported', () {
    final withCut = service().render(receiptOf(saleJson()));
    expect(withCut.cutRequested, isTrue);
    expect(withCut.bytes.sublist(withCut.bytes.length - 4), cutBytes);
    expect(withCut.commands.sublist(withCut.commands.length - 2), [
      'feed:4',
      'cut',
    ]);
    final noCut = service(cut: false).render(receiptOf(saleJson()));
    expect(noCut.cutRequested, isFalse);
    expect(hasBytes(noCut.bytes, cutBytes), isFalse);
    final noCutter = service(caps: EscPosCapabilities.basic)
        .render(receiptOf(saleJson()));
    expect(noCutter.cutRequested, isFalse);
    expect(hasBytes(noCutter.bytes, cutBytes), isFalse);
    expect(
      noCutter.commands,
      isNot(contains('size:1x2')),
      reason: 'no double size without the capability',
    );
  });

  test('18. cash drawer: the ESC p command is defined, never sent unless asked AND supported; the mock only records the request', () async {
    expect(EscPosCommands.drawerPulse(), [0x1B, 0x70, 0x00, 50, 50]);
    expect(EscPosCommands.drawerPulse(pin: 1, onMs: 120, offMs: 240), [
      0x1B,
      0x70,
      0x01,
      60,
      120,
    ]);
    final drawerCaps = service(
      caps: const EscPosCapabilities(cashDrawer: true),
    );
    final plain = drawerCaps.render(receiptOf(saleJson()));
    expect(plain.drawerRequested, isFalse, reason: 'never automatic');
    expect(hasBytes(plain.bytes, [0x1B, 0x70]), isFalse);
    final r = await drawerCaps.print(receiptOf(saleJson()), openDrawer: true);
    expect(r.ok, isTrue);
    expect(printer.drawerRequested, isTrue);
    expect(
      hasBytes(printer.lastJob!.bytes, EscPosCommands.drawerPulse()),
      isTrue,
    );
    expect(printer.type, PrinterConnectionType.mock);
  });

  test('text is reduced to printable ASCII (no code-page assumptions)', () {
    expect(
      EscPosCommands.asciiBytes('Rice × 2 — ₹50 · é'),
      ascii.encode('Rice x 2 - Rs50 - ?'),
    );
  });

  test('the aggregated discount row reads "Total discounts" (not a promotion title) on text, thermal and PDF; amounts unchanged', () async {
    final json = saleJson(discount: 10)
      ..['promotion'] = {
        'id': 5,
        'title': 'Summer Saver',
        'discount_type': 'percentage',
        'discount_value': 5,
        'discount_amount': 6,
        'eligible': true,
      };
    final receipt = receiptOf(json);
    bool labelled(List<String> lines) => lines.any(
      (l) => l.startsWith('Total discounts') && l.endsWith('-10.00'),
    );
    bool titled(List<String> lines) =>
        lines.any((l) => l.contains('Summer Saver'));
    // Text receipt.
    final text = receipt.toLines();
    expect(labelled(text), isTrue);
    expect(titled(text), isFalse);
    expect(
      text.any((l) => l.startsWith('TOTAL') && l.endsWith('122.00')),
      isTrue,
    );
    // Thermal (80 mm, its own column count).
    final job = service().render(receipt);
    expect(labelled(job.lines), isTrue);
    expect(titled(job.lines), isFalse);
    // PDF: decode the page content and read the printed strings.
    final pdf = await buildReceiptPdf(receipt);
    final raw = latin1.decode(pdf);
    final content = StringBuffer();
    for (final m in RegExp(r'(?<!end)stream\r?\n').allMatches(raw)) {
      final end = raw.indexOf('endstream', m.end);
      final bytes = pdf.sublist(m.end, end);
      try {
        content.write(latin1.decode(zlib.decode(bytes)));
      } catch (_) {
        content.write(latin1.decode(bytes));
      }
    }
    // Each word is its own text run: (Total) (discounts) ...
    final printed = RegExp(r'\(([^)]*)\)')
        .allMatches(content.toString())
        .map((m) => m.group(1))
        .join(' ');
    expect(printed, contains('Total discounts -10.00'));
    expect(printed, isNot(contains('Summer')));
    expect(printed, contains('TOTAL 122.00'));
  });
}

class _ThrowingAdapter implements PrinterAdapter {
  @override
  PrinterConnectionType get type => PrinterConnectionType.network;
  @override
  Future<bool> isAvailable() async => true;
  @override
  Future<PrintResult> send(PrintJob job) => throw StateError('socket closed');
}
