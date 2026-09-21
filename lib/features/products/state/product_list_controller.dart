import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../data/product_service.dart';
import '../models/category.dart';
import '../models/product_group.dart';
import '../models/product_item.dart';

enum ListStatus { idle, loading, loaded, empty, error }

/// How the LOADED products are ordered on screen.
///
/// The backend (`GET /products`) has no sort parameter; it always returns rows
/// ordered by product name then variation name, page after page. So
/// [serverOrder] is already A–Z across the whole catalog, while [nameAsc] and
/// [nameDesc] are LOCAL re-orderings of only the pages loaded so far.
enum ProductSort { serverOrder, nameAsc, nameDesc }

/// State for the product browser: paginated listing, debounced search and
/// category filtering.
///
/// Concurrency rules:
///  * every change of query/category starts a new "generation"; responses
///    from an older generation are discarded, so a slow earlier request can
///    never overwrite newer results or corrupt the page counter;
///  * an identical first-page request already in flight is not duplicated;
///  * only one "load more" runs at a time;
///  * nothing is retried automatically — retry is an explicit user action.
class ProductListController extends ChangeNotifier {
  ProductListController(
    this._service, {
    this.debounce = const Duration(milliseconds: 350),
    this.pageSize = 20,
    this.onUnauthorized,
  });

  final ProductService _service;
  final Duration debounce;
  final int pageSize;
  final VoidCallback? onUnauthorized;

  ListStatus _status = ListStatus.idle;
  final List<ProductItem> _items = [];
  List<ProductGroup> _groups = const [];
  ProductSort _sort = ProductSort.serverOrder;
  bool _loadingAll = false;
  int _page = 0;
  int _totalPages = 1;
  int _total = 0;
  bool _loadingMore = false;
  ApiException? _error;
  ApiException? _loadMoreError;

  String _query = '';
  int? _categoryId;
  Timer? _debounceTimer;
  int _generation = 0;
  String? _firstPageInFlightKey;
  bool _disposed = false;

  List<ProductCategory> _categories = const [];
  bool _categoriesLoading = false;
  ApiException? _categoriesError;

  ListStatus get status => _status;
  List<ProductItem> get items => List.unmodifiable(_items);
  List<ProductGroup> get groups => _groups;
  ProductSort get sort => _sort;

  /// True while a local A–Z / Z–A order is applied to a partial result: more
  /// pages exist on the server, so the order covers only what is loaded.
  bool get sortIsPartial => _sort != ProductSort.serverOrder && hasMore;

  /// Variation rows loaded so far (the server's `total` counts the same rows).
  int get loadedCount => _items.length;
  bool get isLoadingAll => _loadingAll;
  int get total => _total;
  bool get hasMore => _page > 0 && _page < _totalPages;
  bool get loadingMore => _loadingMore;
  ApiException? get error => _error;
  ApiException? get loadMoreError => _loadMoreError;
  String get query => _query;
  int? get categoryId => _categoryId;
  List<ProductCategory> get categories => _categories;
  bool get categoriesLoading => _categoriesLoading;
  ApiException? get categoriesError => _categoriesError;

  // ---- categories ----

  Future<void> loadCategories() async {
    if (_categoriesLoading) return;
    _categoriesLoading = true;
    _categoriesError = null;
    _notify();
    try {
      _categories = await _service.categories();
    } on ApiException catch (e) {
      _categoriesError = e;
      _handleAuth(e);
    } finally {
      _categoriesLoading = false;
      _notify();
    }
  }

  // ---- listing ----

  Future<void> loadInitial() => _loadFirstPage();

  /// Explicit retry after an error (or pull-to-refresh). Ignored while the
  /// same request is already running.
  Future<void> retry() => _loadFirstPage();

  /// Called on every keystroke; the search runs after [debounce] of quiet.
  void onQueryChanged(String text) {
    final next = text.trim();
    _debounceTimer?.cancel();
    if (next == _query) return;
    _debounceTimer = Timer(debounce, () {
      _query = next;
      _loadFirstPage();
    });
  }

  /// Runs the search immediately (keyboard "search" action, scanner input).
  Future<void> submitQuery(String text) {
    _debounceTimer?.cancel();
    _query = text.trim();
    return _loadFirstPage();
  }

  Future<void> selectCategory(int? id) {
    if (id == _categoryId) return Future.value();
    _categoryId = id;
    return _loadFirstPage();
  }

  Future<void> _loadFirstPage() async {
    final key = '$_query|${_categoryId ?? ''}';
    if (_status == ListStatus.loading && _firstPageInFlightKey == key) return;

    final gen = ++_generation;
    _firstPageInFlightKey = key;
    _status = ListStatus.loading;
    _error = null;
    _loadMoreError = null;
    _loadingMore = false;
    _items.clear();
    _groups = const [];
    _page = 0;
    _totalPages = 1;
    _total = 0;
    _notify();

    try {
      final res = await _service.search(
        query: _query,
        categoryId: _categoryId,
        page: 1,
        limit: pageSize,
      );
      if (gen != _generation) return; // superseded by a newer query
      _items.addAll(res.items);
      _groups = _buildGroups();
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
      _total = res.pagination.total;
      _status = _items.isEmpty ? ListStatus.empty : ListStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      _status = ListStatus.error;
      _handleAuth(e);
    } finally {
      if (gen == _generation) _firstPageInFlightKey = null;
      _notify();
    }
  }

  Future<void> loadNextPage() async {
    if (_status != ListStatus.loaded || _loadingMore || !hasMore) return;
    final gen = _generation;
    final nextPage = _page + 1;
    _loadingMore = true;
    _loadMoreError = null;
    _notify();
    try {
      final res = await _service.search(
        query: _query,
        categoryId: _categoryId,
        page: nextPage,
        limit: pageSize,
      );
      if (gen != _generation) return;
      final known = _items.map((i) => i.id).toSet();
      _items.addAll(res.items.where((i) => !known.contains(i.id)));
      _groups = _buildGroups();
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
      _total = res.pagination.total;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _loadMoreError = e; // keep what is already on screen
      _handleAuth(e);
    } finally {
      if (gen == _generation) _loadingMore = false;
      _notify();
    }
  }

  /// Changes the local ordering. It never issues a request, never resets the
  /// page counter, and never touches in-flight loads (the generation guard is
  /// about query/category, not order), so it is safe alongside search,
  /// category filtering, pagination and stale-response protection.
  void setSort(ProductSort next) {
    if (next == _sort) return;
    _sort = next;
    _groups = _buildGroups();
    _notify();
  }

  List<ProductGroup> _buildGroups() {
    final groups = ProductGroup.group(_items);
    if (_sort == ProductSort.serverOrder) return groups;
    final desc = _sort == ProductSort.nameDesc;
    groups.sort((a, b) {
      final c = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      if (c != 0) return desc ? -c : c;
      return a.first.id.compareTo(b.first.id); // deterministic ties
    });
    return groups;
  }

  /// Loads every remaining page (on demand) so a local sort covers the whole
  /// result. Stops on the first error, if the query changes underneath it, or
  /// after [maxPages] pages.
  Future<void> loadRemaining({int maxPages = 100}) async {
    if (_loadingAll || _status != ListStatus.loaded) return;
    _loadingAll = true;
    _notify();
    final gen = _generation;
    var pages = 0;
    var spins = 0;
    try {
      while (_status == ListStatus.loaded &&
          hasMore &&
          pages < maxPages &&
          gen == _generation &&
          _loadMoreError == null &&
          spins < maxPages * 50) {
        if (_loadingMore) {
          spins++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          continue;
        }
        pages++;
        await loadNextPage();
      }
    } finally {
      _loadingAll = false;
      _notify();
    }
  }

  void _handleAuth(ApiException e) {
    if (e.isUnauthorized) onUnauthorized?.call();
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
