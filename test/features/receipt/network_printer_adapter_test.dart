// Phase 11B — the Phase 11A PrinterAdapter for the EXISTING LAN printer
// (NetworkPrinterAdapter -> NetworkEscPosPrinter.sendBytes). A fake
// transport stands in for the TCP socket: no printer, no network.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:buskit_pos/features/receipt/data/printer_driver.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/printing/escpos_receipt_service.dart';
import 'package:buskit_pos/features/receipt/printing/network_printer_adapter.dart';
import 'package:buskit_pos/features/receipt/printing/printer_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'escpos_receipt_test.dart' show receiptOf, saleJson;

/// The fake transport: records what is written; can fail at each step.
class FakeConnection implements PrinterConnection {
  FakeConnection({this.failOnAdd, this.failOnFlush, this.failOnClose});
  final Object? failOnAdd;
  final Object? failOnFlush;
  final Object? failOnClose;
  final List<int> written = [];
  bool flushed = false;
  bool closed = false;

  @override
  void add(List<int> bytes) {
    if (failOnAdd != null) throw failOnAdd!;
    written.addAll(bytes);
  }

  @override
  Future<void> flush() async {
    if (failOnFlush != null) throw failOnFlush!;
    flushed = true;
  }

  @override
  Future<void> close() async {
    if (failOnClose != null) throw failOnClose!;
    closed = true;
  }
}

class Transport {
  Transport([FakeConnection? conn]) : conn = conn ?? FakeConnection();
  final FakeConnection conn;
  Object? connectError;
  final List<(String, int, Duration)> connects = [];

  Future<PrinterConnection> connect(
    String host,
    int port,
    Duration timeout,
  ) async {
    connects.add((host, port, timeout));
    if (connectError != null) throw connectError!;
    return conn;
  }
}

const lan = PrinterSettings(
  host: ' 192.168.1.50 ',
  port: 9101,
  paper: PaperWidth.mm58,
);
// Same printer, address stored without padding (the existing printer builds
// its error message from the stored host as-is).
const lanClean = PrinterSettings(
  host: '192.168.1.50',
  port: 9101,
  paper: PaperWidth.mm58,
);

void main() {
  test('successful send: the rendered ESC/POS job reaches the configured host:port byte for byte, then flush + close', () async {
    final t = Transport();
    final adapter = NetworkPrinterAdapter(settings: lan, connector: t.connect);
    final service = EscPosReceiptService(
      adapter: adapter,
      config: NetworkPrinterAdapter.configFor(lan),
    );
    final receipt = receiptOf(saleJson());
    final r = await service.print(receipt);
    expect(r.status, PrintStatus.success);
    expect(r.job!.reference, 'POS-00000007');
    expect(
      t.connects.single.$1,
      '192.168.1.50',
      reason: 'host trimmed, as the existing printer does',
    );
    expect(t.connects.single.$2, 9101);
    expect(t.connects.single.$3, const Duration(seconds: 5));
    expect(t.conn.written, service.render(receipt).bytes, reason: 'unchanged');
    expect(r.job!.columns, 32, reason: '58 mm from the LAN settings');
    expect(t.conn.flushed && t.conn.closed, isTrue);
  });

  test('bytes are passed through unchanged (any job, including cut / drawer bytes)', () async {
    final t = Transport();
    final bytes = Uint8List.fromList([
      0x1B,
      0x40,
      0x41,
      0x0A,
      0x1B,
      0x70,
      0x00,
      50,
      50,
      0x1D,
      0x56,
      0x42,
      0x00,
      0xFF,
    ]);
    final job = PrintJob(
      bytes: bytes,
      reference: 'X',
      paper: PaperWidth.mm80,
      columns: 48,
      lines: const [],
      commands: const [],
    );
    final r = await NetworkPrinterAdapter(
      settings: lan,
      connector: t.connect,
    ).send(job);
    expect(r.ok, isTrue);
    expect(t.conn.written, bytes);
  });

  test('unavailable: no printer address -> printerUnavailable without connecting; refused / timed out / unknown host -> printerUnavailable', () async {
    final t = Transport();
    final none = NetworkPrinterAdapter(
      settings: const PrinterSettings(),
      connector: t.connect,
    );
    expect(await none.isAvailable(), isFalse);
    final service = EscPosReceiptService(adapter: none);
    expect(
      (await service.print(receiptOf(saleJson()))).status,
      PrintStatus.printerUnavailable,
    );
    expect(t.connects, isEmpty);

    for (final failure in [
      const SocketException('refused'),
      TimeoutException('slow'),
      const SocketException('Failed host lookup'),
    ]) {
      final t2 = Transport()..connectError = failure;
      final adapter = NetworkPrinterAdapter(
        settings: lanClean,
        connector: t2.connect,
      );
      expect(
        await adapter.isAvailable(),
        isTrue,
        reason: 'configured; reachability is reported by send',
      );
      final r = await EscPosReceiptService(adapter: adapter)
          .print(receiptOf(saleJson()));
      expect(r.status, PrintStatus.printerUnavailable, reason: '$failure');
      expect(r.message, contains('192.168.1.50:9101'));
      expect(t2.conn.written, isEmpty);
    }
  });

  test('connection / write failure after connecting -> connectionFailure; unexpected errors never leak raw text', () async {
    for (final conn in [
      FakeConnection(failOnFlush: const SocketException('broken pipe')),
      FakeConnection(failOnClose: const SocketException('reset')),
      FakeConnection(failOnFlush: const FileSystemException('io')),
    ]) {
      final r = await EscPosReceiptService(
        adapter: NetworkPrinterAdapter(
          settings: lanClean,
          connector: Transport(conn).connect,
        ),
      ).print(receiptOf(saleJson()));
      expect(r.status, PrintStatus.connectionFailure);
      expect(r.message, contains('192.168.1.50:9101'));
    }
    final odd = await EscPosReceiptService(
      adapter: NetworkPrinterAdapter(
        settings: lanClean,
        connector: Transport(FakeConnection(failOnAdd: StateError('boom')))
            .connect,
      ),
    ).print(receiptOf(saleJson()));
    expect(odd.status, PrintStatus.connectionFailure);
    expect(odd.message, isNot(contains('boom')));
    expect(odd.message, isNot(contains('StateError')));
  });

  test('configFor: the LAN settings give the Phase 11A config (network, paper, name)', () {
    final c = NetworkPrinterAdapter.configFor(lan);
    expect(c.connectionType, PrinterConnectionType.network);
    expect(c.paper, PaperWidth.mm58);
    expect(c.columns, 32);
    expect(c.printerName, '192.168.1.50:9101');
    expect(
      NetworkPrinterAdapter(settings: lan).type,
      PrinterConnectionType.network,
    );
  });

  test('the existing raster path still uses the same connection code (PrintException messages unchanged, unconfigured refused)', () async {
    final t = Transport()..connectError = const SocketException('refused');
    final printer = NetworkEscPosPrinter(settings: lan, connector: t.connect);
    await expectLater(
      printer.sendBytes([0x1B, 0x40]),
      throwsA(
        isA<PrintException>()
            .having(
              (e) => e.message,
              'message',
              'Cannot reach the printer at  192.168.1.50 :9101.',
            )
            .having((e) => e.connected, 'connected', isFalse),
      ),
    );
    await expectLater(
      NetworkEscPosPrinter(settings: const PrinterSettings()).sendBytes([1]),
      throwsA(isA<PrintException>()),
    );
  });
}
