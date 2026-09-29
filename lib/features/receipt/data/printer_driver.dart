import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/receipt.dart';
import '../models/receipt_formatter.dart';
import 'escpos_encoder.dart';
import 'printer_settings.dart';
import 'receipt_rasterizer.dart';

class PrintException implements Exception {
  const PrintException(this.message);
  final String message;
  @override
  String toString() => 'PrintException: $message';
}

/// A write-only channel to a printer. The default wraps a TCP [Socket]; tests
/// substitute a recorder.
abstract class PrinterConnection {
  void add(List<int> bytes);
  Future<void> flush();
  Future<void> close();
}

typedef PrinterConnector = Future<PrinterConnection> Function(
  String host,
  int port,
  Duration timeout,
);

class _SocketConnection implements PrinterConnection {
  _SocketConnection(this._socket);
  final Socket _socket;
  @override
  void add(List<int> bytes) => _socket.add(bytes);
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future<void> close() async {
    await _socket.close();
    _socket.destroy();
  }
}

Future<PrinterConnection> socketConnector(
  String host,
  int port,
  Duration timeout,
) async =>
    _SocketConnection(await Socket.connect(host, port, timeout: timeout));

/// Direct ESC/POS printing to a LAN thermal printer (raw TCP, usually port
/// 9100). The receipt is rasterised, so text and currency symbols print the
/// same on any printer.
class NetworkEscPosPrinter {
  NetworkEscPosPrinter({
    required this.settings,
    PrinterConnector? connector,
    this.rasterizer = const ReceiptRasterizer(),
    this.encoder = const EscPosEncoder(),
    this.timeout = const Duration(seconds: 5),
  }) : _connector = connector ?? socketConnector;

  final PrinterSettings settings;
  final PrinterConnector _connector;
  final ReceiptRasterizer rasterizer;
  final EscPosEncoder encoder;
  final Duration timeout;

  /// The bytes that would be sent for [receipt] (also used by tests).
  Future<Uint8List> buildJob(ReceiptData receipt) async {
    final dots = settings.paper.dots;
    final lines = receipt.toLines(columns: ReceiptRasterizer.columnsFor(dots));
    final bitmap = await rasterizer.render(lines, widthDots: dots);
    return encoder.receiptJob(bitmap);
  }

  Future<void> print(ReceiptData receipt) async {
    if (!settings.thermalConfigured) {
      throw const PrintException('No thermal printer is configured.');
    }
    final job = await buildJob(receipt);
    final where = '${settings.host}:${settings.port}';
    PrinterConnection? conn;
    try {
      conn = await _connector(settings.host.trim(), settings.port, timeout);
      conn.add(job);
      await conn.flush();
      await conn.close();
    } on TimeoutException {
      throw PrintException('The printer at $where did not respond.');
    } on SocketException {
      throw PrintException('Cannot reach the printer at $where.');
    } on IOException {
      throw PrintException('Printing to $where failed.');
    }
  }
}
