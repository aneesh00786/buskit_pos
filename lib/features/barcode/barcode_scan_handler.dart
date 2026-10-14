import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/network/error_messages.dart';
import '../../core/utils/format.dart';
import '../../core/utils/quantity.dart';
import '../cart/state/cart_controller.dart';
import '../products/data/product_service.dart';
import 'scale_label.dart';

/// [confirmRepeat]: the same scale label is already in this sale — the
/// cashier must confirm a second identical pack ([BarcodeScanHandler.handle]
/// with `confirmRepeat: true`); nothing was added.
enum ScanOutcome { added, notFound, invalid, busy, error, confirmRepeat }

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
    this.scaleLabels,
    this.cartWait = const Duration(seconds: 15),
  });
  final ProductService products;
  final CartController cart;

  /// Supermarket scale labels: a code of an active format is sent to the
  /// server as a label (the server reads the PLU and the weight); every
  /// other code takes the ordinary barcode path below, unchanged. Null (or
  /// no active format) = no scale labels at all.
  final ScaleLabelRecognizer? scaleLabels;

  static const scaleOfflineMessage =
      'Scale labels need a connection to the server. Nothing was added; scan it again when the till is back online.';
  static const repeatedLabelCode = 'POS_SCALE_LABEL_REPEATED';

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

  /// [confirmRepeat]: the cashier confirmed a second identical pack after a
  /// [ScanOutcome.confirmRepeat] answer for this scale label.
  Future<ScanResult> handle(String? raw, {bool confirmRepeat = false}) {
    if (_pending >= maxQueued) {
      // Refused, never queued: the earlier scans keep their place.
      return Future.value(
        ScanResult(ScanOutcome.busy, queueFullMessage, code: normalize(raw)),
      );
    }
    _pending++;
    final result = _tail
        .then((_) => _handle(raw, confirmRepeat))
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

  Future<ScanResult> _handle(String? raw, bool confirmRepeat) async {
    final code = normalize(raw);
    if (code == null) {
      return const ScanResult(
        ScanOutcome.invalid,
        'That barcode could not be read. Try again.',
      );
    }
    final scale = scaleLabels;
    if (scale != null) {
      final offline = cart.offline?.isOffline() ?? false;
      if (await scale.matches(code, online: !offline)) {
        return _scaleLabel(scale, code, confirmRepeat);
      }
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
        final merged = cart.takeMergeNotice();
        return ScanResult(
          ScanOutcome.added,
          'Added 1 × ${item.productName}${merged == null ? '' : '. ${merged.text}'}',
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

  /// A scale label: the SERVER parses it, finds the product from its PLU and
  /// prices the weight; this only sends the barcode. A refused label leaves
  /// the cart exactly as it was.
  Future<ScanResult> _scaleLabel(
    ScaleLabelRecognizer scale,
    String code,
    bool confirmRepeat,
  ) async {
    // No sale yet: let the server read the label first, so a refused label
    // never opens an empty sale (the add below checks everything again).
    final draft = cart.sale;
    if ((draft == null || !draft.isDraft) &&
        !(cart.offline?.isOffline() ?? false) &&
        !cart.isLocalSale) {
      try {
        await scale.service.resolve(code);
      } on ApiException catch (e) {
        return ScanResult(ScanOutcome.error, describeApiError(e), code: code);
      } catch (_) {
        return ScanResult(
          ScanOutcome.error,
          'Could not read scale label $code.',
          code: code,
        );
      }
    }
    ScaleLabelLine? read;
    var ok = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      if (!await _cartIdle()) break;
      cart.clearError();
      ok = await cart.addViaServer((draft) async {
        final (sale, line) = await scale.service.addToSale(
          saleId: draft.id,
          barcode: code,
          expectedVersion: draft.version,
          confirmRepeat: confirmRepeat,
        );
        read = line;
        return sale;
      }, offlineMessage: scaleOfflineMessage);
      if (ok || cart.error != null || !cart.isMutating) break;
    }
    if (ok) {
      final r = read;
      final merged = cart.takeMergeNotice();
      return ScanResult(
        ScanOutcome.added,
        (r == null
                ? 'Scale label added.'
                : 'Added ${formatQuantity(r.weightKg, weight: true)} kg × ${r.productName} — ${formatMoney(r.lineTotal)}') +
            (merged == null ? '' : '. ${merged.text}'),
        code: code,
      );
    }
    final e = cart.error;
    if (e != null && e.errorCode == repeatedLabelCode) {
      cart.clearError();
      return ScanResult(ScanOutcome.confirmRepeat, e.message, code: code);
    }
    if (e != null) {
      return ScanResult(ScanOutcome.error, describeApiError(e), code: code);
    }
    return ScanResult(
      ScanOutcome.busy,
      'The cart is busy — scan the label again.',
      code: code,
    );
  }
}
