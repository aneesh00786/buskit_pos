import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../cart/data/cart_service.dart';
import '../../cart/models/cart_sale.dart';
import '../data/held_sales_service.dart';
import '../models/held_sale_summary.dart';

enum HeldListStatus { idle, loading, loaded, empty, error }

/// The store's held sales (`GET /sales?status=held`) plus a detail preview
/// (`GET /sales/:id`) of the one the cashier selects.
///
/// Rules:
///  * only one list request runs at a time; a refresh requested while one is
///    running is remembered and runs once afterwards, so the list always ends
///    up reflecting the latest hold/resume;
///  * an existing list stays on screen while it refreshes;
///  * a response for anything other than the latest list generation or the
///    currently selected sale is discarded (stale-response protection);
///  * nothing is retried automatically.
///
/// The store is derived from the token by the server — no scope is ever sent.
class HeldSalesController extends ChangeNotifier {
  HeldSalesController(this._list, this._detailService);

  final HeldSalesService _list;
  final CartService _detailService;

  HeldListStatus _status = HeldListStatus.idle;
  List<HeldSaleSummary> _sales = const [];
  ApiException? _error;
  bool _loading = false;
  bool _refreshQueued = false;
  int _generation = 0;
  bool _disposed = false;

  int? _detailId;
  CartSale? _detail;
  bool _detailLoading = false;
  ApiException? _detailError;
  int _detailGen = 0;

  HeldListStatus get status => _status;
  List<HeldSaleSummary> get sales => _sales;
  ApiException? get error => _error;

  /// True while a request is running (also true during a background refresh).
  bool get isLoading => _loading;

  /// Number of held sales once known; null before the first successful load.
  int? get heldCount =>
      (_status == HeldListStatus.loaded || _status == HeldListStatus.empty)
      ? _sales.length
      : null;

  int? get detailSaleId => _detailId;
  CartSale? get detail => _detail;
  bool get detailLoading => _detailLoading;
  ApiException? get detailError => _detailError;

  /// Loads (or reloads) the list. If one is already running, a follow-up
  /// reload is queued instead of a parallel request.
  Future<void> refresh() async {
    if (_loading) {
      _refreshQueued = true;
      return;
    }
    do {
      _refreshQueued = false;
      await _loadOnce();
    } while (_refreshQueued && !_disposed);
  }

  Future<void> _loadOnce() async {
    final gen = ++_generation;
    _loading = true;
    _error = null;
    if (_sales.isEmpty) _status = HeldListStatus.loading;
    _notify();
    try {
      final result = await _list.listHeld();
      if (gen != _generation) return;
      _sales = result;
      _status = result.isEmpty ? HeldListStatus.empty : HeldListStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      // Keep showing a list we already have; only a first load becomes an error page.
      if (_sales.isEmpty) _status = HeldListStatus.error;
    } finally {
      if (gen == _generation) _loading = false;
      _notify();
    }
  }

  /// Drops a sale from the local list once the server confirmed it changed
  /// (resumed); the follow-up refresh confirms the rest.
  void removeLocally(int saleId) {
    if (!_sales.any((s) => s.id == saleId)) return;
    _sales = _sales.where((s) => s.id != saleId).toList();
    if (_sales.isEmpty && _status == HeldListStatus.loaded) {
      _status = HeldListStatus.empty;
    }
    _notify();
  }

  // ---- detail ----

  /// Loads the live view (items, totals, current version) of held sale [id].
  Future<void> openDetail(int id) async {
    final gen = ++_detailGen;
    _detailId = id;
    _detail = null;
    _detailError = null;
    _detailLoading = true;
    _notify();
    try {
      final view = await _detailService.getSale(id);
      if (gen != _detailGen) return; // the cashier already picked another sale
      _detail = view;
    } on ApiException catch (e) {
      if (gen != _detailGen) return;
      _detailError = e;
    } finally {
      if (gen == _detailGen) _detailLoading = false;
      _notify();
    }
  }

  void closeDetail() {
    _detailGen++;
    _detailId = null;
    _detail = null;
    _detailError = null;
    _detailLoading = false;
    _notify();
  }

  void reset() {
    _generation++;
    _detailGen++;
    _status = HeldListStatus.idle;
    _sales = const [];
    _error = null;
    _loading = false;
    _refreshQueued = false;
    _detailId = null;
    _detail = null;
    _detailError = null;
    _detailLoading = false;
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
