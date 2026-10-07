import '../../../core/storage/token_store.dart';
import 'receipt_rasterizer.dart';

enum PaperWidth {
  mm58(ReceiptRasterizer.width58mm, '58 mm'),
  mm80(ReceiptRasterizer.width80mm, '80 mm');

  const PaperWidth(this.dots, this.label);
  final int dots;
  final String label;
}

/// Phase 11C — how receipts are sent to the LAN thermal printer.
enum ThermalMode {
  /// The receipt drawn as an image (raster) — prints the same on any printer.
  /// The default (unchanged behaviour).
  image('Image'),

  /// ESC/POS text commands (Phase 11A layer) — smaller and faster, ASCII text.
  escPos('ESC/POS text');

  const ThermalMode(this.label);
  final String label;
}

/// Where thermal receipts go. No host = not configured (system print is used).
class PrinterSettings {
  const PrinterSettings({
    this.host = '',
    this.port = defaultPort,
    this.paper = PaperWidth.mm80,
    this.mode = ThermalMode.image,
    this.cashDrawer = false,
    this.autoPrint = false,
  });

  static const int defaultPort = 9100; // raw ESC/POS over LAN
  final String host;
  final int port;
  final PaperWidth paper;
  final ThermalMode mode;

  /// Phase 14A: a cash drawer is connected to this printer's drawer port
  /// (set by the store in printer setup; off by default).
  final bool cashDrawer;

  /// Phase 14B: print the receipt automatically after a completed sale
  /// (off by default — existing installations keep printing on tap).
  final bool autoPrint;

  bool get thermalConfigured => host.trim().isNotEmpty;

  /// The drawer can be opened through the configured LAN printer.
  bool get drawerConfigured => thermalConfigured && cashDrawer;

  PrinterSettings copyWith({
    String? host,
    int? port,
    PaperWidth? paper,
    ThermalMode? mode,
    bool? cashDrawer,
    bool? autoPrint,
  }) => PrinterSettings(
    host: host ?? this.host,
    port: port ?? this.port,
    paper: paper ?? this.paper,
    mode: mode ?? this.mode,
    cashDrawer: cashDrawer ?? this.cashDrawer,
    autoPrint: autoPrint ?? this.autoPrint,
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
  static const _kMode = 'printer_mode';
  static const _kCashDrawer = 'printer_cash_drawer';
  static const _kAutoPrint = 'printer_auto_print';

  Future<PrinterSettings> load() async {
    final host = await _store.read(_kHost) ?? '';
    final port =
        int.tryParse(await _store.read(_kPort) ?? '') ??
        PrinterSettings.defaultPort;
    final paperName = await _store.read(_kPaper);
    final paper =
        PaperWidth.values.where((p) => p.name == paperName).firstOrNull ??
        PaperWidth.mm80;
    final modeName = await _store.read(_kMode);
    final mode =
        ThermalMode.values.where((m) => m.name == modeName).firstOrNull ??
        ThermalMode.image;
    final cashDrawer = await _store.read(_kCashDrawer) == 'true';
    final autoPrint = await _store.read(_kAutoPrint) == 'true';
    return PrinterSettings(
      host: host,
      port: port,
      paper: paper,
      mode: mode,
      cashDrawer: cashDrawer,
      autoPrint: autoPrint,
    );
  }

  Future<void> save(PrinterSettings s) async {
    if (s.host.trim().isEmpty) {
      await _store.delete(_kHost);
    } else {
      await _store.write(_kHost, s.host.trim());
    }
    await _store.write(_kPort, '${s.port}');
    await _store.write(_kPaper, s.paper.name);
    await _store.write(_kMode, s.mode.name);
    await _store.write(_kCashDrawer, s.cashDrawer ? 'true' : 'false');
    await _store.write(_kAutoPrint, s.autoPrint ? 'true' : 'false');
  }
}
