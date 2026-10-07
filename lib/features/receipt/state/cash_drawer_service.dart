import 'dart:collection';

import '../data/printer_settings.dart';
import '../printing/escpos_receipt_service.dart';
import '../printing/network_printer_adapter.dart';
import '../printing/printer_adapter.dart';
import 'print_service.dart';

/// Phase 14A — what happened when the cash drawer was asked to open.
enum DrawerOpenStatus {
  opened,

  /// No printer with a cash drawer is set up (nothing was sent).
  notConfigured,

  /// The drawer was already opened for this sale (nothing sent again).
  alreadyOpened,

  /// The printer could not be reached / the pulse could not be sent.
  failed,
}

class DrawerOpenResult {
  const DrawerOpenResult(this.status, {this.message});
  final DrawerOpenStatus status;

  /// Cashier-facing text (never printer addresses or raw errors).
  final String? message;

  bool get opened => status == DrawerOpenStatus.opened;
}

/// Phase 14A — opens the cash drawer connected to the receipt printer's
/// drawer port, through the EXISTING ESC/POS layer ([EscPosReceiptService],
/// [PrinterAdapter], printer settings). It never creates or changes a sale,
/// payment, stock or shift, and never claims success it did not get.
///
/// [openForCashSale] opens at most ONCE per completed sale (payment retries,
/// idempotent completion replays and screen rebuilds never pulse again).
class CashDrawerService {
  CashDrawerService({
    required this.settings,
    EscPosAdapterFactory? adapterFactory,
  }) : _adapterFactory =
           adapterFactory ?? ((s) => NetworkPrinterAdapter(settings: s));

  final PrinterSettingsStore settings;
  final EscPosAdapterFactory _adapterFactory;

  /// Sales the drawer was already opened for (bounded; oldest dropped).
  final LinkedHashSet<String> _openedFor = LinkedHashSet<String>();
  static const _remember = 500;

  static const notConfiguredMessage =
      'No cash drawer is set up. Connect it to the receipt printer and turn on '
      '"Cash drawer connected" in printer setup.';
  static const failedMessage =
      'The cash drawer could not be opened. Check the receipt printer, or open '
      'the drawer with its key.';

  /// Whether a drawer is configured (so a caller can skip asking for one).
  Future<bool> isConfigured() async {
    try {
      return (await settings.load()).drawerConfigured;
    } catch (_) {
      return false;
    }
  }

  /// After a COMPLETED cash sale identified by [saleKey] (`sale:42`,
  /// `local:UUID`). Never opens twice for the same sale.
  Future<DrawerOpenResult> openForCashSale(String saleKey) async {
    if (_openedFor.contains(saleKey)) {
      return const DrawerOpenResult(DrawerOpenStatus.alreadyOpened);
    }
    // Claimed before the await: a second call for the same sale while this
    // one is still sending does nothing.
    _openedFor.add(saleKey);
    if (_openedFor.length > _remember) _openedFor.remove(_openedFor.first);
    return _open();
  }

  /// A manual opening ("no sale") — the caller has already recorded it.
  Future<DrawerOpenResult> open() => _open();

  Future<DrawerOpenResult> _open() async {
    final PrinterSettings cfg;
    try {
      cfg = await settings.load();
    } catch (_) {
      return const DrawerOpenResult(
        DrawerOpenStatus.failed,
        message: failedMessage,
      );
    }
    if (!cfg.drawerConfigured) {
      return const DrawerOpenResult(
        DrawerOpenStatus.notConfigured,
        message: notConfiguredMessage,
      );
    }
    final PrintResult result;
    try {
      result = await EscPosReceiptService(
        adapter: _adapterFactory(cfg),
        config: NetworkPrinterAdapter.configFor(cfg),
      ).openDrawer();
    } catch (_) {
      return const DrawerOpenResult(
        DrawerOpenStatus.failed,
        message: failedMessage,
      );
    }
    if (result.ok) return const DrawerOpenResult(DrawerOpenStatus.opened);
    return DrawerOpenResult(
      result.status == PrintStatus.unsupportedCapability
          ? DrawerOpenStatus.notConfigured
          : DrawerOpenStatus.failed,
      message: result.status == PrintStatus.unsupportedCapability
          ? notConfiguredMessage
          : failedMessage,
    );
  }
}
