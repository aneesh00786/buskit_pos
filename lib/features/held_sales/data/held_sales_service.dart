import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../cart/models/cart_sale.dart';
import '../../../core/utils/json_read.dart';
import '../models/held_sale_summary.dart';

abstract class HeldSalesService {
  Future<List<HeldSaleSummary>> listHeld();

  /// Phase 2.1 — `PATCH /sales/:id/table {expected_version, table_ref}`:
  /// assigns, changes or (null) clears the table of a held sale. Version
  /// checked by the server; returns the sale view.
  Future<CartSale> setTable({
    required int saleId,
    required int expectedVersion,
    required String? tableRef,
  });
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

  @override
  Future<CartSale> setTable({
    required int saleId,
    required int expectedVersion,
    required String? tableRef,
  }) async {
    final data = await _client.patch(
      '/sales/$saleId/table',
      body: {'expected_version': expectedVersion, 'table_ref': tableRef},
    );
    final sale = CartSale.fromJson(data);
    if (sale == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return sale;
  }
}
