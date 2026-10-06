import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../checkout/models/payment.dart';
import '../models/partial_refund.dart';
import '../models/sale_history_entry.dart';

abstract class SalesHistoryService {
  /// `GET /sales?status=completed` — the store is taken from the device
  /// token server-side. [todayOnly] asks for the store's current business
  /// day only (`range=today`); [limit] / [beforeId] page the history newest
  /// first (`limit`, `before_id`). Search, cashier and payment-method
  /// filters are still applied client-side over the loaded rows (see
  /// [SalesHistoryController]).
  Future<List<SaleHistoryEntry>> listCompleted({
    bool todayOnly = false,
    int? limit,
    int? beforeId,
  });

  /// `GET /sales/:id` — items, payments and totals for one completed sale
  /// (no product names; the completed view never carries them).
  /// With [refresh], the server first reconciles the sale's pending provider
  /// refunds (`GET /sales/:id?refresh=true`).
  Future<CompletedSale?> getDetail(int id, {bool refresh = false});

  /// `POST /sales/:id/refund {idempotency_key}` — FULL-SALE REFUND ONLY.
  /// Requires the `payments.refund` permission server-side; the backend
  /// never changes `status` (stays 'completed'). Returns the same shape as
  /// [getDetail], now carrying a non-null `refund`.
  Future<CompletedSale?> refundSale({
    required int saleId,
    required String idempotencyKey,
  });

  /// `POST /sales/:id/refunds/preview` — the server's calculation for a
  /// quantity-based partial refund (Phase 17.8). Writes nothing.
  Future<RefundPreview?> previewRefund({
    required int saleId,
    required List<RefundRequestLine> lines,
    String? refundMethod,
  });

  /// `POST /sales/:id/refunds` — records a partial refund. The server
  /// rejects it (409) if its amount no longer equals [expectedRefundAmount]
  /// (the previewed figure the cashier confirmed).
  Future<PartialRefundResult> refundItems({
    required int saleId,
    required List<RefundRequestLine> lines,
    required double expectedRefundAmount,
    required String idempotencyKey,
    String? refundMethod,
    String? reason,
  });
}

/// `POST /sales/:id/refunds`'s response: the recorded refund and the sale as
/// the server now reports it.
class PartialRefundResult {
  const PartialRefundResult({this.refund, this.sale});
  final PartialRefund? refund;
  final CompletedSale? sale;
}

class ApiSalesHistoryService implements SalesHistoryService {
  ApiSalesHistoryService(this._client);
  final PosApiClient _client;

  @override
  Future<List<SaleHistoryEntry>> listCompleted({
    bool todayOnly = false,
    int? limit,
    int? beforeId,
  }) async {
    final data = await _client.get(
      '/sales',
      query: {
        'status': 'completed',
        if (todayOnly) 'range': 'today',
        if (limit != null) 'limit': '$limit',
        if (beforeId != null) 'before_id': '$beforeId',
      },
    );
    return asList(data)
        .map(SaleHistoryEntry.fromJson)
        .whereType<SaleHistoryEntry>()
        .toList();
  }

  @override
  Future<CompletedSale?> getDetail(int id, {bool refresh = false}) async {
    final data = await _client.get('/sales/$id', query: refresh ? const {'refresh': 'true'} : null);
    return CompletedSale.fromJson(data);
  }

  @override
  Future<CompletedSale?> refundSale({
    required int saleId,
    required String idempotencyKey,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/refund',
      body: {'idempotency_key': idempotencyKey},
    );
    return CompletedSale.fromJson(data);
  }

  @override
  Future<RefundPreview?> previewRefund({
    required int saleId,
    required List<RefundRequestLine> lines,
    String? refundMethod,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/refunds/preview',
      body: {
        'items': [for (final l in lines) l.toJson()],
        'refund_method': ?refundMethod,
      },
    );
    return RefundPreview.fromJson(data);
  }

  @override
  Future<PartialRefundResult> refundItems({
    required int saleId,
    required List<RefundRequestLine> lines,
    required double expectedRefundAmount,
    required String idempotencyKey,
    String? refundMethod,
    String? reason,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/refunds',
      body: {
        'items': [for (final l in lines) l.toJson()],
        'expected_refund_amount': expectedRefundAmount,
        'idempotency_key': idempotencyKey,
        'refund_method': ?refundMethod,
        if (reason != null && reason.trim().isNotEmpty) 'reason': reason.trim(),
      },
    );
    final m = asMap(data);
    return PartialRefundResult(
      refund: PartialRefund.fromJson(m?['refund']),
      sale: CompletedSale.fromJson(m?['sale']),
    );
  }
}
