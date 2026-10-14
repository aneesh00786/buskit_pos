import '../../core/network/api_exception.dart';
import '../../core/network/pos_api_client.dart';
import '../../core/utils/json_read.dart';
import '../cart/models/cart_sale.dart';

/// Supermarket scale labels (backend migration 054). The till only needs to
/// RECOGNISE a label — same length as an active format and one of its
/// prefixes; the SERVER parses it, checks the check digit, finds the product
/// from the PLU, and prices the weight. The till never sends a weight or a
/// price for a label, only the scanned barcode.
///
/// No format is built in: with no active format configured by an
/// administrator, nothing is recognised and every scan takes the ordinary
/// barcode path exactly as before.
class ScaleLabelFormat {
  const ScaleLabelFormat({
    required this.id,
    required this.barcodeLength,
    required this.prefixes,
  });

  final int id;
  final int barcodeLength;
  final List<String> prefixes;

  bool matches(String code) =>
      code.length == barcodeLength && prefixes.any(code.startsWith);

  static ScaleLabelFormat? fromJson(Object? json) {
    final m = asMap(json);
    final id = asInt(m?['id']);
    final length = asInt(m?['barcode_length']);
    final prefixes = asList(m?['prefixes'])
        .map(asString)
        .whereType<String>()
        .where((p) => p.isNotEmpty)
        .toList();
    if (id == null || length == null || length < 2 || prefixes.isEmpty) {
      return null;
    }
    return ScaleLabelFormat(id: id, barcodeLength: length, prefixes: prefixes);
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'barcode_length': barcodeLength,
    'prefixes': prefixes,
  };
}

/// The active formats of this store (from `GET /scale-labels/formats`).
class ScaleLabelConfig {
  const ScaleLabelConfig({
    this.formats = const [],
    this.weightSalesEnabled = false,
  });

  static const none = ScaleLabelConfig();

  final List<ScaleLabelFormat> formats;
  final bool weightSalesEnabled;

  bool matches(String code) => formats.any((f) => f.matches(code));

  static ScaleLabelConfig fromJson(Object? json) {
    final m = asMap(json);
    return ScaleLabelConfig(
      weightSalesEnabled: m?['weight_sales_enabled'] == true,
      formats: asList(m?['formats'])
          .map(ScaleLabelFormat.fromJson)
          .whereType<ScaleLabelFormat>()
          .toList(),
    );
  }

  Map<String, Object?> toJson() => {
    'weight_sales_enabled': weightSalesEnabled,
    'formats': [for (final f in formats) f.toJson()],
  };
}

/// What the server read from a label it added (shown to the cashier).
class ScaleLabelLine {
  const ScaleLabelLine({
    required this.productName,
    required this.weightKg,
    required this.lineTotal,
    this.unitPrice,
    this.labelPrice,
    this.plu,
  });

  final String productName;
  final num weightKg;
  final num lineTotal;
  final num? unitPrice;

  /// The printed price of a PRICE label (never what is charged).
  final num? labelPrice;
  final String? plu;

  static ScaleLabelLine? fromJson(Object? json) {
    final m = asMap(json);
    final product = asMap(m?['product']);
    final name = asString(product?['product_name']);
    final weight = asDouble(m?['weight_kg']);
    final total = asDouble(m?['line_total']);
    if (name == null || weight == null || total == null) return null;
    return ScaleLabelLine(
      productName: name,
      weightKg: weight,
      lineTotal: total,
      unitPrice: asDouble(m?['unit_price']),
      labelPrice: asDouble(m?['label_price']),
      plu: asString(m?['plu']),
    );
  }
}

abstract class ScaleLabelService {
  Future<ScaleLabelConfig> loadFormats();

  /// `POST /scale-labels/resolve` — what the server reads from the label,
  /// without adding anything (used before a sale exists, so a refused label
  /// never opens an empty sale).
  Future<ScaleLabelLine?> resolve(String barcode);

  /// `POST /sales/:id/items/scale-label` — the refreshed sale and what the
  /// server read from the label.
  Future<(CartSale, ScaleLabelLine?)> addToSale({
    required int saleId,
    required String barcode,
    required int expectedVersion,
    bool confirmRepeat = false,
  });
}

class ApiScaleLabelService implements ScaleLabelService {
  ApiScaleLabelService(this._client);
  final PosApiClient _client;

  @override
  Future<ScaleLabelConfig> loadFormats() async =>
      ScaleLabelConfig.fromJson(await _client.get('/scale-labels/formats'));

  @override
  Future<ScaleLabelLine?> resolve(String barcode) async =>
      ScaleLabelLine.fromJson(
        await _client.post('/scale-labels/resolve', body: {'barcode': barcode}),
      );

  @override
  Future<(CartSale, ScaleLabelLine?)> addToSale({
    required int saleId,
    required String barcode,
    required int expectedVersion,
    bool confirmRepeat = false,
  }) async {
    final data = await _client.post(
      '/sales/$saleId/items/scale-label',
      body: {
        'barcode': barcode,
        'expected_version': expectedVersion,
        if (confirmRepeat) 'confirm_repeat': true,
      },
    );
    final sale = CartSale.fromJson(data);
    if (sale == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return (sale, ScaleLabelLine.fromJson(asMap(data)?['scale_label']));
  }
}

/// Keeps this store's active formats for recognising scans. Loaded from the
/// server when online (at most every [maxAge]); the last copy is kept on the
/// device ([save] / [restore]) so that a label scanned offline — even after a
/// restart — is recognised and refused clearly instead of looked up as an
/// ordinary barcode.
class ScaleLabelRecognizer {
  ScaleLabelRecognizer(
    this.service, {
    this.save,
    this.restore,
    this.maxAge = const Duration(minutes: 5),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final ScaleLabelService service;
  final Future<void> Function(Map<String, Object?> json)? save;
  final Future<Map<String, dynamic>?> Function()? restore;
  final Duration maxAge;
  final DateTime Function() _clock;

  ScaleLabelConfig _config = ScaleLabelConfig.none;
  DateTime? _loadedAt;
  bool _restored = false;

  ScaleLabelConfig get config => _config;

  /// Whether [code] is a scale label of an active format. [online] decides
  /// whether the formats may be refreshed from the server first.
  Future<bool> matches(String code, {required bool online}) async {
    final stale = _loadedAt == null || _clock().difference(_loadedAt!) > maxAge;
    if (online && stale) {
      try {
        _config = await service.loadFormats();
        _loadedAt = _clock();
        await save?.call(_config.toJson());
      } on Object {
        // Unknown: keep what we have (the server still decides every label).
      }
    }
    if (_loadedAt == null && !_restored) {
      _restored = true;
      try {
        final json = await restore?.call();
        if (json != null) _config = ScaleLabelConfig.fromJson(json);
      } on Object {
        // No saved copy: nothing is recognised offline.
      }
    }
    return _config.matches(code);
  }
}
