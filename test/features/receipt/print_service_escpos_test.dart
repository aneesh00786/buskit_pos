// Phase 11C — the existing PrintService with the ESC/POS layer selectable
// for the LAN printer (PrinterSettings.mode). Default = the unchanged image
// (raster) path; ThermalMode.escPos = EscPosReceiptService +
// NetworkPrinterAdapter (same LAN connection code); any failure falls back to
// the system print engine as before. No printer, no network, no drawer.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/models/receipt_formatter.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_receipt_service.dart';
import 'package:buskit_pos/features/receipt/printing/mock_printer_adapter.dart';
import 'package:buskit_pos/features/receipt/printing/network_printer_adapter.dart';
import 'package:buskit_pos/features/receipt/printing/printer_adapter.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'escpos_receipt_test.dart' show receiptOf, saleJson;
import 'receipt_logic_test.dart' show FakePdfPrinter, RecordingConnection;

const lan = PrinterSettings(
  host: '10.0.0.7',
  port: 9100,
  paper: PaperWidth.mm80,
);
const escPosLan = PrinterSettings(
  host: '10.0.0.7',
  port: 9100,
  paper: PaperWidth.mm80,
  mode: ThermalMode.escPos,
);

void main() {
  late FakePdfPrinter pdf;
  late PrinterSettingsStore store;
  late MockPrinterAdapter mock;
  late List<PrinterSettings> escPosCalls;
  late List<PrinterSettings> rasterCalls;

  setUp(() {
    pdf = FakePdfPrinter();
    store = PrinterSettingsStore(MemoryTokenStore());
    mock = MockPrinterAdapter();
    escPosCalls = [];
    rasterCalls = [];
  });

  PrintService service({
    PrinterConnector? rasterConnector,
    EscPosAdapterFactory? escPos,
  }) => PrintService(
    settings: store,
    pdfPrinter: pdf,
    pdfBuilder: (r) async => Uint8List.fromList(ascii.encode('%PDF-fake')),
    thermalFactory: (s) {
      rasterCalls.add(s);
      return NetworkEscPosPrinter(settings: s, connector: rasterConnector);
    },
    escPosAdapterFactory:
        escPos ??
        (s) {
          escPosCalls.add(s);
          return mock;
        },
  );

  test('settings: the mode defaults to image (also for settings saved before Phase 11C), ESC/POS persists in the same local store', () async {
    expect(const PrinterSettings().mode, ThermalMode.image);
    final tokens = MemoryTokenStore();
    await tokens.write('printer_host', '10.0.0.7');
    expect(
      (await PrinterSettingsStore(tokens).load()).mode,
      ThermalMode.image,
      reason: 'older saved settings',
    );
    await tokens.write('printer_mode', 'nonsense');
    expect((await PrinterSettingsStore(tokens).load()).mode, ThermalMode.image);
    await store.save(escPosLan);
    final back = await store.load();
    expect(
      (back.host, back.port, back.paper, back.mode),
      ('10.0.0.7', 9100, PaperWidth.mm80, ThermalMode.escPos),
    );
    expect(lan.copyWith(mode: ThermalMode.escPos).mode, ThermalMode.escPos);
  });

  testWidgets(
    '1. default (image mode) is unchanged: the raster LAN printer prints, the ESC/POS layer is not used',
    (tester) async {
      await store.save(lan);
      final conn = RecordingConnection();
      final out = await tester.runAsync(
        () =>
            service(rasterConnector: (h, p, t) async => conn)
                .print(receiptOf(saleJson())),
      );
      expect(out!.channel, PrintChannel.thermal);
      expect(out.thermalStatus, isNull);
      expect(rasterCalls, hasLength(1));
      expect(escPosCalls, isEmpty);
      expect(mock.jobs, isEmpty);
      expect(conn.written.sublist(0, 2), [0x1B, 0x40]);
      expect(conn.written, contains(0x76), reason: 'raster GS v 0');
      expect(pdf.jobs, isEmpty);
    },
  );

  test('2. ESC/POS selected: the app\'s adapter for the LAN settings is NetworkPrinterAdapter (no socket opened to check)', () {
    final adapter = PrintService(settings: store).escPosAdapterFor(escPosLan);
    expect(adapter, isA<NetworkPrinterAdapter>());
    expect((adapter as NetworkPrinterAdapter).settings, escPosLan);
  });

  test('3/7. ESC/POS selected: the receipt\'s ESC/POS bytes reach the adapter (mock, no hardware) — no raster, no PDF, no drawer', () async {
    await store.save(escPosLan);
    final receipt = receiptOf(saleJson());
    final out = await service().print(receipt);
    expect(out.channel, PrintChannel.thermal);
    expect(out.fellBack, isFalse);
    expect(out.thermalStatus, PrintStatus.success);
    expect(escPosCalls.single.host, '10.0.0.7');
    final expected = EscPosReceiptService(
      adapter: mock,
      config: NetworkPrinterAdapter.configFor(escPosLan),
    ).render(receipt);
    expect(mock.lastJob!.bytes, expected.bytes);
    expect(mock.lastJob!.columns, 48, reason: '80 mm from the settings');
    expect(
      mock.drawerRequested,
      isFalse,
      reason: 'printing never opens the drawer',
    );
    expect(rasterCalls, isEmpty);
    expect(pdf.jobs, isEmpty);
  });

  test('3b. ESC/POS through the real NetworkPrinterAdapter: the same bytes reach the configured host:port over the existing LAN code', () async {
    await store.save(escPosLan.copyWith(paper: PaperWidth.mm58));
    final conn = RecordingConnection();
    String? host;
    int? port;
    final out = await service(
      escPos: (s) => NetworkPrinterAdapter(
        settings: s,
        connector: (h, p, t) async {
          host = h;
          port = p;
          return conn;
        },
      ),
    ).print(receiptOf(saleJson()));
    expect(out.channel, PrintChannel.thermal);
    expect((host, port), ('10.0.0.7', 9100));
    final expected = EscPosReceiptService(
      adapter: mock,
      config: NetworkPrinterAdapter.configFor(
        escPosLan.copyWith(paper: PaperWidth.mm58),
      ),
    ).render(receiptOf(saleJson()));
    expect(conn.written, expected.bytes);
    expect(conn.flushed && conn.closed, isTrue);
  });

  test('4/5. ESC/POS failure is safe and keeps the existing fallback: unavailable / connection failure -> system print, with the printer\'s message and status', () async {
    await store.save(escPosLan);
    mock.available = false;
    var out = await service().print(receiptOf(saleJson()));
    expect(out.channel, PrintChannel.system);
    expect(out.fellBack, isTrue);
    expect(out.thermalStatus, PrintStatus.printerUnavailable);
    expect(out.thermalError, 'The receipt printer is not available.');
    expect(pdf.jobs, hasLength(1));

    mock
      ..available = true
      ..failWith = PrintStatus.connectionFailure;
    out = await service().print(receiptOf(saleJson()));
    expect(out.channel, PrintChannel.system);
    expect(out.thermalStatus, PrintStatus.connectionFailure);
    expect(pdf.jobs, hasLength(2));

    // The real adapter, printer refusing the connection.
    out = await service(
      escPos: (s) => NetworkPrinterAdapter(
        settings: s,
        connector: (h, p, t) async => throw const SocketException('refused'),
      ),
    ).print(receiptOf(saleJson()));
    expect(out.channel, PrintChannel.system);
    expect(out.fellBack, isTrue);
    expect(out.thermalStatus, PrintStatus.printerUnavailable);
    expect(out.thermalError, 'Cannot reach the printer at 10.0.0.7:9100.');
    expect(rasterCalls, isEmpty, reason: 'no silent switch to the image path');
  });

  test('5b. ESC/POS selected but no printer address: straight to the system print engine (as before), no adapter used', () async {
    await store.save(const PrinterSettings(mode: ThermalMode.escPos));
    final out = await service().print(receiptOf(saleJson()));
    expect(out.channel, PrintChannel.system);
    expect(out.fellBack, isFalse);
    expect(escPosCalls, isEmpty);
    expect(pdf.jobs, hasLength(1));
  });

  test('6. printing (either mode, success or failure) never changes the completed sale or its receipt data', () async {
    final json = saleJson();
    final before = jsonEncode(json);
    final sale = CompletedSale.fromJson(json)!;
    final receipt = ReceiptFormatter.build(
      sale: sale,
      names: const {1: 'Rice'},
    );
    final snapshot = receipt.lines
        .map((l) => '${l.name}|${l.quantity}|${l.unitPrice}|${l.lineTotal}')
        .join(',');
    await store.save(escPosLan);
    await service().print(receipt);
    mock.available = false;
    await service().print(receipt);
    expect(jsonEncode(json), before);
    expect(
      receipt.lines
          .map((l) => '${l.name}|${l.quantity}|${l.unitPrice}|${l.lineTotal}')
          .join(','),
      snapshot,
    );
    expect(
      (receipt.total, receipt.payments.single.amount),
      ('132.00', '132.00'),
    );
    expect(sale.payments.single.amount, 132);
  });
}
