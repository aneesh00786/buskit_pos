import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/analytics_summary.dart';

abstract class AnalyticsService {
  /// [from]/[to] are inclusive business dates (YYYY-MM-DD, store time zone);
  /// both or neither — neither means the store's today.
  Future<AnalyticsSummary> getSummary({String? from, String? to});
}

/// Verified against the backend: `GET /analytics/summary` — store-scoped
/// from the device/staff token, never a client-supplied store id.
class ApiAnalyticsService implements AnalyticsService {
  ApiAnalyticsService(this._client);
  final PosApiClient _client;

  @override
  Future<AnalyticsSummary> getSummary({String? from, String? to}) async {
    final data = await _client.get(
      '/analytics/summary',
      query: from != null && to != null ? {'from': from, 'to': to} : null,
    );
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
