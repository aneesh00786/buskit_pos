import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../data/store_exception_service.dart';

/// Phase 9 — the manager's store-wide Payment Exceptions screen. Server
/// data only: nothing is cached across loads, and while the POS is offline
/// the list and detail are cleared (never shown as current) and nothing can
/// be resolved — there is no offline payment-exception resolution.
class StoreExceptionsController extends ChangeNotifier {
  StoreExceptionsController(this._service, {bool Function()? isOffline})
    : _isOffline = isOffline ?? (() => false);

  final StoreExceptionService _service;
  final bool Function() _isOffline;

  static const filters = [
    'UNRESOLVED',
    'OPEN',
    'MANUAL_REFUND_REQUIRED',
    'REFUND_PENDING',
    'REFUND_FAILED',
    'REFUNDED',
    'ALL',
  ];
  static const pageSize = 25;

  String _filter = 'UNRESOLVED';
  List<StoreExceptionItem> _items = const [];
  int? _nextBeforeId;
  bool _loading = false;
  bool _loadingMore = false;
  bool _offline = false;
  ApiException? _error;
  StoreExceptionDetail? _detail;
  bool _detailLoading = false;
  ApiException? _detailError;
  int _generation = 0;
  bool _disposed = false;

  String get filter => _filter;
  List<StoreExceptionItem> get items => _items;
  bool get hasMore => _nextBeforeId != null;
  bool get loading => _loading;
  bool get loadingMore => _loadingMore;
  bool get offline => _offline;
  ApiException? get error => _error;
  StoreExceptionDetail? get detail => _detail;
  bool get detailLoading => _detailLoading;
  ApiException? get detailError => _detailError;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _blockedOffline() {
    if (!_isOffline()) {
      _offline = false;
      return false;
    }
    _offline = true;
    _items = const [];
    _nextBeforeId = null;
    _detail = null;
    _notify();
    return true;
  }

  /// First page for the current filter (also "Refresh").
  Future<void> load() async {
    if (_blockedOffline()) return;
    final gen = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final page = await _service.list(state: _filter, limit: pageSize);
      if (gen != _generation) return;
      _items = page.items;
      _nextBeforeId = page.nextBeforeId;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      _items = const [];
      _nextBeforeId = null;
      if (e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout) {
        _offline = true;
      }
    } finally {
      if (gen == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  /// The next (older) page, appended.
  Future<void> loadMore() async {
    final before = _nextBeforeId;
    if (before == null || _loading || _loadingMore) return;
    if (_blockedOffline()) return;
    final gen = _generation;
    _loadingMore = true;
    _notify();
    try {
      final page = await _service.list(
        state: _filter,
        beforeId: before,
        limit: pageSize,
      );
      if (gen != _generation) return;
      final seen = _items.map((i) => i.paymentAttemptId).toSet();
      _items = [
        ..._items,
        ...page.items.where((i) => !seen.contains(i.paymentAttemptId)),
      ];
      _nextBeforeId = page.nextBeforeId;
    } on ApiException catch (e) {
      if (gen == _generation) _error = e;
    } finally {
      _loadingMore = false;
      _notify();
    }
  }

  Future<void> setFilter(String f) async {
    if (!filters.contains(f) || f == _filter) return;
    _filter = f;
    _detail = null;
    await load();
  }

  /// Opens one payment ([refresh]: ask the provider first).
  Future<void> open(int attemptId, {bool refresh = false}) async {
    if (_blockedOffline()) return;
    _detailLoading = true;
    _detailError = null;
    _notify();
    try {
      _detail = await _service.detail(attemptId, refresh: refresh);
    } on ApiException catch (e) {
      _detailError = e;
      _detail = null;
    } finally {
      _detailLoading = false;
      _notify();
    }
  }

  void closeDetail() {
    _detail = null;
    _detailError = null;
    _notify();
  }

  /// After a resolution: the list and the open detail are re-read from the
  /// server (the server's state is the only truth).
  Future<void> afterAction(int attemptId) async {
    await load();
    await open(attemptId);
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
