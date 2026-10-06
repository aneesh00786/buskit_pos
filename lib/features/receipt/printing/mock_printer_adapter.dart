import 'printer_adapter.dart';

/// Phase 11A — an in-memory printer: accepts jobs, keeps them for tests and
/// previews, and can simulate the failures a real connection reports. Touches
/// no hardware.
class MockPrinterAdapter implements PrinterAdapter {
  MockPrinterAdapter({this.available = true, this.failWith});

  /// False = behaves like a printer that is off / not paired.
  bool available;

  /// When set, [send] fails with this status (e.g. connectionFailure).
  PrintStatus? failWith;

  final List<PrintJob> jobs = [];

  @override
  PrinterConnectionType get type => PrinterConnectionType.mock;

  PrintJob? get lastJob => jobs.isEmpty ? null : jobs.last;
  bool get cutRequested => lastJob?.cutRequested ?? false;
  bool get drawerRequested => lastJob?.drawerRequested ?? false;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<PrintResult> send(PrintJob job) async {
    if (!available) {
      return const PrintResult(
        PrintStatus.printerUnavailable,
        message: 'The receipt printer is not available.',
      );
    }
    final fail = failWith;
    if (fail != null && fail != PrintStatus.success) {
      return PrintResult(fail, message: 'The receipt could not be printed.');
    }
    jobs.add(job);
    return PrintResult.success(job);
  }
}
