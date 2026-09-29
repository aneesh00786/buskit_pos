import '../../../core/storage/token_store.dart';
import 'receipt_rasterizer.dart';

enum PaperWidth {
  mm58(ReceiptRasterizer.width58mm, '58 mm'),
  mm80(ReceiptRasterizer.width80mm, '80 mm');

  const PaperWidth(this.dots, this.label);
  final int dots;
  final String label;
}

/// Where thermal receipts go. No host = not configured (system print is used).
class PrinterSettings {
  const PrinterSettings({
    this.host = '',
    this.port = defaultPort,
    this.paper = PaperWidth.mm80,
  });

  static const int defaultPort = 9100; // raw ESC/POS over LAN
  final String host;
  final int port;
  final PaperWidth paper;

  bool get thermalConfigured => host.trim().isNotEmpty;

  PrinterSettings copyWith({String? host, int? port, PaperWidth? paper}) =>
      PrinterSettings(
        host: host ?? this.host,
        port: port ?? this.port,
        paper: paper ?? this.paper,
      );

  /// Null when valid, else the problem.
  static String? validate(String host, String portText) {
    final h = host.trim();
    if (h.isEmpty) return null; // empty = use system print only
    if (h.length > 253 || RegExp(r'\s').hasMatch(h)) {
      return 'Enter a valid printer address (IP or host name).';
    }
    final p = int.tryParse(portText.trim());
    if (p == null || p < 1 || p > 65535) {
      return 'Port must be a number from 1 to 65535.';
    }
    return null;
  }
}

/// Persists [PrinterSettings] in the app's secure key/value store (they are
/// device configuration, not credentials).
class PrinterSettingsStore {
  PrinterSettingsStore(this._store);
  final TokenStore _store;

  static const _kHost = 'printer_host';
  static const _kPort = 'printer_port';
  static const _kPaper = 'printer_paper';

  Future<PrinterSettings> load() async {
    final host = await _store.read(_kHost) ?? '';
    final port =
        int.tryParse(await _store.read(_kPort) ?? '') ??
        PrinterSettings.defaultPort;
    final paperName = await _store.read(_kPaper);
    final paper =
        PaperWidth.values.where((p) => p.name == paperName).firstOrNull ??
        PaperWidth.mm80;
    return PrinterSettings(host: host, port: port, paper: paper);
  }

  Future<void> save(PrinterSettings s) async {
    if (s.host.trim().isEmpty) {
      await _store.delete(_kHost);
    } else {
      await _store.write(_kHost, s.host.trim());
    }
    await _store.write(_kPort, '${s.port}');
    await _store.write(_kPaper, s.paper.name);
  }
}
