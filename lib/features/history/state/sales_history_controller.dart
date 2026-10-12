import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../../checkout/models/payment.dart';
import '../../products/data/product_service.dart';
import '../data/sales_history_service.dart';
import '../models/partial_refund.dart';
import '../models/sale_history_entry.dart';

enum HistoryListStatus { idle, loading, loaded, empty, error }

enum RefundStatus { idle, refunding }

enum HistoryDateFilter { today, all }

const int historyPageSize = 20;

/// "All" loads the history in batches of this many sales, newest first
/// ("Load older sales" fetches the next batch) — never the whole history.
const int historyBatchSize = 500;

/// The store's completed sales (`GET /sales?status=completed`). "Today" asks
/// the server for the store's current business day only; "All" loads the
/// newest [historyBatchSize] sales and older batches on request (Phase 5 —
/// the list used to download every sale the store ever made). Search,
/// cashier filtering, pagination of the loaded rows and per-sale detail are
/// done client-side.
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
  bool _hasOlder = false;
  bool _loadingOlder = false;

  /// "All" view: older sales exist beyond the loaded batches.
  bool get hasOlder => _dateFilter == HistoryDateFilter.all && _hasOlder;
  bool get loadingOlder => _loadingOlder;
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

  RefundStatus _refundStatus = RefundStatus.idle;
  ApiException? _refundError;
  // Same "same attempt keeps its key across a retry" rule as
  // CartController.completeSale — a refund has no varying request body, so
  // the sale id alone is the fingerprint. Attempting a DIFFERENT sale always
  // gets a fresh key.
  int? _refundAttemptSaleId;
  String? _refundAttemptKey;

  // Partial refunds (Phase 17.8). Same key-per-attempt rule, but the
  // request body varies, so the fingerprint is sale + lines + method +
  // reason + the confirmed (server-previewed) amount: an identical retry
  // reuses the key, any change gets a fresh one.
  bool _previewing = false;
  ApiException? _previewError;
  String? _partialAttemptFingerprint;
  String? _partialAttemptKey;
  PartialRefund? _lastPartialRefund;

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

  bool get isRefunding => _refundStatus == RefundStatus.refunding;
  ApiException? get refundError => _refundError;

  bool get isPreviewing => _previewing;
  ApiException? get previewError => _previewError;

  /// The refund recorded by the last successful [refundItems] call.
  PartialRefund? get lastPartialRefund => _lastPartialRefund;

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
    // Today and All come from different server windows.
    unawaited(refresh());
  }

  /// Appends the next batch of older sales to the "All" view.
  Future<void> loadOlder() async {
    if (!hasOlder || _loadingOlder || _loading || _all.isEmpty) return;
    _loadingOlder = true;
    final gen = _generation;
    _notify();
    try {
      final rows = await _history.listCompleted(
        limit: historyBatchSize,
        beforeId: _all.last.id,
      );
      if (gen != _generation || _disposed) return;
      final known = _all.map((s) => s.id).toSet();
      _all = [..._all, ...rows.where((r) => !known.contains(r.id))];
      _hasOlder = rows.length >= historyBatchSize;
    } on ApiException catch (e) {
      if (gen != _generation || _disposed) return;
      _error = e;
    } finally {
      if (!_disposed) {
        _loadingOlder = false;
        _notify();
      }
    }
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
      final all = _dateFilter == HistoryDateFilter.all;
      final rows = all
          ? await _history.listCompleted(limit: historyBatchSize)
          : await _history.listCompleted(todayOnly: true);
      if (gen != _generation || _disposed) return;
      _all = rows;
      _hasOlder = all && rows.length >= historyBatchSize;
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

  bool _providerRefreshing = false;
  bool get isRefreshingProviderRefunds => _providerRefreshing;

  /// Asks the server to reconcile the open sale's pending provider refunds
  /// (e.g. a Razorpay UPI refund) and shows the result. Errors keep the
  /// current view.
  Future<void> refreshProviderRefunds() async {
    final id = _detailId;
    if (id == null || _providerRefreshing) return;
    _providerRefreshing = true;
    _notify();
    try {
      final sale = await _history.getDetail(id, refresh: true);
      if (!_disposed && _detailId == id && sale != null) _detail = sale;
    } on ApiException {
      // Leave the current detail in place; the cashier can try again.
    } finally {
      _providerRefreshing = false;
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

  void clearRefundError() {
    if (_refundError == null) return;
    _refundError = null;
    _notify();
  }

  /// FULL-SALE REFUND ONLY (`POST /sales/:id/refund`). Requires
  /// `payments.refund` — enforced entirely server-side; a denial surfaces as
  /// an [ApiException] with `kind == ApiErrorKind.forbidden` and
  /// `errorCode == PosErrorCodes.permissionDenied`, same as every other
  /// permission-gated POS action. The sale itself is left exactly as the
  /// server returns it (still 'completed'; `refund` now non-null on
  /// success) — this never guesses at the outcome locally.
  ///
  /// Same idempotency-key-per-attempt rule as
  /// `CartController.completeSale`: retrying the SAME sale (e.g. after a
  /// network error where the outcome is unknown) reuses the same key so the
  /// server can safely replay; a different sale always gets a fresh one.
  Future<bool> refundSale(int saleId) async {
    if (_refundStatus == RefundStatus.refunding) return false;
    if (_refundAttemptSaleId != saleId) {
      _refundAttemptSaleId = saleId;
      _refundAttemptKey = generateUuidV4();
    }
    final key = _refundAttemptKey!;

    _refundStatus = RefundStatus.refunding;
    _refundError = null;
    _notify();
    try {
      final result = await _history.refundSale(
        saleId: saleId,
        idempotencyKey: key,
      );
      _refundStatus = RefundStatus.idle;
      if (result != null && _detailId == saleId) {
        _detail = result;
      }
      // A successful refund closes this attempt — a later refund on the
      // SAME sale id (which the backend will reject as already-refunded)
      // must not replay this key.
      _refundAttemptSaleId = null;
      _refundAttemptKey = null;
      _notify();
      await _refetchAfterRefund(saleId);
      return true;
    } on ApiException catch (e) {
      _refundStatus = RefundStatus.idle;
      _refundError = e;
      _notify();
      return false;
    }
  }

  /// Asks the server to calculate a partial refund. Returns null (with
  /// [previewError] set) on failure. The preview is display-only — the
  /// client never computes or trusts its own refund totals.
  Future<RefundPreview?> previewRefund(
    int saleId,
    List<RefundRequestLine> lines, {
    String? refundMethod,
  }) async {
    if (_previewing) return null;
    _previewing = true;
    _previewError = null;
    _notify();
    try {
      final preview = await _history.previewRefund(
        saleId: saleId,
        lines: lines,
        refundMethod: refundMethod,
      );
      _previewing = false;
      _notify();
      return preview;
    } on ApiException catch (e) {
      _previewing = false;
      _previewError = e;
      _notify();
      return null;
    }
  }

  void clearPreviewError() {
    if (_previewError == null) return;
    _previewError = null;
    _notify();
  }

  /// Records a partial refund for [saleId] (`POST /sales/:id/refunds`),
  /// sending the previewed [expectedRefundAmount] the cashier confirmed.
  /// On success the sale is RE-FETCHED from the server (never patched
  /// locally) and the list is refreshed for its refund badge. Shares
  /// [isRefunding] with the whole-sale refund: only one refund in flight.
  Future<bool> refundItems(
    int saleId,
    List<RefundRequestLine> lines, {
    required double expectedRefundAmount,
    String? refundMethod,
    String? reason,
  }) async {
    if (_refundStatus == RefundStatus.refunding) return false;
    final sorted = [...lines]
      ..sort((a, b) => a.saleItemId.compareTo(b.saleItemId));
    final fingerprint = [
      saleId,
      sorted.map((l) => l.canonical).join(','),
      refundMethod ?? '',
      reason?.trim() ?? '',
      expectedRefundAmount,
    ].join('|');
    if (_partialAttemptFingerprint != fingerprint) {
      _partialAttemptFingerprint = fingerprint;
      _partialAttemptKey = generateUuidV4();
    }
    final key = _partialAttemptKey!;

    _refundStatus = RefundStatus.refunding;
    _refundError = null;
    _notify();
    try {
      final result = await _history.refundItems(
        saleId: saleId,
        lines: lines,
        expectedRefundAmount: expectedRefundAmount,
        idempotencyKey: key,
        refundMethod: refundMethod,
        reason: reason,
      );
      _lastPartialRefund = result.refund;
      // This attempt is closed: an identical later refund is a NEW request.
      _partialAttemptFingerprint = null;
      _partialAttemptKey = null;
      if (result.sale != null && _detailId == saleId) _detail = result.sale;
      _refundStatus = RefundStatus.idle;
      _notify();
      await _refetchAfterRefund(saleId);
      return true;
    } on ApiException catch (e) {
      _refundStatus = RefundStatus.idle;
      _refundError = e;
      _notify();
      return false;
    }
  }

  void clearLastPartialRefund() {
    _lastPartialRefund = null;
  }

  /// Authoritative re-read after a refund: the sale detail and the list
  /// (refund badge). A failure here keeps what the refund response returned.
  Future<void> _refetchAfterRefund(int saleId) async {
    try {
      final fresh = await _history.getDetail(saleId);
      if (fresh != null && _detailId == saleId && !_disposed) {
        _detail = fresh;
        _notify();
      }
    } on ApiException {
      // keep the refund response's sale view
    }
    unawaited(refresh());
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
