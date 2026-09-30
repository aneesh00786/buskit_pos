import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../data/analytics_service.dart';
import '../models/analytics_summary.dart';

enum AnalyticsStatus { idle, loading, loaded, error }

/// A single read (`GET /analytics/summary`) — no pagination, no mutation.
/// Also used by `SalesSummaryPanel` on the products page, so both surfaces
/// show exactly the same numbers from one load.
class AnalyticsController extends ChangeNotifier {
  AnalyticsController(this._service);
  final AnalyticsService _service;

  AnalyticsStatus _status = AnalyticsStatus.idle;
  AnalyticsSummary? _summary;
  ApiException? _error;
  int _generation = 0;
  bool _disposed = false;

  AnalyticsStatus get status => _status;
  AnalyticsSummary? get summary => _summary;
  ApiException? get error => _error;

  Future<void> load() async {
    final gen = ++_generation;
    _status = AnalyticsStatus.loading;
    _error = null;
    _notify();
    try {
      final result = await _service.getSummary();
      if (gen != _generation) return;
      _summary = result;
      _status = AnalyticsStatus.loaded;
    } on ApiException catch (e) {
      if (gen != _generation) return;
      _error = e;
      _status = AnalyticsStatus.error;
    } finally {
      _notify();
    }
  }

  Future<void> retry() => load();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
