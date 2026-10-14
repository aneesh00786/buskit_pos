/// Phase 13B — what a recognized voice request MEANS, before anything is done
/// with it. Only what was said: no product id, price, stock or payment —
/// matching, pricing, permissions and validation stay with the backend
/// (a later phase). Always tied to the voice session and request it came
/// from.
enum VoiceIntentType {
  createQuickBill('CREATE_QUICK_BILL'),
  needsClarification('NEEDS_CLARIFICATION'),
  unknown('UNKNOWN'),

  /// Phase 13G: the session's language has no parser yet — the text is
  /// never interpreted as another language.
  unsupportedLanguage('UNSUPPORTED_LANGUAGE'),

  /// Phase 2 (English): "bill order 1048" — an EXISTING order (a held sale)
  /// by its number ([VoiceIntent.orderNumber]). Looked up by the server.
  billOrder('BILL_ORDER'),

  /// Phase 2.1 (English): "bill table 6" — the held orders at that table
  /// ([VoiceIntent.tableNumber]), looked up by the server; never chosen
  /// automatically when there are several.
  tableOrder('TABLE_ORDER'),

  /// Phase 2 (English): "bill that order" — the order on screen, if any.
  billShownOrder('BILL_SHOWN_ORDER');

  const VoiceIntentType(this.wire);
  final String wire;
}

/// What is missing when an intent needs clarification.
enum ClarificationNeed {
  /// "Bill some coffee" — how many?
  quantity,

  /// "Bill two" / "Bill something" — which product?
  product,

  /// Phase 2: "bill order" — which order number?
  order,
}

/// One requested line, exactly as spoken. [productQuery] / [variantQuery]
/// are search text for a later product match — never an id.
class VoiceIntentItem {
  const VoiceIntentItem({
    required this.spokenText,
    required this.quantity,
    required this.productQuery,
    this.variantQuery,
    this.unit,
  });

  final String spokenText;

  /// Whole number for pieces; a decimal only when spoken (e.g. 1.5 kg).
  final num quantity;
  final String productQuery;
  final String? variantQuery;

  /// Spoken unit (kg, g, l, ml, pack, bottle, box) or null.
  final String? unit;

  Map<String, dynamic> toJson() => {
    'spokenText': spokenText,
    'quantity': quantity,
    'productQuery': productQuery,
    'variantQuery': ?variantQuery,
    'unit': ?unit,
  };
}

class VoiceIntent {
  const VoiceIntent({
    required this.type,
    required this.voiceSessionId,
    required this.requestId,
    required this.recognizedText,
    this.items = const [],
    this.clarification,
    this.need,
    this.orderNumber,
    this.tableNumber,
  });

  final VoiceIntentType type;

  /// Phase 2: BILL_ORDER — the order number as said (never resolved here).
  final int? orderNumber;

  /// Phase 2: TABLE_ORDER — the table number as said.
  final int? tableNumber;

  /// The Phase 13A voice session / request this intent belongs to.
  final String voiceSessionId;
  final String requestId;
  final String recognizedText;

  /// CREATE_QUICK_BILL: the lines. NEEDS_CLARIFICATION: the lines that were
  /// understood (the unclear part is described by [clarification]).
  final List<VoiceIntentItem> items;

  /// A short question / explanation for the cashier ("How many coffee?").
  final String? clarification;
  final ClarificationNeed? need;

  Map<String, dynamic> toJson() => {
    'intent': type.wire,
    'voiceSessionId': voiceSessionId,
    'requestId': requestId,
    'recognizedText': recognizedText,
    'items': [for (final i in items) i.toJson()],
    'clarification': ?clarification,
    'orderNumber': ?orderNumber,
    'tableNumber': ?tableNumber,
  };
}

/// Phase 13E — a spoken correction of the Quick Bill currently on screen
/// ("make it three", "remove the water", "add one more coffee"). Only what
/// was said: the controller matches [target] against the bill's own lines
/// and never guesses; the server re-prices the corrected bill.
enum VoiceCorrectionKind { setQuantity, remove, add, unclear }

class VoiceCorrection {
  const VoiceCorrection._(
    this.kind, {
    this.target,
    this.position,
    this.quantity,
    this.unit,
    this.items = const [],
    this.question,
  });

  /// "make the coffee three" / "make it three" ([target] null = it / that).
  const VoiceCorrection.setQuantity({
    String? target,
    int? position,
    required num quantity,
    String? unit,
  }) : this._(
         VoiceCorrectionKind.setQuantity,
         target: target,
         position: position,
         quantity: quantity,
         unit: unit,
       );

  /// "remove the coffee" / "remove it" / "remove the second item".
  const VoiceCorrection.remove({String? target, int? position})
    : this._(VoiceCorrectionKind.remove, target: target, position: position);

  /// "add one more coffee" / "add one water".
  const VoiceCorrection.add(List<VoiceIntentItem> items)
    : this._(VoiceCorrectionKind.add, items: items);

  /// Recognisably a correction, but not clear enough to act on.
  const VoiceCorrection.unclear(String question)
    : this._(VoiceCorrectionKind.unclear, question: question);

  final VoiceCorrectionKind kind;

  /// The item as said ("coffee", "large coffee"); null = "it" / "that"
  /// (or a [position] was said instead).
  final String? target;

  /// Phase 1 (English): the line by its place on the bill — 1 = "the first
  /// item", 2 = "the second one" / "item 2", -1 = "the last item". Null when
  /// no position was said. Matched against the bill's own lines only.
  final int? position;
  final num? quantity;
  final String? unit;
  final List<VoiceIntentItem> items;
  final String? question;
}

/// Phase 1 (English) — a spoken answer to "Would you like to confirm this
/// bill?". [confirm] / [reject] / [cancel] only for a clear answer; a mix
/// ("yes … no") or a "yes" followed by something else is [unclear] (the
/// controller asks again — never a guess).
enum VoiceReply { confirm, reject, cancel, unclear }
