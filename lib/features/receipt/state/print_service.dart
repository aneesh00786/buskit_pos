import '../data/printer_driver.dart';
import '../data/printer_settings.dart';
import '../data/receipt_pdf.dart';
import '../models/receipt.dart';

enum PrintChannel { thermal, system }

class PrintOutcome {
  const PrintOutcome({
    required this.channel,
    this.fellBack = false,
    this.thermalError,
    this.cancelled = false,
  });

  /// The channel that produced the print (or was attempted last).
  final PrintChannel channel;

  /// True when the thermal printer failed and the system print engine was used.
  final bool fellBack;
  final String? thermalError;

  /// The cashier dismissed the system print dialog.
  final bool cancelled;
}

typedef ThermalPrinterFactory = NetworkEscPosPrinter Function(
  PrinterSettings settings,
);

/// Prints a receipt: to the configured LAN thermal printer if there is one,
/// otherwise — or if that printer cannot be reached — through the device's
/// native print engine (PDF / OS print queue).
class PrintService {
  PrintService({
    required this.settings,
    this.pdfPrinter = const SystemPdfPrinter(),
    ThermalPrinterFactory? thermalFactory,
    this.pdfBuilder = buildReceiptPdf,
  }) : _thermalFactory =
           thermalFactory ?? ((s) => NetworkEscPosPrinter(settings: s));

  final PrinterSettingsStore settings;
  final PdfPrinter pdfPrinter;
  final ThermalPrinterFactory _thermalFactory;
  final Future<dynamic> Function(ReceiptData receipt) pdfBuilder;

  Future<PrintOutcome> print(ReceiptData receipt) async {
    final cfg = await settings.load();
    String? thermalError;
    if (cfg.thermalConfigured) {
      try {
        await _thermalFactory(cfg).print(receipt);
        return const PrintOutcome(channel: PrintChannel.thermal);
      } on PrintException catch (e) {
        thermalError = e.message;
      } catch (_) {
        thermalError = 'The thermal printer could not print this receipt.';
      }
    }
    return _system(
      receipt,
      fellBack: thermalError != null,
      thermalError: thermalError,
    );
  }

  Future<PrintOutcome> _system(
    ReceiptData receipt, {
    required bool fellBack,
    String? thermalError,
  }) async {
    try {
      final bytes = await pdfBuilder(receipt);
      final sent = await pdfPrinter.printPdf(
        bytes,
        name: 'Receipt ${receipt.orderNumber}',
      );
      return PrintOutcome(
        channel: PrintChannel.system,
        fellBack: fellBack,
        thermalError: thermalError,
        cancelled: !sent,
      );
    } on PrintException {
      rethrow;
    } catch (_) {
      throw const PrintException(
        'This device could not open its print dialog.',
      );
    }
  }
}
