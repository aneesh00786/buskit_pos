import '../models/receipt.dart';
import 'escpos_commands.dart';
import 'escpos_receipt_renderer.dart';
import 'printer_adapter.dart';

/// Phase 11A — the receipt printing service for ESC/POS printers: takes the
/// existing receipt of a COMPLETED sale ([ReceiptData], built by
/// `ReceiptFormatter` from the server's completed sale), lays it out for the
/// configured paper and hands the bytes to a [PrinterAdapter].
///
/// Printing is output only: this never creates or changes a sale, payment,
/// stock, shift or refund, and never calls a payment provider. Failures are
/// returned as a [PrintResult], never thrown. The cash-drawer pulse is only
/// added when explicitly requested AND the printer declares a drawer port.
///
/// (Named to sit beside the existing `PrintService` — LAN raster / system
/// PDF printing — which is unchanged.)
class EscPosReceiptService {
  EscPosReceiptService({
    required this.adapter,
    this.config = const ReceiptPrinterConfig(),
    this.renderer = const EscPosReceiptRenderer(),
  });

  final PrinterAdapter adapter;
  final ReceiptPrinterConfig config;
  final EscPosReceiptRenderer renderer;

  /// Why [receipt] cannot be printed, or null.
  static String? validate(ReceiptData receipt) {
    if (receipt.orderNumber.trim().isEmpty) {
      return 'The receipt has no sale number.';
    }
    if (receipt.lines.isEmpty) return 'The receipt has no items.';
    if (receipt.total.trim().isEmpty || receipt.total == '—') {
      return 'The receipt has no total.';
    }
    return null;
  }

  /// The job that would be sent (previews / tests). Pure.
  PrintJob render(ReceiptData receipt, {bool openDrawer = false}) =>
      renderer.render(receipt, config, openDrawer: openDrawer);

  /// Phase 14A: a job that ONLY pulses the cash-drawer port (no receipt, no
  /// paper feed or cut). Pure.
  PrintJob renderDrawerOpen() {
    final cmd = EscPosCommands().initialize().openCashDrawer();
    return PrintJob(
      bytes: cmd.bytes(),
      reference: 'drawer',
      paper: config.paper,
      columns: config.columns,
      lines: const [],
      commands: cmd.log,
      drawerRequested: true,
    );
  }

  /// Phase 14A: opens the cash drawer through the printer, without printing.
  /// Refused (never pretended) when the printer declares no drawer port;
  /// failures are returned, never thrown.
  Future<PrintResult> openDrawer() async {
    if (!config.capabilities.cashDrawer) {
      return const PrintResult(
        PrintStatus.unsupportedCapability,
        message: 'This printer has no cash drawer port configured.',
      );
    }
    try {
      if (!await adapter.isAvailable()) {
        return const PrintResult(
          PrintStatus.printerUnavailable,
          message: 'The receipt printer is not available.',
        );
      }
      return await adapter.send(renderDrawerOpen());
    } catch (_) {
      return const PrintResult(
        PrintStatus.connectionFailure,
        message: 'The cash drawer could not be reached through the printer.',
      );
    }
  }

  Future<PrintResult> print(
    ReceiptData receipt, {
    bool openDrawer = false,
  }) async {
    final invalid = validate(receipt);
    if (invalid != null) {
      return PrintResult(PrintStatus.invalidReceipt, message: invalid);
    }
    if (openDrawer && !config.capabilities.cashDrawer) {
      return const PrintResult(
        PrintStatus.unsupportedCapability,
        message: 'This printer has no cash drawer port configured.',
      );
    }
    try {
      if (!await adapter.isAvailable()) {
        return const PrintResult(
          PrintStatus.printerUnavailable,
          message: 'The receipt printer is not available.',
        );
      }
      return await adapter.send(render(receipt, openDrawer: openDrawer));
    } catch (_) {
      return const PrintResult(
        PrintStatus.connectionFailure,
        message: 'The receipt could not be sent to the printer.',
      );
    }
  }
}
