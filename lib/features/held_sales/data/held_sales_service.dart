import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/held_sale_summary.dart';

abstract class HeldSalesService {
  Future<List<HeldSaleSummary>> listHeld();
}

/// Verified against the backend: `GET /sales?status=held`. The store is taken
/// from the token server-side; no company/store parameter is ever sent.
class ApiHeldSalesService implements HeldSalesService {
  ApiHeldSalesService(this._client);
  final PosApiClient _client;

  @override
  Future<List<HeldSaleSummary>> listHeld() async {
    final data = await _client.get('/sales', query: {'status': 'held'});
    return asList(data)
        .map(HeldSaleSummary.fromJson)
        .whereType<HeldSaleSummary>()
        .toList();
  }
}
