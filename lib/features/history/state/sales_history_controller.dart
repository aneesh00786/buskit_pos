import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../checkout/models/payment.dart';
import '../../products/data/product_service.dart';
import '../data/sales_history_service.dart';
import '../models/sale_history_entry.dart';

enum HistoryListStatus { idle, loading, loaded, empty, error }

enum HistoryDateFilter { today, all }

const int historyPageSize = 20;

/// The store's completed sales (`GET /sales?status=completed`), with search,
/// date and cashier filtering, pagination and per-sale detail all done
/// client-side — the backend has no date range, search, cashier or
/// payment-method filter, and no pagination (verified against
/// Routes/posRoutes.js and posSaleService.listSales before writing this).
///
/// A payment-method filter is intentionally NOT offered: the list response
/// carries no payment data (payments only exist on the per-sale detail), so a
/// real filter would mean fetching every sale's detail just to build a
/// filter chip — expensive and misleading at scale. The UI shows this as a
/// disabled placeholder, consistent with the rest of the app's "coming soon"
/// affordances, rather than silently omitting it.
class SalesHistoryController extends ChangeNotifier {
  SalesHistoryController(this._history, this._products);

  final SalesHistoryService _history;
  final ProductService _products;

  HistoryListStatus _status = HistoryListStatus.idle;
  List<SaleHistoryEntry> _all = const [];
  ApiException? _error;
  bool _loading = false;
  bool _refreshQueued = false;
  int _generation = 0;
  bool _disposed = false;

  String _query = '';
  HistoryDateFilter _dateFilter = HistoryDateFilter.today;
  String? _cashierFilter; // null = all cashiers
  int _page = 1;

  int? _detailId;
  CompletedSale? _detail;
  Map<int, String> _detailNames = const {};
  bool _detailLoading = false;
  ApiException? _detailError;
  int _detailGen = 0;

  HistoryListStatus get status => _status;
  ApiException? get error => _error;
  bool get isLoading => _loading;
  String get query => _query;
  HistoryDateFilter get dateFilter => _dateFilter;
  String? get cashierFilter => _cashierFilter;
  int get page => _page;

  int? get detailSaleId => _detailId;
  CompletedSale? get detail => _detail;
  Map<int, String> get detailNames => _detailNames;
  bool get detailLoading => _detailLoading;
  ApiException? get detailError => _detailError;

  /// Every cashier (`salesman_id`) seen in the currently loaded list, sorted —
  /// the filter dropdown's options. Only as complete as the loaded list.
  List<String> get knownCashiers =>
      _all.map((s) => s.salesmanId).whereType<String>().toSet().toList()
        ..sort();

  bool _matchesDate(SaleHistoryEntry s) {
    if (_dateFilter == HistoryDateFilter.all) return true;
    final w = s.when;
    if (w == null) return false;
    final local = w.toLocal();
    final now = DateTime.now();
    return local.year == now.year &&
        local.month == now.month &&
        local.day == now.day;
  }

  bool _matchesQuery(SaleHistoryEntry s) {
    if (_query.isEmpty) return true;
    return s.displayNumber.toLowerCase().contains(_query.toLowerCase());
  }

  bool _matchesCashier(SaleHistoryEntry s) =>
      _cashierFilter == null || s.salesmanId == _cashierFilter;

  /// The full filtered set, most recent first (the backend already orders by
  /// id desc; `when` may be null for a defensive fallback, so id order is
  /// kept as the primary sort rather than re-sorting by a possibly-missing date).
  List<SaleHistoryEntry> get filtered => _all
      .where((s) => _matchesDate(s) && _matchesQuery(s) && _matchesCashier(s))
      .toList();

  int get totalPages {
    final n = filtered.length;
    if (n == 0) return 1;
    return (n + historyPageSize - 1) ~/ historyPageSize;
  }

  /// The current page of [filtered] (1-based; clamped into range).
  List<SaleHistoryEntry> get pageItems {
    final f = filtered;
    if (f.isEmpty) return const [];
    final p = _page.clamp(1, totalPages);
    final start = (p - 1) * historyPageSize;
    final end = (start + historyPageSize).clamp(0, f.length);
    return f.sublist(start, end);
  }

  void setQuery(String value) {
    if (value == _query) return;
    _query = value;
    _page = 1;
    _notify();
  }

  void setDateFilter(HistoryDateFilter value) {
    if (value == _dateFilter) return;
    _dateFilter = value;
    _page = 1;
    _notify();
  }

  void setCashierFilter(String? value) {
    if (value == _cashierFilter) return;
    _cashierFilter = value;
    _page = 1;
    _notify();
  }

  void setPage(int value) {
    final clamped = value.clamp(1, totalPages);
    if (clamped == _page) return;
    _page = clamped;
    _notify();
  }

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Loads (or reloads) the completed-sales list. An existing list stays on
  /// screen while a refresh runs; a refresh requested mid-flight is queued
  /// and runs once more afterwards, so the list always ends up current.
  Future<void> refresh() async {
    if (_loading) {
      _refreshQueued = true;
      return;
    }
    _loading = true;
    _error = null;
    if (_all.isEmpty) _status = HistoryListStatus.loading;
    final gen = ++_generation;
    _notify();
    try {
      final rows = await _history.listCompleted();
      if (gen != _generation || _disposed) return;
      _all = rows;
      _status = rows.isEmpty
          ? HistoryListStatus.empty
          : HistoryListStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation || _disposed) return;
      _error = e;
      _status = _all.isEmpty
          ? HistoryListStatus.error
          : HistoryListStatus.loaded;
    } finally {
      if (!_disposed) {
        _loading = false;
        if (_refreshQueued) {
          _refreshQueued = false;
          unawaited(refresh());
        } else {
          _notify();
        }
      }
    }
  }

  /// Loads the detail (items, payments, totals) of [id], plus best-effort
  /// current product names for its lines (the detail response has none).
  /// Stale-response protected: only the latest selection's result is kept.
  Future<void> selectSale(int id) async {
    _detailId = id;
    _detail = null;
    _detailNames = const {};
    _detailError = null;
    _detailLoading = true;
    final gen = ++_detailGen;
    _notify();
    try {
      final sale = await _history.getDetail(id);
      if (gen != _detailGen || _disposed) return;
      if (sale == null) {
        _detailError = const ApiException(
          kind: ApiErrorKind.notFound,
          message: 'This sale could not be found.',
        );
        _detailLoading = false;
        _notify();
        return;
      }
      _detail = sale;
      _detailLoading = false;
      _notify();
      unawaited(_resolveNames(sale, gen));
    } on ApiException catch (e) {
      if (gen != _detailGen || _disposed) return;
      _detailError = e;
      _detailLoading = false;
      _notify();
    }
  }

  /// Best-effort: a product renamed or removed since the sale falls back to
  /// "Item {id}" (the same fallback `ReceiptFormatter` uses), never an error.
  Future<void> _resolveNames(CompletedSale sale, int gen) async {
    final ids = sale.items.map((i) => i.productVariationId).toSet();
    final names = <int, String>{};
    for (final id in ids) {
      if (gen != _detailGen || _disposed) return;
      try {
        final p = await _products.findById(id);
        if (p != null) names[id] = p.productName;
      } catch (_) {
        // Best-effort only — a lookup failure just leaves that name unresolved.
      }
    }
    if (gen != _detailGen || _disposed) return;
    _detailNames = names;
    _notify();
  }

  void closeDetail() {
    _detailId = null;
    _detail = null;
    _detailNames = const {};
    _detailError = null;
    _detailGen++;
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
