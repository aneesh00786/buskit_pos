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
  unsupportedLanguage('UNSUPPORTED_LANGUAGE');

  const VoiceIntentType(this.wire);
  final String wire;
}

/// What is missing when an intent needs clarification.
enum ClarificationNeed {
  /// "Bill some coffee" — how many?
  quantity,

  /// "Bill two" / "Bill something" — which product?
  product,
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
  });

  final VoiceIntentType type;

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
    this.quantity,
    this.unit,
    this.items = const [],
    this.question,
  });

  /// "make the coffee three" / "make it three" ([target] null = it / that).
  const VoiceCorrection.setQuantity({
    String? target,
    required num quantity,
    String? unit,
  }) : this._(
         VoiceCorrectionKind.setQuantity,
         target: target,
         quantity: quantity,
         unit: unit,
       );

  /// "remove the coffee" / "remove it".
  const VoiceCorrection.remove({String? target})
    : this._(VoiceCorrectionKind.remove, target: target);

  /// "add one more coffee" / "add one water".
  const VoiceCorrection.add(List<VoiceIntentItem> items)
    : this._(VoiceCorrectionKind.add, items: items);

  /// Recognisably a correction, but not clear enough to act on.
  const VoiceCorrection.unclear(String question)
    : this._(VoiceCorrectionKind.unclear, question: question);

  final VoiceCorrectionKind kind;

  /// The item as said ("coffee", "large coffee"); null = "it" / "that".
  final String? target;
  final num? quantity;
  final String? unit;
  final List<VoiceIntentItem> items;
  final String? question;
}
