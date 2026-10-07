import '../../../core/utils/json_read.dart';
import '../intent/voice_intent.dart';

/// Phase 13C-B — the backend's answer to a spoken quick bill
/// (`POST /voice/quick-bill/preview`). Everything priced here comes from the
/// server: the client sends only what was said and never computes, edits or
/// sends a price, tax, product id or company / store scope.
enum QuickBillPreviewStatus {
  ready('READY'),
  needsClarification('NEEDS_CLARIFICATION');

  const QuickBillPreviewStatus(this.wire);
  final String wire;

  static QuickBillPreviewStatus? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }
}

/// One requested line as sent for a preview: what was said, plus — only
/// after the cashier explicitly chose one of the server's candidates
/// (Phase 13D) — that candidate's [productVariationId]. Never a price.
class QuickBillRequestItem {
  const QuickBillRequestItem({
    required this.productQuery,
    required this.quantity,
    this.variantQuery,
    this.unit,
    this.productVariationId,
  });

  factory QuickBillRequestItem.fromIntent(VoiceIntentItem i) =>
      QuickBillRequestItem(
        productQuery: i.productQuery,
        quantity: i.quantity,
        variantQuery: i.variantQuery,
        unit: i.unit,
      );

  final String productQuery;
  final num quantity;
  final String? variantQuery;
  final String? unit;
  final int? productVariationId;

  QuickBillRequestItem withQuantity(num q, {String? unit}) =>
      QuickBillRequestItem(
        productQuery: productQuery,
        quantity: q,
        variantQuery: variantQuery,
        unit: unit ?? this.unit,
        productVariationId: productVariationId,
      );

  QuickBillRequestItem withSelection(int variationId) => QuickBillRequestItem(
    productQuery: productQuery,
    quantity: quantity,
    variantQuery: variantQuery,
    unit: unit,
    productVariationId: variationId,
  );

  Map<String, dynamic> toJson() => {
    'product_query': productQuery,
    'variant_query': ?variantQuery,
    'quantity': quantity,
    'unit': ?unit,
    'product_variation_id': ?productVariationId,
  };
}

/// One preview request: the voice ids it belongs to and the lines. Each
/// correction is a NEW request (same voice session, new request id).
class QuickBillRequest {
  const QuickBillRequest({
    required this.voiceSessionId,
    required this.requestId,
    required this.recognizedText,
    required this.items,
  });

  factory QuickBillRequest.fromIntent(VoiceIntent intent) => QuickBillRequest(
    voiceSessionId: intent.voiceSessionId,
    requestId: intent.requestId,
    recognizedText: intent.recognizedText,
    items: [for (final i in intent.items) QuickBillRequestItem.fromIntent(i)],
  );

  final String voiceSessionId;
  final String requestId;
  final String recognizedText;
  final List<QuickBillRequestItem> items;

  /// The request body: only what was said, the voice ids and any explicit
  /// candidate choice (scope comes from the signed-in session on the server).
  Map<String, dynamic> toJson() => {
    'intent': VoiceIntentType.createQuickBill.wire,
    'voice_session_id': voiceSessionId,
    'request_id': requestId,
    'recognized_text': recognizedText,
    'items': [for (final i in items) i.toJson()],
  };
}

/// The request body for a CREATE_QUICK_BILL intent as first spoken.
Map<String, dynamic> quickBillPreviewBody(VoiceIntent intent) =>
    QuickBillRequest.fromIntent(intent).toJson();

/// One resolved, server-priced line.
class QuickBillLine {
  const QuickBillLine({
    required this.itemIndex,
    required this.productVariationId,
    required this.productName,
    required this.variantName,
    required this.sellingMode,
    required this.quantity,
    required this.unit,
    required this.unitPrice,
    required this.taxPercent,
    required this.taxIncluded,
    required this.lineSubtotal,
    required this.tax,
    required this.lineTotal,
  });

  final int itemIndex;

  /// The variation the SERVER resolved — used only as the identifier for the
  /// existing cart add-item API (Phase 13C-C), never shown.
  final int productVariationId;
  final String productName;
  final String? variantName;
  final String sellingMode;
  final num quantity;
  final String? unit;
  final double unitPrice;
  final double taxPercent;
  final bool taxIncluded;
  final double lineSubtotal;
  final double tax;
  final double lineTotal;

  static QuickBillLine? fromJson(Object? json) {
    final m = asMap(json);
    final name = asString(m?['product_name']);
    final qty = m?['quantity'];
    final price = asDouble(m?['unit_price']);
    final total = asDouble(m?['line_total']);
    final variationId = asInt(m?['product_variation_id']);
    if (m == null ||
        variationId == null ||
        variationId <= 0 ||
        name == null ||
        qty is! num ||
        price == null ||
        total == null) {
      return null;
    }
    return QuickBillLine(
      itemIndex: asInt(m['item_index']) ?? 0,
      productVariationId: variationId,
      productName: name,
      variantName: asString(m['variant_name']),
      sellingMode: asString(m['selling_mode']) ?? 'PIECE',
      quantity: qty,
      unit: asString(m['unit']),
      unitPrice: price,
      taxPercent: asDouble(m['tax_percent']) ?? 0,
      taxIncluded: asBool(m['tax_included']) ?? false,
      lineSubtotal: asDouble(m['line_subtotal']) ?? 0,
      tax: asDouble(m['tax']) ?? 0,
      lineTotal: total,
    );
  }
}

/// A product the backend found for an unclear line. Shown for the cashier
/// to say again more precisely — never chosen automatically.
class QuickBillCandidate {
  const QuickBillCandidate({
    this.productVariationId,
    required this.productName,
    this.variantName,
    this.sellingMode,
  });

  /// Sent back only if the cashier explicitly chooses this candidate.
  final int? productVariationId;
  final String productName;
  final String? variantName;
  final String? sellingMode;

  String get label =>
      variantName == null ? productName : '$productName — $variantName';

  static QuickBillCandidate? fromJson(Object? json) {
    final m = asMap(json);
    final name = asString(m?['product_name']);
    if (name == null) return null;
    final id = asInt(m?['product_variation_id']);
    return QuickBillCandidate(
      productVariationId: id != null && id > 0 ? id : null,
      productName: name,
      variantName: asString(m?['variant_name']),
      sellingMode: asString(m?['selling_mode']),
    );
  }
}

/// A line the backend could not resolve without guessing.
class QuickBillIssue {
  const QuickBillIssue({
    required this.itemIndex,
    required this.code,
    required this.message,
    required this.productQuery,
    this.variantQuery,
    this.candidates = const [],
  });

  final int itemIndex;

  /// PRODUCT_NOT_FOUND, MULTIPLE_PRODUCT_MATCHES, VARIANT_NOT_FOUND, …
  final String code;
  final String message;
  final String productQuery;
  final String? variantQuery;
  final List<QuickBillCandidate> candidates;

  /// What the cashier said for this line ("large coffee").
  String get said =>
      variantQuery == null ? productQuery : '$variantQuery $productQuery';

  static QuickBillIssue? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    return QuickBillIssue(
      itemIndex: asInt(m['item_index']) ?? 0,
      code: asString(m['code']) ?? 'UNKNOWN',
      message: asString(m['message']) ?? 'This item needs to be said again.',
      productQuery: asString(m['product_query']) ?? '',
      variantQuery: asString(m['variant_query']),
      candidates: [
        for (final c in asList(m['candidates']))
          ?QuickBillCandidate.fromJson(c),
      ],
    );
  }
}

class QuickBillPreview {
  const QuickBillPreview({
    required this.status,
    required this.voiceSessionId,
    required this.requestId,
    required this.recognizedText,
    required this.items,
    required this.issues,
    this.subtotal,
    this.tax,
    this.total,
    this.pricingNote,
  });

  final QuickBillPreviewStatus status;
  final String voiceSessionId;
  final String requestId;
  final String recognizedText;
  final List<QuickBillLine> items;
  final List<QuickBillIssue> issues;

  /// Present only when [status] is READY (a partial total would mislead).
  final double? subtotal;
  final double? tax;
  final double? total;
  final String? pricingNote;

  bool get isReady => status == QuickBillPreviewStatus.ready;

  /// Null when the response is not a usable preview (unknown status,
  /// missing ids, a READY bill without totals).
  static QuickBillPreview? fromJson(Object? json) {
    final m = asMap(json);
    final status = QuickBillPreviewStatus.fromWire(asString(m?['status']));
    final sessionId = asString(m?['voice_session_id']);
    final requestId = asString(m?['request_id']);
    if (m == null || status == null || sessionId == null || requestId == null) {
      return null;
    }
    final rawItems = asList(m['items']);
    final items = [for (final i in rawItems) ?QuickBillLine.fromJson(i)];
    final preview = QuickBillPreview(
      status: status,
      voiceSessionId: sessionId,
      requestId: requestId,
      recognizedText: asString(m['recognized_text']) ?? '',
      items: items,
      issues: [
        for (final i in asList(m['issues'])) ?QuickBillIssue.fromJson(i),
      ],
      subtotal: asDouble(m['subtotal']),
      tax: asDouble(m['tax']),
      total: asDouble(m['total']),
      pricingNote: asString(m['pricing_note']),
    );
    if (preview.isReady &&
        (items.length != rawItems.length ||
            items.isEmpty ||
            preview.issues.isNotEmpty ||
            preview.subtotal == null ||
            preview.tax == null ||
            preview.total == null)) {
      return null;
    }
    return preview;
  }
}
