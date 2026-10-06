import '../data/printer_driver.dart';
import '../data/printer_settings.dart';
import 'printer_adapter.dart';

/// Phase 11B — the Phase 11A [PrinterAdapter] for the EXISTING LAN printer.
/// It does not open sockets itself: the bytes of a [PrintJob] go, unchanged,
/// through [NetworkEscPosPrinter.sendBytes] (the app's one raw-TCP path,
/// host / port from the existing [PrinterSettings], same timeout and error
/// messages). Receipt layout is done before this is called.
///
/// Failures are returned, never thrown:
///   * no printer address configured / printer unreachable (refused, timed
///     out, unknown host) → [PrintStatus.printerUnavailable];
///   * connected, but the write / flush failed → [PrintStatus.connectionFailure];
///   * anything unexpected → [PrintStatus.connectionFailure] (no raw error
///     text reaches the UI).
class NetworkPrinterAdapter implements PrinterAdapter {
  NetworkPrinterAdapter({
    required this.settings,
    PrinterConnector? connector,
    Duration timeout = const Duration(seconds: 5),
  }) : _printer = NetworkEscPosPrinter(
         settings: settings,
         connector: connector,
         timeout: timeout,
       );

  final PrinterSettings settings;
  final NetworkEscPosPrinter _printer;

  /// The Phase 11A printer configuration for this LAN printer (its paper
  /// width comes from the same settings).
  static ReceiptPrinterConfig configFor(
    PrinterSettings settings, {
    bool cutEnabled = true,
    int? columnsOverride,
  }) => ReceiptPrinterConfig(
    paper: settings.paper,
    connectionType: PrinterConnectionType.network,
    printerName: '${settings.host.trim()}:${settings.port}',
    cutEnabled: cutEnabled,
    columnsOverride: columnsOverride,
  );

  @override
  PrinterConnectionType get type => PrinterConnectionType.network;

  /// Configured = usable. No connection is opened just to check (a raw
  /// ESC/POS port has no status handshake); reachability is reported by
  /// [send].
  @override
  Future<bool> isAvailable() async => settings.thermalConfigured;

  @override
  Future<PrintResult> send(PrintJob job) async {
    if (!settings.thermalConfigured) {
      return const PrintResult(
        PrintStatus.printerUnavailable,
        message: 'No network receipt printer is configured.',
      );
    }
    try {
      await _printer.sendBytes(job.bytes);
      return PrintResult.success(job);
    } on PrintException catch (e) {
      return PrintResult(
        e.connected
            ? PrintStatus.connectionFailure
            : PrintStatus.printerUnavailable,
        message: e.message,
      );
    } catch (_) {
      return const PrintResult(
        PrintStatus.connectionFailure,
        message: 'The receipt could not be sent to the network printer.',
      );
    }
  }
}
