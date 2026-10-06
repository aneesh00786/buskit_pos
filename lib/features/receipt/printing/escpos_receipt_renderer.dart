import '../models/receipt.dart';
import '../models/receipt_formatter.dart';
import 'escpos_commands.dart';
import 'printer_adapter.dart';

/// Phase 11A — lays an existing [ReceiptData] out as ESC/POS text commands
/// for the configured paper width. The text layout is the app's one receipt
/// layout (`ReceiptText.toLines`, shared with the PDF / raster receipts);
/// this only adds printer styling: bold title (double height when the
/// printer supports it), bold TOTAL / CHANGE DUE, feed, and an optional cut.
/// It knows nothing about how the printer is connected.
class EscPosReceiptRenderer {
  const EscPosReceiptRenderer();

  static const int feedBeforeCut = 4;

  PrintJob render(
    ReceiptData receipt,
    ReceiptPrinterConfig config, {
    bool openDrawer = false,
  }) {
    final columns = config.columns;
    final caps = config.capabilities;
    final lines = receipt.toLines(
      columns: columns,
      showBarcodes: config.printBarcodes,
    );
    final cmd = EscPosCommands()
      ..initialize()
      ..align(EscPosAlign.left);
    for (var i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (i == 0) {
        cmd.bold(true);
        if (caps.doubleSize) cmd.size(height: 2);
        cmd.line(l);
        if (caps.doubleSize) cmd.size();
        cmd.bold(false);
      } else if (l.startsWith('TOTAL') || l.startsWith('CHANGE DUE')) {
        cmd
          ..bold(true)
          ..line(l)
          ..bold(false);
      } else {
        cmd.line(l);
      }
    }
    cmd.feed(feedBeforeCut);
    final cut = config.cutEnabled && caps.cutter;
    if (cut) cmd.cut();
    final drawer = openDrawer && caps.cashDrawer;
    if (drawer) cmd.openCashDrawer();
    return PrintJob(
      bytes: cmd.bytes(),
      reference: receipt.orderNumber,
      paper: config.paper,
      columns: columns,
      lines: lines,
      commands: cmd.log,
      cutRequested: cut,
      drawerRequested: drawer,
    );
  }
}
