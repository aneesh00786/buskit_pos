import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../models/receipt.dart';
import '../models/receipt_formatter.dart';
import 'escpos_encoder.dart';
import 'printer_settings.dart';
import 'receipt_rasterizer.dart';

class PrintException implements Exception {
  const PrintException(this.message, {this.connected = false});
  final String message;

  /// Phase 11B: true when the connection was made and the write / flush /
  /// close failed (false = the printer could not be reached at all).
  final bool connected;
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
    await sendBytes(await buildJob(receipt));
  }

  /// Sends ready-made ESC/POS [bytes] to the configured printer (raw TCP),
  /// unchanged. Used by [print] for the raster receipt and, since Phase 11B,
  /// by `NetworkPrinterAdapter` for the text-mode ESC/POS receipt — the one
  /// LAN connection path.
  Future<void> sendBytes(List<int> bytes) async {
    if (!settings.thermalConfigured) {
      throw const PrintException('No thermal printer is configured.');
    }
    final where = '${settings.host}:${settings.port}';
    PrinterConnection? conn;
    try {
      conn = await _connector(settings.host.trim(), settings.port, timeout);
      conn.add(bytes);
      await conn.flush();
      await conn.close();
    } on TimeoutException {
      throw PrintException(
        'The printer at $where did not respond.',
        connected: conn != null,
      );
    } on SocketException {
      throw PrintException(
        'Cannot reach the printer at $where.',
        connected: conn != null,
      );
    } on IOException {
      throw PrintException(
        'Printing to $where failed.',
        connected: conn != null,
      );
    }
  }
}
