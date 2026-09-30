import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../loyalty/data/loyalty_service.dart';
import '../../loyalty/models/loyalty_profile.dart';
import '../data/customer_service.dart';
import '../models/customer.dart';
import '../models/customer_purchase.dart';

enum CustomerListStatus { idle, loading, loaded, empty, error }

/// Search/list (server-paginated, debounced) plus one selected customer's
/// detail + purchase history, plus create/update — one controller, following
/// the same shape `SalesHistoryController` uses for list+detail.
///
/// Concurrency rules (same as `ProductListController`/`SalesHistoryController`):
///  * every new search starts a generation; stale responses are discarded;
///  * an identical first-page request already in flight is not duplicated;
///  * only one "load more" runs at a time;
///  * selecting a customer bumps its own generation, independent of the list's,
///    so switching selection never lets an old detail/purchase response land;
///  * create/update use a single-flight lock (like `CartController`'s `_op`) —
///    no double-submit.
class CustomerListController extends ChangeNotifier {
  CustomerListController(
    this._service, {
    LoyaltyService? loyaltyService,
    this.debounce = const Duration(milliseconds: 350),
    this.pageSize = 20,
  }) : _loyaltyService = loyaltyService;

  final CustomerService _service;

  /// Null when the caller doesn't wire loyalty in (e.g. existing tests that
  /// predate this feature) — the loyalty section is then simply not shown,
  /// same as when the company has no active program.
  final LoyaltyService? _loyaltyService;
  final Duration debounce;
  final int pageSize;

  CustomerListStatus _status = CustomerListStatus.idle;
  final List<Customer> _items = [];
  int _page = 0;
  int _totalPages = 1;
  int _total = 0;
  bool _loadingMore = false;
  ApiException? _error;
  ApiException? _loadMoreError;

  String _query = '';
  Timer? _debounceTimer;
  int _generation = 0;
  String? _firstPageInFlightKey;
  bool _disposed = false;

  String? _detailId;
  Customer? _detail;
  bool _detailLoading = false;
  ApiException? _detailError;
  CustomerPurchasePage? _purchases;
  bool _purchasesLoading = false;
  ApiException? _purchasesError;
  LoyaltyProfile? _loyalty;
  bool _loyaltyLoading = false;
  ApiException? _loyaltyError;
  int _detailGen = 0;

  bool _mutating = false;
  ApiException? _mutationError;

  CustomerListStatus get status => _status;
  List<Customer> get items => List.unmodifiable(_items);
  bool get hasMore => _page > 0 && _page < _totalPages;
  bool get loadingMore => _loadingMore;
  ApiException? get error => _error;
  ApiException? get loadMoreError => _loadMoreError;
  String get query => _query;
  int get total => _total;

  String? get detailCustomerId => _detailId;
  Customer? get detail => _detail;
  bool get detailLoading => _detailLoading;
  ApiException? get detailError => _detailError;
  CustomerPurchasePage? get purchases => _purchases;
  bool get purchasesLoading => _purchasesLoading;
  ApiException? get purchasesError => _purchasesError;
  LoyaltyProfile? get loyalty => _loyalty;
  bool get loyaltyLoading => _loyaltyLoading;
  ApiException? get loyaltyError => _loyaltyError;

  bool get isMutating => _mutating;
  ApiException? get mutationError => _mutationError;

  // ---- list ----

  Future<void> loadInitial() => _loadFirstPage();
  Future<void> retry() => _loadFirstPage();

  void onQueryChanged(String text) {
    final next = text.trim();
    _debounceTimer?.cancel();
    if (next == _query) return;
    _debounceTimer = Timer(debounce, () {
      _query = next;
      unawaited(_loadFirstPage());
    });
  }

  Future<void> submitQuery(String text) {
    _debounceTimer?.cancel();
    _query = text.trim();
    return _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    final key = _query;
    if (_status == CustomerListStatus.loading && _firstPageInFlightKey == key) {
      return;
    }
    final gen = ++_generation;
    _firstPageInFlightKey = key;
    _status = CustomerListStatus.loading;
    _error = null;
    _loadMoreError = null;
    _loadingMore = false;
    _items.clear();
    _page = 0;
    _totalPages = 1;
    _total = 0;
    _notify();

    try {
      final res = await _service.search(
        query: _query,
        page: 1,
        limit: pageSize,
      );
      if (gen != _generation) return;
      _items.addAll(res.items);
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
      _total = res.pagination.total;
      _status = _items.isEmpty
          ? CustomerListStatus.empty
          : CustomerListStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      _status = CustomerListStatus.error;
    } finally {
      if (gen == _generation) _firstPageInFlightKey = null;
      _notify();
    }
  }

  Future<void> loadNextPage() async {
    if (_status != CustomerListStatus.loaded || _loadingMore || !hasMore) {
      return;
    }
    final gen = _generation;
    final nextPage = _page + 1;
    _loadingMore = true;
    _loadMoreError = null;
    _notify();
    try {
      final res = await _service.search(
        query: _query,
        page: nextPage,
        limit: pageSize,
      );
      if (gen != _generation) return;
      final known = _items.map((c) => c.customerId).toSet();
      _items.addAll(res.items.where((c) => !known.contains(c.customerId)));
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
      _total = res.pagination.total;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _loadMoreError = e;
    } finally {
      if (gen == _generation) _loadingMore = false;
      _notify();
    }
  }

  // ---- detail + purchase history ----

  Future<void> selectCustomer(String customerId) async {
    _detailId = customerId;
    _detail = null;
    _detailError = null;
    _purchases = null;
    _purchasesError = null;
    _loyalty = null;
    _loyaltyError = null;
    _detailLoading = true;
    _purchasesLoading = true;
    _loyaltyLoading = _loyaltyService != null;
    final gen = ++_detailGen;
    _notify();

    try {
      final c = await _service.findByCustomerId(customerId);
      if (gen != _detailGen || _disposed) return;
      if (c == null) {
        _detailError = const ApiException(
          kind: ApiErrorKind.notFound,
          message: 'This customer could not be found.',
        );
        _detailLoading = false;
        _purchasesLoading = false;
        _loyaltyLoading = false;
        _notify();
        return;
      }
      _detail = c;
      _detailLoading = false;
      _notify();
    } on ApiException catch (e) {
      if (gen != _detailGen || _disposed) return;
      _detailError = e;
      _detailLoading = false;
      _purchasesLoading = false;
      _loyaltyLoading = false;
      _notify();
      return;
    }
    unawaited(_loadPurchases(customerId, gen));
    unawaited(_loadLoyalty(customerId, gen));
  }

  Future<void> _loadLoyalty(String customerId, int gen) async {
    final service = _loyaltyService;
    if (service == null) return;
    if (gen != _detailGen || _disposed) return;
    _loyaltyLoading = true;
    _loyaltyError = null;
    _notify();
    try {
      final p = await service.getProfile(customerId);
      if (gen != _detailGen || _disposed) return;
      _loyalty = p;
    } on ApiException catch (e) {
      if (gen != _detailGen || _disposed) return;
      _loyaltyError = e;
    } finally {
      if (gen == _detailGen && !_disposed) {
        _loyaltyLoading = false;
        _notify();
      }
    }
  }

  /// Re-fetches just the loyalty profile for the currently open customer —
  /// the "Retry" action for a loyalty-section-only failure.
  Future<void> retryLoyalty() async {
    final id = _detailId;
    if (id == null) return;
    await _loadLoyalty(id, _detailGen);
  }

  Future<void> _loadPurchases(
    String customerId,
    int gen, {
    int page = 1,
  }) async {
    if (gen != _detailGen || _disposed) return;
    _purchasesLoading = true;
    _purchasesError = null;
    _notify();
    try {
      final p = await _service.purchaseHistory(customerId, page: page);
      if (gen != _detailGen || _disposed) return;
      _purchases = p;
    } on ApiException catch (e) {
      if (gen != _detailGen || _disposed) return;
      _purchasesError = e;
    } finally {
      if (gen == _detailGen && !_disposed) {
        _purchasesLoading = false;
        _notify();
      }
    }
  }

  Future<void> loadMorePurchases() async {
    final id = _detailId;
    if (id == null || _purchases == null || _purchasesLoading) return;
    if (!_purchases!.hasMore) return;
    await _loadPurchases(id, _detailGen, page: _purchases!.pagination.page + 1);
  }

  /// Re-fetches just the purchase summary/history for the currently open
  /// customer, without re-fetching the customer detail itself — the "Retry"
  /// action for a purchase-section-only failure.
  Future<void> retryPurchases() async {
    final id = _detailId;
    if (id == null) return;
    await _loadPurchases(id, _detailGen);
  }

  void closeDetail() {
    _detailId = null;
    _detail = null;
    _detailError = null;
    _purchases = null;
    _purchasesError = null;
    _loyalty = null;
    _loyaltyError = null;
    _detailGen++;
    _notify();
  }

  // ---- create / update ----

  void clearMutationError() {
    if (_mutationError == null) return;
    _mutationError = null;
    _notify();
  }

  Future<Customer?> createCustomer({
    required String fullname,
    required String mobileno,
    String? email,
  }) async {
    if (_mutating) return null;
    _mutating = true;
    _mutationError = null;
    _notify();
    try {
      final c = await _service.create(
        fullname: fullname,
        mobileno: mobileno,
        email: email,
      );
      _items.insert(0, c);
      _total += 1;
      _status = CustomerListStatus.loaded;
      return c;
    } on ApiException catch (e) {
      _mutationError = e;
      return null;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  Future<bool> updateCustomer(
    String customerId, {
    String? fullname,
    String? mobileno,
    Object? email = unsetCustomerField,
  }) async {
    if (_mutating) return false;
    _mutating = true;
    _mutationError = null;
    _notify();
    try {
      final updated = await _service.update(
        customerId,
        fullname: fullname,
        mobileno: mobileno,
        email: email,
      );
      final i = _items.indexWhere((c) => c.customerId == customerId);
      if (i != -1) _items[i] = updated;
      if (_detailId == customerId) _detail = updated;
      return true;
    } on ApiException catch (e) {
      _mutationError = e;
      return false;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _debounceTimer?.cancel();
    super.dispose();
  }
}
