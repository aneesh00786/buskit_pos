import 'models/offline_context.dart';

/// Which payments may be taken while the POS cannot reach the server.
///
/// Offline the POS must never pretend an online payment succeeded:
///  - cash: always allowed (nothing to confirm)
///  - manual card / other (provider NONE, recorded from a standalone
///    terminal or slip): only if explicitly approved in [OfflineSettings]
///  - any provider payment (Pine Labs terminal, Razorpay UPI QR, or any future
///    provider that needs server/provider confirmation): never
class OfflinePaymentPolicy {
  const OfflinePaymentPolicy([this.settings = const OfflineSettings()]);
  final OfflineSettings settings;

  static const onlineRequiredMessage =
      'Internet connection is required for this payment method.';

  /// Null when allowed offline, otherwise the message to show.
  String? check({required String method, String provider = 'NONE'}) {
    if (provider.toUpperCase() != 'NONE') return onlineRequiredMessage;
    final m = method.toLowerCase();
    if (m == 'cash') return null;
    if ((m == 'card' || m == 'other') &&
        settings.offlineManualTenders.contains(m)) {
      return null;
    }
    return onlineRequiredMessage;
  }

  bool allows({required String method, String provider = 'NONE'}) =>
      check(method: method, provider: provider) == null;
}
