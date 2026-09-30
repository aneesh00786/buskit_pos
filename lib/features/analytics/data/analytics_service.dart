import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/analytics_summary.dart';

abstract class AnalyticsService {
  Future<AnalyticsSummary> getSummary();
}

/// Verified against the backend: `GET /analytics/summary` — store-scoped
/// from the device/staff token, never a client-supplied store id.
class ApiAnalyticsService implements AnalyticsService {
  ApiAnalyticsService(this._client);
  final PosApiClient _client;

  @override
  Future<AnalyticsSummary> getSummary() async {
    final data = await _client.get('/analytics/summary');
    final summary = AnalyticsSummary.fromJson(data);
    if (summary == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return summary;
  }
}
