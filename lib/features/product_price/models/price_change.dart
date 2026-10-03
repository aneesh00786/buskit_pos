import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';

/// One immutable POS price change (`pos_product_price_changes`).
class PriceChange {
  const PriceChange({
    required this.id,
    required this.action,
    required this.previousPrice,
    required this.previousSource,
    required this.newPrice,
    required this.newSource,
    this.reason,
    this.salesmanId,
    this.createdAt,
  });

  final int id;

  /// 'set' or 'reset'.
  final String action;
  final double previousPrice;
  final String previousSource;
  final double newPrice;
  final String newSource;
  final String? reason;
  final String? salesmanId;
  final DateTime? createdAt;

  static PriceChange? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final action = asString(m['action']);
    final prev = asDouble(m['previous_price']);
    final next = asDouble(m['new_price']);
    if (id == null || action == null || prev == null || next == null) {
      return null;
    }
    return PriceChange(
      id: id,
      action: action,
      previousPrice: prev,
      previousSource: asString(m['previous_source']) ?? 'catalogue',
      newPrice: next,
      newSource: asString(m['new_source']) ?? 'pos',
      reason: asString(m['reason']),
      salesmanId: asString(m['salesman_id']),
      createdAt: parseServerTime(m['created_at']),
    );
  }
}

/// The server's price state after a change, or with its history.
class ProductPriceState {
  const ProductPriceState({
    required this.sellPrice,
    required this.cataloguePrice,
    required this.priceSource,
    required this.priceVersion,
    this.change,
    this.history = const [],
  });

  final double sellPrice;
  final double cataloguePrice;
  final String priceSource;
  final int priceVersion;
  final PriceChange? change;
  final List<PriceChange> history;

  static ProductPriceState? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final sell = asDouble(m['sell_price']);
    final cat = asDouble(m['catalogue_price']);
    if (sell == null || cat == null) return null;
    return ProductPriceState(
      sellPrice: sell,
      cataloguePrice: cat,
      priceSource: asString(m['price_source']) ?? 'catalogue',
      priceVersion: asInt(m['price_version']) ?? 0,
      change: PriceChange.fromJson(m['change']),
      history: asList(m['items'])
          .map(PriceChange.fromJson)
          .whereType<PriceChange>()
          .toList(),
    );
  }
}
