import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../checkout/models/payment.dart';
import '../models/sale_history_entry.dart';

abstract class SalesHistoryService {
  /// `GET /sales?status=completed` — the store is taken from the device
  /// token server-side; no date range, search, cashier or payment-method
  /// filter exists on the backend, so those are applied client-side over
  /// this list (see [SalesHistoryController]).
  Future<List<SaleHistoryEntry>> listCompleted();

  /// `GET /sales/:id` — items, payments and totals for one completed sale
  /// (no product names; the completed view never carries them).
  Future<CompletedSale?> getDetail(int id);
}

class ApiSalesHistoryService implements SalesHistoryService {
  ApiSalesHistoryService(this._client);
  final PosApiClient _client;

  @override
  Future<List<SaleHistoryEntry>> listCompleted() async {
    final data = await _client.get('/sales', query: {'status': 'completed'});
    return asList(data)
        .map(SaleHistoryEntry.fromJson)
        .whereType<SaleHistoryEntry>()
        .toList();
  }

  @override
  Future<CompletedSale?> getDetail(int id) async {
    final data = await _client.get('/sales/$id');
    return CompletedSale.fromJson(data);
  }
}
