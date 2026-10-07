import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../models/retail_report.dart';

abstract class ReportService {
  /// [from]/[to]: inclusive business dates (YYYY-MM-DD), both or neither —
  /// neither = the store's today (decided by the server, in its time zone).
  Future<RetailReport> fetch(ReportKind kind, {String? from, String? to});
}

/// `GET /reports/{products|cashiers|registers|tax}` — scope (company / store)
/// comes from the device and staff token on the server; nothing else is sent.
class ApiReportService implements ReportService {
  ApiReportService(this._client);
  final PosApiClient _client;

  @override
  Future<RetailReport> fetch(
    ReportKind kind, {
    String? from,
    String? to,
  }) async {
    final data = await _client.get(
      '/reports/${kind.path}',
      query: from != null && to != null ? {'from': from, 'to': to} : null,
    );
    final report = RetailReport.fromJson(data);
    if (report == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return report;
  }
}
