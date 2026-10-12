import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';

/// Phase 6ZA — operations that must not be cut off by quitting the desktop app
/// (Cmd+Q / closing the last window): a provider payment being taken on the
/// card terminal or by UPI QR. Cart operations (including checkout) are
/// tracked by the cart itself (CartController.isMutating).
class InFlightOperations {
  InFlightOperations._();

  static final ValueNotifier<int> _count = ValueNotifier<int>(0);

  /// True while at least one tracked operation is running.
  static bool get busy => _count.value > 0;

  /// Runs [operation], counted as in flight until it finishes (or fails).
  static Future<T> track<T>(Future<T> Function() operation) async {
    _count.value++;
    try {
      return await operation();
    } finally {
      _count.value--;
    }
  }
}

/// The cashier-facing reason a quit request was refused.
const exitBlockedMessage =
    'A sale or payment is still in progress. Finish or cancel it before closing the POS.';

/// Phase 6ZA — the answer to a desktop quit request. Nothing in flight: the app
/// may exit (unpaid offline carts are already saved as drafts and restored at
/// the next start; queued sales are on disk). Otherwise the quit is refused,
/// so a checkout or payment is never silently abandoned mid-way.
AppExitResponse decideAppExit({required bool cartBusy, bool? paymentBusy}) {
  final payment = paymentBusy ?? InFlightOperations.busy;
  return (cartBusy || payment) ? AppExitResponse.cancel : AppExitResponse.exit;
}
