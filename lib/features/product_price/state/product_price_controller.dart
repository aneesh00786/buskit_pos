import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../data/product_price_service.dart';
import '../models/price_change.dart';

enum PriceHistoryStatus { idle, loading, loaded, error }

/// POS-only price change + its history for one product at a time. Whether
/// the action is shown at all is a UI decision (SessionController.isDenied);
/// the backend enforces `products.price_change` regardless.
class ProductPriceController extends ChangeNotifier {
  ProductPriceController(this._service, {this.onPriceChanged});

  final ProductPriceService _service;

  /// Called after every successful change/reset (e.g. to re-read the product
  /// and refresh the sales catalogue).
  final Future<void> Function()? onPriceChanged;

  bool _disposed = false;
  bool _busy = false;
  ApiException? _error;
  ProductPriceState? _last;

  PriceHistoryStatus _historyStatus = PriceHistoryStatus.idle;
  List<PriceChange> _history = const [];
  ApiException? _historyError;
  int? _historyProductId;

  // One idempotency key per logical attempt: retrying the SAME product,
  // version, price and reason (e.g. after a timeout) reuses it; anything
  // different gets a fresh key.
  String? _attemptFingerprint;
  String? _attemptKey;

  bool get isBusy => _busy;
  ApiException? get error => _error;
  ProductPriceState? get lastResult => _last;
  PriceHistoryStatus get historyStatus => _historyStatus;
  List<PriceChange> get history => _history;
  ApiException? get historyError => _historyError;

  String _keyFor(String fingerprint) {
    if (_attemptFingerprint != fingerprint) {
      _attemptFingerprint = fingerprint;
      _attemptKey = generateUuidV4();
    }
    return _attemptKey!;
  }

  Future<bool> changePrice({
    required int productId,
    required int expectedVersion,
    required String price,
    String? reason,
  }) {
    final key = _keyFor(
      'set|$productId|$expectedVersion|$price|${reason ?? ''}',
    );
    return _run(
      productId,
      () => _service.setPrice(
        productId: productId,
        price: price,
        expectedVersion: expectedVersion,
        idempotencyKey: key,
        reason: reason,
      ),
    );
  }

  Future<bool> resetPrice({
    required int productId,
    required int expectedVersion,
    String? reason,
  }) {
    final key = _keyFor('reset|$productId|$expectedVersion|${reason ?? ''}');
    return _run(
      productId,
      () => _service.resetPrice(
        productId: productId,
        expectedVersion: expectedVersion,
        idempotencyKey: key,
        reason: reason,
      ),
    );
  }

  Future<bool> _run(
    int productId,
    Future<ProductPriceState?> Function() call,
  ) async {
    if (_busy) return false;
    _busy = true;
    _error = null;
    _notify();
    try {
      _last = await call();
      _attemptFingerprint = null;
      _attemptKey = null;
      final change = _last?.change;
      if (change != null && _historyProductId == productId) {
        _history = [change, ..._history.where((c) => c.id != change.id)];
      }
      _busy = false;
      _notify();
      await onPriceChanged?.call();
      return true;
    } on ApiException catch (e) {
      _busy = false;
      _error = e;
      _notify();
      // A stale version means our displayed price is out of date.
      if (e.kind == ApiErrorKind.conflict) await onPriceChanged?.call();
      return false;
    }
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  Future<void> loadHistory(int productId) async {
    _historyProductId = productId;
    _historyStatus = PriceHistoryStatus.loading;
    _historyError = null;
    _notify();
    try {
      final state = await _service.history(productId);
      if (_historyProductId != productId) return;
      _history = state?.history ?? const [];
      _historyStatus = PriceHistoryStatus.loaded;
    } on ApiException catch (e) {
      if (_historyProductId != productId) return;
      _historyError = e;
      _historyStatus = PriceHistoryStatus.error;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
