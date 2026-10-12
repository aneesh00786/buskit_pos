import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../../products/data/product_service.dart';
import '../../products/models/product_item.dart';
import '../data/inventory_service.dart';
import '../models/inventory_adjustment.dart';

enum InventoryLoadStatus { idle, loading, loaded, error }

/// Inventory screen state: product search (reuses the existing
/// `GET /products` browse API — no separate stock-read endpoint), the
/// selected product's stock + adjustment history, and the adjust action.
/// Whether the adjust action / history are shown at all is a UI decision
/// (SessionController.isDenied) — the backend stays authoritative.
class InventoryController extends ChangeNotifier {
  InventoryController(this._inventory, this._products);

  final InventoryService _inventory;
  final ProductService _products;
  bool _disposed = false;

  InventoryLoadStatus _searchStatus = InventoryLoadStatus.idle;
  List<ProductItem> _results = const [];
  ApiException? _searchError;
  String _query = '';
  int _searchGen = 0;

  ProductItem? _selected;

  InventoryLoadStatus _historyStatus = InventoryLoadStatus.idle;
  List<InventoryAdjustment> _history = const [];
  ApiException? _historyError;

  bool _adjusting = false;
  ApiException? _adjustError;
  InventoryAdjustment? _lastAdjustment;
  // Same "one key per logical attempt" rule as refund/cash withdrawal:
  // retrying the SAME product+direction+quantity+reason (e.g. after a
  // timeout) reuses the key; changing any of them gets a fresh one.
  String? _attemptFingerprint;
  String? _attemptKey;

  InventoryLoadStatus get searchStatus => _searchStatus;
  List<ProductItem> get results => _results;
  ApiException? get searchError => _searchError;
  String get query => _query;
  ProductItem? get selected => _selected;
  InventoryLoadStatus get historyStatus => _historyStatus;
  List<InventoryAdjustment> get history => _history;
  ApiException? get historyError => _historyError;
  bool get isAdjusting => _adjusting;
  ApiException? get adjustError => _adjustError;
  InventoryAdjustment? get lastAdjustment => _lastAdjustment;

  /// Whole pieces — the server's own figure, never computed locally.
  int? get selectedStock => _selected?.currentStock?.round();

  Future<void> search(String query) async {
    _query = query.trim();
    final gen = ++_searchGen;
    _searchStatus = InventoryLoadStatus.loading;
    _searchError = null;
    _notify();
    try {
      final page = await _products.search(
        query: _query.isEmpty ? null : _query,
        limit: 20,
      );
      if (gen != _searchGen) return;
      _results = page.items;
      _searchStatus = InventoryLoadStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _searchGen) return;
      _searchError = e;
      _searchStatus = InventoryLoadStatus.error;
    }
    _notify();
  }

  Future<void> select(ProductItem product, {bool loadHistory = true}) async {
    _selected = product;
    _adjustError = null;
    _history = const [];
    _historyStatus = InventoryLoadStatus.idle;
    _notify();
    if (loadHistory) await refreshHistory();
  }

  void clearSelection() {
    _selected = null;
    _history = const [];
    _historyStatus = InventoryLoadStatus.idle;
    _historyError = null;
    _adjustError = null;
    _notify();
  }

  Future<void> refreshHistory() async {
    final product = _selected;
    if (product == null) return;
    _historyStatus = InventoryLoadStatus.loading;
    _historyError = null;
    _notify();
    try {
      _history = await _inventory.listHistory(productVariationId: product.id);
      _historyStatus = InventoryLoadStatus.loaded;
    } on ApiException catch (e) {
      _historyError = e;
      _historyStatus = InventoryLoadStatus.error;
    }
    _notify();
  }

  /// Returns true on success; the server's record is in [lastAdjustment],
  /// the product's stock is re-read from the server, and the history list
  /// is updated.
  Future<bool> adjust({
    required AdjustmentDirection direction,
    required String quantity,
    required String reason,
  }) async {
    final product = _selected;
    if (product == null || _adjusting) return false;
    final fingerprint = '${product.id}|${direction.wire}|$quantity|$reason';
    if (_attemptFingerprint != fingerprint) {
      _attemptFingerprint = fingerprint;
      _attemptKey = generateUuidV4();
    }
    final key = _attemptKey!;

    _adjusting = true;
    _adjustError = null;
    _notify();
    try {
      final result = await _inventory.adjust(
        productVariationId: product.id,
        direction: direction,
        quantity: quantity,
        reason: reason,
        idempotencyKey: key,
      );
      _attemptFingerprint = null;
      _attemptKey = null;
      _lastAdjustment = result;
      if (result != null) _history = [result, ..._history];
      _adjusting = false;
      _notify();
      await refreshSelected();
      return true;
    } on ApiException catch (e) {
      _adjusting = false;
      _adjustError = e;
      _notify();
      // A 422 (e.g. insufficient stock) means our snapshot may be stale.
      if (e.kind == ApiErrorKind.validation) await refreshSelected();
      return false;
    }
  }

  void clearAdjustError() {
    if (_adjustError == null) return;
    _adjustError = null;
    _notify();
  }

  /// Re-reads the selected product from the server (stock AND price) and
  /// updates it in the search results too.
  Future<void> refreshSelected() async {
    final product = _selected;
    if (product == null) return;
    try {
      final fresh = await _products.findById(product.id);
      if (fresh == null || _selected?.id != product.id) return;
      _selected = fresh;
      _results = [for (final p in _results) p.id == fresh.id ? fresh : p];
      _notify();
    } on ApiException {
      // Non-fatal: the adjustment itself already succeeded/failed on its own.
    }
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
