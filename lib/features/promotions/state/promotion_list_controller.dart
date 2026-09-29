import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../data/promotion_service.dart';
import '../models/promotion.dart';

enum PromotionListStatus { idle, loading, loaded, empty, error }

/// Read-only browse list (server-paginated) + a selected promotion's detail.
/// There is no create/edit/delete/activate anywhere — promotions are defined
/// entirely by the existing Admin/Web system; POS only ever displays them.
/// Detail is just the already-fetched [Promotion] object (the list response
/// already carries every field POS can show — no separate detail endpoint).
class PromotionListController extends ChangeNotifier {
  PromotionListController(this._service, {this.pageSize = 20});

  final PromotionService _service;
  final int pageSize;

  PromotionListStatus _status = PromotionListStatus.idle;
  final List<Promotion> _items = [];
  int _page = 0;
  int _totalPages = 1;
  bool _loadingMore = false;
  ApiException? _error;
  ApiException? _loadMoreError;
  int _generation = 0;
  bool _disposed = false;

  Promotion? _selected;

  PromotionListStatus get status => _status;
  List<Promotion> get items => List.unmodifiable(_items);
  bool get hasMore => _page > 0 && _page < _totalPages;
  bool get loadingMore => _loadingMore;
  ApiException? get error => _error;
  ApiException? get loadMoreError => _loadMoreError;
  Promotion? get selected => _selected;

  Future<void> loadInitial() => _loadFirstPage();
  Future<void> retry() => _loadFirstPage();

  void select(Promotion promotion) {
    _selected = promotion;
    _notify();
  }

  void closeDetail() {
    _selected = null;
    _notify();
  }

  Future<void> _loadFirstPage() async {
    final gen = ++_generation;
    _status = PromotionListStatus.loading;
    _error = null;
    _loadMoreError = null;
    _loadingMore = false;
    _items.clear();
    _page = 0;
    _totalPages = 1;
    _notify();

    try {
      final res = await _service.listPromotions(page: 1, limit: pageSize);
      if (gen != _generation) return;
      _items.addAll(res.items);
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
      _status = _items.isEmpty
          ? PromotionListStatus.empty
          : PromotionListStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      _status = PromotionListStatus.error;
    } finally {
      _notify();
    }
  }

  Future<void> loadNextPage() async {
    if (_status != PromotionListStatus.loaded || _loadingMore || !hasMore) {
      return;
    }
    final gen = _generation;
    final nextPage = _page + 1;
    _loadingMore = true;
    _loadMoreError = null;
    _notify();
    try {
      final res = await _service.listPromotions(
        page: nextPage,
        limit: pageSize,
      );
      if (gen != _generation) return;
      final known = _items.map((p) => p.id).toSet();
      _items.addAll(res.items.where((p) => !known.contains(p.id)));
      _page = res.pagination.page;
      _totalPages = res.pagination.totalPages;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _loadMoreError = e;
    } finally {
      if (gen == _generation) _loadingMore = false;
      _notify();
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
