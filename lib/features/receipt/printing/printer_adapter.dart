import 'dart:typed_data';

import '../data/printer_settings.dart';
import 'escpos_commands.dart';

/// Phase 11A — how a receipt printer is reached. Only [mock] has an adapter
/// in this phase; the others are placeholders for later phases (the existing
/// LAN raster printer, `NetworkEscPosPrinter`, is unchanged and separate).
enum PrinterConnectionType { mock, network, usb, bluetooth }

/// Text columns per line. Printers differ (e.g. some 80 mm heads are 512
/// dots, not 576), so the default per paper width can be overridden per
/// printer; this is the only place the number is decided.
class ReceiptColumns {
  const ReceiptColumns._();

  /// ESC/POS Font A is 12 dots wide: 58 mm (384 dots) = 32, 80 mm (576 dots)
  /// = 48 columns.
  static const int fontADotWidth = 12;

  static int defaultFor(PaperWidth paper) => paper.dots ~/ fontADotWidth;

  static int resolve(PaperWidth paper, {int? override}) =>
      (override != null && override >= 16 && override <= 96)
      ? override
      : defaultFor(paper);
}

/// The minimum printer configuration (in memory; no database, no
/// persistence in this phase).
class ReceiptPrinterConfig {
  const ReceiptPrinterConfig({
    this.paper = PaperWidth.mm80,
    this.connectionType = PrinterConnectionType.mock,
    this.printerName = 'Receipt printer',
    this.cutEnabled = true,
    this.columnsOverride,
    this.printBarcodes = true,
    this.capabilities = const EscPosCapabilities(),
  });

  /// Reuses the app's existing paper widths (58 / 80 mm).
  final PaperWidth paper;
  final PrinterConnectionType connectionType;
  final String printerName;

  /// Cut after the receipt (only if the printer has a cutter).
  final bool cutEnabled;

  /// Characters per line when this printer differs from the default.
  final int? columnsOverride;
  final bool printBarcodes;
  final EscPosCapabilities capabilities;

  int get columns => ReceiptColumns.resolve(paper, override: columnsOverride);

  ReceiptPrinterConfig copyWith({
    PaperWidth? paper,
    bool? cutEnabled,
    int? columnsOverride,
    EscPosCapabilities? capabilities,
  }) => ReceiptPrinterConfig(
    paper: paper ?? this.paper,
    connectionType: connectionType,
    printerName: printerName,
    cutEnabled: cutEnabled ?? this.cutEnabled,
    columnsOverride: columnsOverride ?? this.columnsOverride,
    printBarcodes: printBarcodes,
    capabilities: capabilities ?? this.capabilities,
  );
}

/// One rendered receipt, ready for any connection.
class PrintJob {
  const PrintJob({
    required this.bytes,
    required this.reference,
    required this.paper,
    required this.columns,
    required this.lines,
    required this.commands,
    this.cutRequested = false,
    this.drawerRequested = false,
  });

  /// The ESC/POS bytes to send.
  final Uint8List bytes;

  /// The sale number the receipt is for.
  final String reference;
  final PaperWidth paper;
  final int columns;

  /// The text lines as laid out (for previews / tests).
  final List<String> lines;

  /// The commands issued (see [EscPosCommands.log]).
  final List<String> commands;
  final bool cutRequested;
  final bool drawerRequested;
}

enum PrintStatus {
  success,
  printerUnavailable,
  unsupportedCapability,
  invalidReceipt,
  connectionFailure,
}

/// The outcome of a print request — never thrown, always returned.
class PrintResult {
  const PrintResult(this.status, {this.message, this.job});
  const PrintResult.success(PrintJob this.job)
    : status = PrintStatus.success,
      message = null;

  final PrintStatus status;

  /// A cashier-facing explanation (never raw exception text).
  final String? message;
  final PrintJob? job;

  bool get ok => status == PrintStatus.success;
}

/// A connection to a receipt printer. Adapters only move bytes: receipt
/// layout and ESC/POS commands are built before they are called.
abstract class PrinterAdapter {
  PrinterConnectionType get type;

  /// Whether the printer can be used right now (e.g. connected / paired).
  Future<bool> isAvailable();

  /// Sends the job; never throws (failures are a [PrintResult]).
  Future<PrintResult> send(PrintJob job);
}
