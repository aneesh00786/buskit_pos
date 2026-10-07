import '../data/printer_driver.dart';
import '../data/printer_settings.dart';
import '../data/receipt_pdf.dart';
import '../models/receipt.dart';
import '../printing/escpos_receipt_service.dart';
import '../printing/network_printer_adapter.dart';
import '../printing/printer_adapter.dart';

enum PrintChannel { thermal, system }

class PrintOutcome {
  const PrintOutcome({
    required this.channel,
    this.fellBack = false,
    this.thermalError,
    this.cancelled = false,
    this.thermalStatus,
  });

  /// The channel that produced the print (or was attempted last).
  final PrintChannel channel;

  /// True when the thermal printer failed and the system print engine was used.
  final bool fellBack;
  final String? thermalError;

  /// The cashier dismissed the system print dialog.
  final bool cancelled;

  /// Phase 11C: the ESC/POS printer's result when [ThermalMode.escPos] was
  /// used (null for the image path).
  final PrintStatus? thermalStatus;
}

typedef ThermalPrinterFactory = NetworkEscPosPrinter Function(
  PrinterSettings settings,
);

/// Phase 11C: the [PrinterAdapter] for [ThermalMode.escPos] (tests inject a
/// mock; the app uses the LAN [NetworkPrinterAdapter]).
typedef EscPosAdapterFactory = PrinterAdapter Function(
  PrinterSettings settings,
);

/// Prints a receipt: to the configured LAN thermal printer if there is one,
/// otherwise — or if that printer cannot be reached — through the device's
/// native print engine (PDF / OS print queue).
///
/// Phase 11C: the LAN printer is used as an image (raster, the default) or,
/// when [ThermalMode.escPos] is selected in the printer settings, as ESC/POS
/// text through the Phase 11A/11B layer (same printer, same connection
/// code). Either way a failure falls back to the system print engine.
/// Printing never opens the cash drawer.
class PrintService {
  PrintService({
    required this.settings,
    this.pdfPrinter = const SystemPdfPrinter(),
    ThermalPrinterFactory? thermalFactory,
    EscPosAdapterFactory? escPosAdapterFactory,
    this.pdfBuilder = buildReceiptPdf,
  }) : _thermalFactory =
           thermalFactory ?? ((s) => NetworkEscPosPrinter(settings: s)),
       _escPosAdapterFactory =
           escPosAdapterFactory ?? ((s) => NetworkPrinterAdapter(settings: s));

  final PrinterSettingsStore settings;
  final PdfPrinter pdfPrinter;
  final ThermalPrinterFactory _thermalFactory;
  final EscPosAdapterFactory _escPosAdapterFactory;
  final Future<dynamic> Function(ReceiptData receipt) pdfBuilder;

  /// Phase 14B: sales whose receipt was already AUTO-printed (bounded). A
  /// sale is auto-printed at most once, whatever rebuilds, retries or
  /// repeated completion callbacks happen; manual printing is unaffected.
  final Set<String> _autoPrinted = <String>{};

  /// True the FIRST time [saleKey] is claimed for an automatic print.
  bool claimAutoPrint(String saleKey) {
    if (_autoPrinted.contains(saleKey)) return false;
    if (_autoPrinted.length >= 500) _autoPrinted.remove(_autoPrinted.first);
    _autoPrinted.add(saleKey);
    return true;
  }

  /// The adapter used for [ThermalMode.escPos] with [settings].
  PrinterAdapter escPosAdapterFor(PrinterSettings settings) =>
      _escPosAdapterFactory(settings);

  Future<PrintOutcome> print(ReceiptData receipt) async {
    final cfg = await settings.load();
    String? thermalError;
    PrintStatus? thermalStatus;
    if (cfg.thermalConfigured && cfg.mode == ThermalMode.escPos) {
      final result = await EscPosReceiptService(
        adapter: escPosAdapterFor(cfg),
        config: NetworkPrinterAdapter.configFor(cfg),
      ).print(receipt);
      if (result.ok) {
        return PrintOutcome(
          channel: PrintChannel.thermal,
          thermalStatus: result.status,
        );
      }
      thermalStatus = result.status;
      thermalError =
          result.message ?? 'The thermal printer could not print this receipt.';
    } else if (cfg.thermalConfigured) {
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
      thermalStatus: thermalStatus,
    );
  }

  Future<PrintOutcome> _system(
    ReceiptData receipt, {
    required bool fellBack,
    String? thermalError,
    PrintStatus? thermalStatus,
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
        thermalStatus: thermalStatus,
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
