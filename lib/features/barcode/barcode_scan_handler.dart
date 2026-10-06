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
class BarcodeScanHandler {
  BarcodeScanHandler({required this.products, required this.cart});
  final ProductService products;
  final CartController cart;

  static const maxLength = 50;

  Future<void> _tail = Future<void>.value();

  /// Trims and validates a raw code; null when unusable.
  static String? normalize(String? raw) {
    final code = raw?.trim();
    if (code == null || code.isEmpty || code.length > maxLength) return null;
    return code;
  }

  Future<ScanResult> handle(String? raw) {
    final result = _tail.then((_) => _handle(raw));
    _tail = result.then((_) {}, onError: (_) {});
    return result;
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
      final label = [
        item.variationName,
        item.unitType,
      ].where((x) => x != null && x.trim().isNotEmpty).join(' · ');
      cart.clearError();
      final ok = await cart.addItem(
        item.id,
        1,
        label: label.isEmpty ? null : label,
        imageUrl: item.imageUrl,
      );
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
