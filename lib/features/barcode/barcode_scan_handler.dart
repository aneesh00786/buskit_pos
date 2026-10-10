import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../cart/state/cart_controller.dart';
import '../products/data/product_service.dart';

enum ScanOutcome { added, notFound, invalid, busy, error }

class ScanResult {
  const ScanResult(this.outcome, this.message, {this.code});
  final ScanOutcome outcome;

  /// Cashier-facing text for a snackbar.
  final String message;
  final String? code;

  bool get added => outcome == ScanOutcome.added;
}

/// Turns a scanned code (from a hardware scanner or the camera) into a cart
/// line: POS barcode lookup, then add one unit of the matched variation.
/// Scans are processed one at a time, in order, so a quick run of scans never
/// races the cart's single-mutation lock.
///
/// Phase 14E-A: a scan that arrives while the cart is busy with ANOTHER change
/// (a quantity edit, a removal, …) waits for the cart instead of being lost.
/// At most [maxQueued] scans wait at once; beyond that a new scan is refused
/// (with a message) and the scans already waiting are kept.
class BarcodeScanHandler {
  BarcodeScanHandler({
    required this.products,
    required this.cart,
    this.cartWait = const Duration(seconds: 15),
  });
  final ProductService products;
  final CartController cart;

  /// How long one scan waits for a busy cart before it gives up.
  final Duration cartWait;

  static const maxLength = 50;

  /// Scans waiting or in progress at once (a scanner burst is far smaller).
  static const maxQueued = 20;

  static const queueFullMessage =
      'Too many scans are waiting. Wait a moment and scan again.';

  Future<void> _tail = Future<void>.value();
  int _pending = 0;

  /// Scans queued or being processed right now.
  int get pending => _pending;

  /// Trims and validates a raw code; null when unusable.
  static String? normalize(String? raw) {
    final code = raw?.trim();
    if (code == null || code.isEmpty || code.length > maxLength) return null;
    return code;
  }

  Future<ScanResult> handle(String? raw) {
    if (_pending >= maxQueued) {
      // Refused, never queued: the earlier scans keep their place.
      return Future.value(
        ScanResult(ScanOutcome.busy, queueFullMessage, code: normalize(raw)),
      );
    }
    _pending++;
    final result = _tail
        .then((_) => _handle(raw))
        .whenComplete(() => _pending--);
    _tail = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// Completes true once no other cart change is running (false on timeout).
  Future<bool> _cartIdle() async {
    if (!cart.isMutating) return true;
    final idle = Completer<bool>();
    void listener() {
      if (!cart.isMutating && !idle.isCompleted) idle.complete(true);
    }

    cart.addListener(listener);
    try {
      return await idle.future.timeout(cartWait, onTimeout: () => false);
    } finally {
      cart.removeListener(listener);
    }
  }

  Future<ScanResult> _handle(String? raw) async {
    final code = normalize(raw);
    if (code == null) {
      return const ScanResult(
        ScanOutcome.invalid,
        'That barcode could not be read. Try again.',
      );
    }
    try {
      final item = await products.findByBarcode(code);
      if (item == null) {
        return ScanResult(
          ScanOutcome.notFound,
          'No product found for barcode $code.',
          code: code,
        );
      }
      // Phase 12B: a product sold by weight is never added by a scan with a
      // guessed weight — the cashier selects it and enters the weight.
      if (item.isWeight) {
        return ScanResult(
          ScanOutcome.invalid,
          '${item.productName} is sold by weight: select it and enter the weight.',
          code: code,
        );
      }
      // Phase 16C: a product not configured for POS sale (REVIEW) is never
      // added by a scan — the same rule as tapping it, checked BEFORE the
      // cart is touched, so no empty draft is created on the server and no
      // unsellable line enters an offline cart.
      final notSellable = item.notSellableMessage;
      if (notSellable != null) {
        return ScanResult(
          ScanOutcome.invalid,
          '${item.productName}: $notSellable',
          code: code,
        );
      }
      final label = [
        item.variationName,
        item.unitType,
      ].where((x) => x != null && x.trim().isNotEmpty).join(' · ');
      // Phase 14E-A: wait for any other cart change to finish, then add. A
      // change that starts in the gap is waited for again (bounded).
      var ok = false;
      for (var attempt = 0; attempt < 3; attempt++) {
        if (!await _cartIdle()) break;
        cart.clearError();
        ok = await cart.addItem(
          item.id,
          1,
          label: label.isEmpty ? null : label,
          imageUrl: item.imageUrl,
        );
        if (ok || cart.error != null || !cart.isMutating) break;
      }
      if (ok) {
        return ScanResult(
          ScanOutcome.added,
          'Added 1 × ${item.productName}',
          code: code,
        );
      }
      if (cart.error != null) {
        return ScanResult(
          ScanOutcome.error,
          describeApiError(cart.error!),
          code: code,
        );
      }
      return ScanResult(
        ScanOutcome.busy,
        'The cart is busy — scan ${item.productName} again.',
        code: code,
      );
    } on ApiException catch (e) {
      return ScanResult(ScanOutcome.error, describeApiError(e), code: code);
    } catch (_) {
      return ScanResult(
        ScanOutcome.error,
        'Could not look up barcode $code.',
        code: code,
      );
    }
  }
}
