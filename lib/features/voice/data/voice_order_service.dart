import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';
import '../../cart/models/cart_sale.dart';

/// Phase 2 — an existing order found by voice: the server's own view of the
/// HELD sale (lines, prices, tax, discounts, total and version), tied to the
/// voice session / request that asked for it.
class VoiceOrderLookup {
  const VoiceOrderLookup({
    required this.voiceSessionId,
    required this.requestId,
    required this.order,
  });
  final String voiceSessionId;
  final String requestId;
  final CartSale order;
}

/// Phase 2.1 — one held order at a table, with what tells it apart.
class TableOrderSummary {
  const TableOrderSummary({
    required this.id,
    required this.version,
    this.heldAt,
    this.itemCount,
    this.grandTotal,
  });
  final int id;
  final int version;
  final DateTime? heldAt;
  final int? itemCount;
  final double? grandTotal;

  static TableOrderSummary? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['id']);
    final version = asInt(m?['version']);
    if (m == null || id == null || version == null) return null;
    return TableOrderSummary(
      id: id,
      version: version,
      heldAt: parseServerTime(m['held_at']),
      itemCount: asInt(m['item_count']),
      grandTotal: asDouble(m['grand_total']),
    );
  }
}

/// Phase 2.1 — the held orders at a table in this store (newest first).
class VoiceTableLookup {
  const VoiceTableLookup({
    required this.voiceSessionId,
    required this.requestId,
    required this.tableRef,
    required this.orders,
  });
  final String voiceSessionId;
  final String requestId;
  final String tableRef;
  final List<TableOrderSummary> orders;
}

/// Phase 2 (Jacky) — existing orders by voice and the voice audit link.
/// Identity and scope are the server's (from the POS token); only the voice
/// session and request ids are sent.
abstract class VoiceOrderService {
  /// `POST /voice/orders/lookup` — a held sale of this store (404 otherwise).
  Future<VoiceOrderLookup> lookup({
    required int orderNumber,
    required String voiceSessionId,
    required String requestId,
  });

  /// Phase 2.1 — `POST /voice/tables/lookup`: the held sales of this store
  /// at [tableRef] (read only; nothing is chosen).
  Future<VoiceTableLookup> lookupTable({
    required String tableRef,
    required String voiceSessionId,
    required String requestId,
  });

  /// `POST /voice/actions/quick-bill` — links a confirmed voice quick bill to
  /// the caller's own current draft (audit only).
  Future<void> linkQuickBill({
    required int saleId,
    required String voiceSessionId,
    required String requestId,
  });
}

class ApiVoiceOrderService implements VoiceOrderService {
  ApiVoiceOrderService(this._client);
  final PosApiClient _client;

  @override
  Future<VoiceOrderLookup> lookup({
    required int orderNumber,
    required String voiceSessionId,
    required String requestId,
  }) async {
    final data = asMap(
      await _client.post(
        '/voice/orders/lookup',
        body: {
          'order_id': orderNumber,
          'voice_session_id': voiceSessionId,
          'request_id': requestId,
        },
      ),
    );
    final order = CartSale.fromJson(data?['order']);
    final session = asString(data?['voice_session_id']);
    final request = asString(data?['request_id']);
    if (order == null || session == null || request == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return VoiceOrderLookup(
      voiceSessionId: session,
      requestId: request,
      order: order,
    );
  }

  @override
  Future<VoiceTableLookup> lookupTable({
    required String tableRef,
    required String voiceSessionId,
    required String requestId,
  }) async {
    final data = asMap(
      await _client.post(
        '/voice/tables/lookup',
        body: {
          'table_ref': tableRef,
          'voice_session_id': voiceSessionId,
          'request_id': requestId,
        },
      ),
    );
    final session = asString(data?['voice_session_id']);
    final request = asString(data?['request_id']);
    final table = asString(data?['table_ref']);
    if (data == null || session == null || request == null || table == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return VoiceTableLookup(
      voiceSessionId: session,
      requestId: request,
      tableRef: table,
      orders: asList(data['orders'])
          .map(TableOrderSummary.fromJson)
          .whereType<TableOrderSummary>()
          .toList(),
    );
  }

  @override
  Future<void> linkQuickBill({
    required int saleId,
    required String voiceSessionId,
    required String requestId,
  }) async {
    await _client.post(
      '/voice/actions/quick-bill',
      body: {
        'sale_id': saleId,
        'voice_session_id': voiceSessionId,
        'request_id': requestId,
      },
    );
  }
}
