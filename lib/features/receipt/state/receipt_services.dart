import '../data/printer_settings.dart';
import '../data/receipt_delivery.dart';
import 'cash_drawer_service.dart';
import 'print_service.dart';

/// The receipt-related services the success screen needs, provided once by the
/// app (and replaced by fakes in tests).
class ReceiptServices {
  const ReceiptServices({
    required this.print,
    required this.delivery,
    required this.settings,
    this.drawer,
  });
  final PrintService print;
  final ReceiptDelivery delivery;
  final PrinterSettingsStore settings;

  /// Phase 14A: the cash drawer behind the receipt printer (null in tests
  /// that do not need it).
  final CashDrawerService? drawer;
}
