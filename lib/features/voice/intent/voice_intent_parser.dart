import '../models/voice_language.dart';
import 'voice_intent.dart';

part 'malayalam_parser.dart';

/// Phase 13B — turns recognized text into a [VoiceIntent]. Behind this small
/// interface so a later phase can replace or extend the interpretation (e.g.
/// an AI provider) without changing the voice controller. Asynchronous for
/// that reason, though the rule-based parser below is not.
abstract class VoiceIntentParser {
  /// Phase 13G: [language] is the voice session's language. A parser that
  /// does not implement it returns UNSUPPORTED_LANGUAGE (never a guess).
  Future<VoiceIntent> parse(
    String recognizedText, {
    required String voiceSessionId,
    required String requestId,
    VoiceLanguage language = VoiceLanguage.english,
  });
}

/// Deterministic, rule-based interpretation of short quick-bill commands:
///
///   "bill two large coffees and three waters"
///   "quick bill 2 coffee, 1 tea"      "two coffees and a water"
///   "bill 1.5 kg rice"
///
/// It never guesses: a missing or vague quantity or product is
/// NEEDS_CLARIFICATION, anything else UNKNOWN. It extracts only what was
/// said — no product id, price, stock or payment.
class RuleBasedIntentParser implements VoiceIntentParser {
  const RuleBasedIntentParser();

  static const maxQuantity = 9999;

  /// The assistant's name, accepted (once) in front of a command.
  static const assistantName = 'jacky';

  static const _triggers = [
    ['quick', 'bill'],
    ['bill'],
    ['ring', 'up'],
    ['charge'],
  ];

  static const _ones = {
    'a': 1,
    'an': 1,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
    'ten': 10,
    'eleven': 11,
    'twelve': 12,
    'thirteen': 13,
    'fourteen': 14,
    'fifteen': 15,
    'sixteen': 16,
    'seventeen': 17,
    'eighteen': 18,
    'nineteen': 19,
  };
  static const _tens = {
    'twenty': 20,
    'thirty': 30,
    'forty': 40,
    'fifty': 50,
    'sixty': 60,
    'seventy': 70,
    'eighty': 80,
    'ninety': 90,
  };

  /// Quantity words that do not say how many ("some coffee").
  static const _vagueQuantities = {
    'some',
    'few',
    'several',
    'many',
    'more',
    'couple',
    'lots',
    'bunch',
  };

  /// Product words that do not say which product.
  static const _vagueProducts = {
    'something',
    'anything',
    'stuff',
    'thing',
    'things',
    'item',
    'items',
    'it',
    'that',
    'this',
    'them',
    'one',
    'ones',
  };

  static const _variants = {
    'small',
    'medium',
    'large',
    'regular',
    'big',
    'extra',
    'hot',
    'cold',
    'iced',
  };

  static const _units = {
    'kg': 'kg',
    'kgs': 'kg',
    'kilo': 'kg',
    'kilos': 'kg',
    'kilogram': 'kg',
    'kilograms': 'kg',
    'g': 'g',
    'gm': 'g',
    'gms': 'g',
    'gram': 'g',
    'grams': 'g',
    'l': 'l',
    'litre': 'l',
    'litres': 'l',
    'liter': 'l',
    'liters': 'l',
    'ml': 'ml',
    'pack': 'pack',
    'packs': 'pack',
    'packet': 'pack',
    'packets': 'pack',
    'bottle': 'bottle',
    'bottles': 'bottle',
    'box': 'box',
    'boxes': 'box',
  };

  static const _fillers = {'of', 'the', 'please', 'pls', 'x'};

  /// The languages this parser implements.
  static const languages = [VoiceLanguage.english, VoiceLanguage.malayalam];

  @override
  Future<VoiceIntent> parse(
    String recognizedText, {
    required String voiceSessionId,
    required String requestId,
    VoiceLanguage language = VoiceLanguage.english,
  }) async {
    VoiceIntent make(
      VoiceIntentType type, {
      List<VoiceIntentItem> items = const [],
      String? clarification,
      ClarificationNeed? need,
    }) => VoiceIntent(
      type: type,
      voiceSessionId: voiceSessionId,
      requestId: requestId,
      recognizedText: recognizedText,
      items: items,
      clarification: clarification,
      need: need,
    );

    // Phase 13G: each language uses its own grammar; one without a parser
    // is never interpreted as another language.
    if (!languages.contains(language)) {
      return make(VoiceIntentType.unsupportedLanguage);
    }
    if (language == VoiceLanguage.malayalam) {
      return _Malayalam.intent(recognizedText, make); // Phase 13H
    }
    final words = _normalize(recognizedText);
    if (words.isEmpty) return make(VoiceIntentType.unknown);

    var rest = words;
    // Phase 13D: "Jacky, bill two coffees" = "bill two coffees". The name is
    // only how the operator addresses the assistant (one exact word, any
    // case); "Jacky" alone is not a command.
    if (rest.first == assistantName) {
      rest = rest.sublist(1);
      // "Jacky, bill …": the comma was normalized to "and".
      if (rest.isNotEmpty && rest.first == 'and') rest = rest.sublist(1);
      if (rest.isEmpty) return make(VoiceIntentType.unknown);
    }
    var triggered = false;
    for (final t in _triggers) {
      if (rest.length >= t.length && _startsWith(rest, t)) {
        rest = rest.sublist(t.length);
        triggered = true;
        break;
      }
    }
    if (triggered && rest.isEmpty) {
      return make(
        VoiceIntentType.needsClarification,
        clarification: 'What should be billed? Which product?',
        need: ClarificationNeed.product,
      );
    }

    final segments = _segments(rest);
    final parsed = segments.map(_item).toList();
    // Without "bill", only an utterance made entirely of clear items
    // ("two coffees and a tea") is taken as a quick bill.
    if (!triggered &&
        (parsed.any((p) => p.item == null) ||
            segments.any((seg) => !_explicitNumber(seg[0])))) {
      return make(VoiceIntentType.unknown);
    }
    final items = [for (final p in parsed) ?p.item];
    final unclear = parsed.where((p) => p.item == null).firstOrNull;
    if (unclear != null) {
      return make(
        VoiceIntentType.needsClarification,
        items: items,
        clarification: unclear.question,
        need: unclear.need,
      );
    }
    return make(VoiceIntentType.createQuickBill, items: items);
  }

  // ---------------------------------------------------------------------

  /// A number said outright ("2", "two", "twenty") — not "a" / "an", which
  /// only count as one after a command word ("bill a coffee").
  static bool _explicitNumber(String w) =>
      RegExp(r'^\d').hasMatch(w) ||
      _tens.containsKey(w) ||
      (_ones.containsKey(w) && w != 'a' && w != 'an');

  static List<String> _normalize(String text) => text
      .toLowerCase()
      .replaceAll('&', ' and ')
      .replaceAll(',', ' and ')
      .replaceAll(RegExp(r'[^a-z0-9.\s]'), ' ')
      .replaceAll(RegExp(r'\.(?!\d)'), ' ')
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();

  static bool _startsWith(List<String> words, List<String> prefix) {
    for (var i = 0; i < prefix.length; i++) {
      if (words[i] != prefix[i]) return false;
    }
    return true;
  }

  static List<List<String>> _segments(List<String> words) {
    final out = <List<String>>[];
    var cur = <String>[];
    for (final w in words) {
      if (w == 'and' || w == 'plus' || w == 'also') {
        if (cur.isNotEmpty) out.add(cur);
        cur = [];
      } else {
        cur.add(w);
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  static _Parsed _item(List<String> seg) {
    final spoken = seg.join(' ');
    var i = 0;
    num? quantity;
    final digits = RegExp(r'^\d{1,4}(\.\d{1,3})?$');
    if (digits.hasMatch(seg[0])) {
      quantity = num.parse(seg[0]);
      if (quantity is double && quantity == quantity.roundToDouble()) {
        quantity = quantity.toInt();
      }
      i = 1;
    } else if (_tens.containsKey(seg[0])) {
      quantity = _tens[seg[0]]!;
      i = 1;
      if (seg.length > 1 &&
          (_ones[seg[1]] ?? 0) >= 1 &&
          (_ones[seg[1]] ?? 0) <= 9 &&
          seg[1] != 'a' &&
          seg[1] != 'an') {
        quantity = quantity + _ones[seg[1]]!;
        i = 2;
      }
    } else if (_ones.containsKey(seg[0])) {
      quantity = _ones[seg[0]]!;
      i = 1;
    }

    // Unit ("1.5 kg rice", "2 packs of milk").
    String? unit;
    if (i < seg.length && _units.containsKey(seg[i])) {
      unit = _units[seg[i]];
      i++;
    }
    final rest = seg.sublist(i).where((w) => !_fillers.contains(w)).toList();
    final variants = <String>[];
    var j = 0;
    while (j < rest.length - 1 && _variants.contains(rest[j])) {
      variants.add(rest[j]);
      j++;
    }
    final productWords = rest.sublist(j);
    final product = productWords.isEmpty
        ? null
        : _singular(productWords).join(' ');

    // No product: nothing left, or only vague / size words ("something",
    // "two large").
    final noProduct =
        product == null ||
        productWords.every(
          (w) => _vagueProducts.contains(w) || _variants.contains(w),
        );
    if (quantity == null && noProduct && !_vagueQuantities.contains(seg[0])) {
      return _Parsed.unclear(
        spoken,
        'Which product?',
        ClarificationNeed.product,
      );
    }
    if (quantity == null) {
      final vague = _vagueQuantities.contains(seg[0]);
      final what = vague ? _productAfter(seg.sublist(1)) : (product ?? spoken);
      return _Parsed.unclear(
        spoken,
        what == null || what.isEmpty ? 'How many?' : 'How many $what?',
        ClarificationNeed.quantity,
      );
    }
    if (quantity <= 0 || quantity > maxQuantity) {
      return _Parsed.unclear(
        spoken,
        'How many? ($spoken is not a valid quantity)',
        ClarificationNeed.quantity,
      );
    }
    if (noProduct) {
      return _Parsed.unclear(
        spoken,
        'Which product?',
        ClarificationNeed.product,
      );
    }
    // Decimals only make sense with a unit (1.5 kg); "1.5 coffee" is unclear.
    if (quantity is double && unit == null) {
      return _Parsed.unclear(
        spoken,
        'How many $product? (a whole number, or give a unit such as kg)',
        ClarificationNeed.quantity,
      );
    }
    return _Parsed(
      VoiceIntentItem(
        spokenText: spoken,
        quantity: quantity,
        productQuery: product,
        variantQuery: variants.isEmpty ? null : variants.join(' '),
        unit: unit,
      ),
    );
  }

  static String? _productAfter(List<String> words) {
    final w = words
        .where((x) => !_fillers.contains(x) && !_variants.contains(x))
        .toList();
    return w.isEmpty ? null : _singular(w).join(' ');
  }

  /// "coffees" -> "coffee", "berries" -> "berry", "boxes" -> "box" (last
  /// word only; simple rules, not a dictionary).
  static List<String> _singular(List<String> words) {
    final out = [...words];
    final w = out.last;
    String s = w;
    if (w.length > 4 && w.endsWith('ies')) {
      s = '${w.substring(0, w.length - 3)}y';
    } else if (w.length > 3 && RegExp(r'(sh|ch|x|ss)es$').hasMatch(w)) {
      s = w.substring(0, w.length - 2);
    } else if (w.length > 3 &&
        w.endsWith('s') &&
        !w.endsWith('ss') &&
        !w.endsWith('us')) {
      s = w.substring(0, w.length - 1);
    }
    out[out.length - 1] = s;
    return out;
  }
}

/// Phase 13E — spoken corrections of the Quick Bill on screen. Same words,
/// numbers and units as [RuleBasedIntentParser]; returns null when the text
/// is not a correction at all. Never resolves WHICH line is meant — that is
/// matched against the bill's own lines by the controller.
class RuleBasedCorrectionParser {
  const RuleBasedCorrectionParser();

  static const _setVerbs = {'make', 'change', 'set', 'update'};
  static const _removeVerbs = {'remove', 'delete', 'drop'};
  static const _pronouns = {'it', 'that', 'this'};
  static const _fillers = {'the', 'quantity', 'qty', 'of', 'please', 'pls'};

  static const exampleHint =
      'Say for example "make the coffee three", "remove the water" or "add one water".';

  VoiceCorrection? parse(
    String text, {
    VoiceLanguage language = VoiceLanguage.english,
  }) {
    // Phase 13G: each language uses its own grammar; never another one.
    if (!RuleBasedIntentParser.languages.contains(language)) {
      return VoiceCorrection.unclear(
        'Voice corrections are not available in ${language.label} yet.',
      );
    }
    if (language == VoiceLanguage.malayalam) {
      return _Malayalam.correction(text); // Phase 13H
    }
    var w = RuleBasedIntentParser._normalize(text);
    if (w.isNotEmpty && w.first == RuleBasedIntentParser.assistantName) {
      w = w.sublist(1);
      if (w.isNotEmpty && w.first == 'and') w = w.sublist(1);
    }
    if (w.isEmpty) return null;
    final rest = w.sublist(1);
    if (_setVerbs.contains(w.first)) return _setQuantity(rest);
    if (_removeVerbs.contains(w.first)) return _remove(rest);
    if (w.first == 'add') return _add(rest);
    return null;
  }

  /// Words for matching a spoken item against a bill line (lower case, the
  /// same simple plural rule, fillers dropped).
  static List<String> matchWords(String text) => [
    for (final w in RuleBasedIntentParser._normalize(text))
      if (!_fillers.contains(w)) RuleBasedIntentParser._singular([w]).single,
  ];

  static bool _isNumber(String w) =>
      RegExp(r'^\d').hasMatch(w) ||
      RuleBasedIntentParser._tens.containsKey(w) ||
      (RuleBasedIntentParser._ones.containsKey(w) && w != 'a' && w != 'an');

  /// "make the coffee three" / "change coffee to 3" / "make it 1.250 kg".
  VoiceCorrection _setQuantity(List<String> rest) {
    final words = rest.where((x) => !_fillers.contains(x)).toList();
    final to = words.indexOf('to');
    final List<String> target;
    final List<String> amount;
    if (to >= 0) {
      target = words.sublist(0, to);
      amount = words.sublist(to + 1);
    } else {
      final k = words.indexWhere(_isNumber, 1);
      target = k < 0 ? words : words.sublist(0, k);
      amount = k < 0 ? const [] : words.sublist(k);
    }
    if (target.isEmpty) {
      return const VoiceCorrection.unclear(
        'Which item, and how many? $exampleHint',
      );
    }
    final q = _quantity(amount);
    if (q == null) {
      return const VoiceCorrection.unclear('How many? $exampleHint');
    }
    return VoiceCorrection.setQuantity(
      target: _target(target),
      quantity: q.$1,
      unit: q.$2,
    );
  }

  VoiceCorrection _remove(List<String> rest) {
    final words = rest.where((x) => !_fillers.contains(x)).toList();
    if (words.isEmpty || _isNumber(words.first)) {
      return const VoiceCorrection.unclear(
        'Which item should be removed? Say for example "remove the water".',
      );
    }
    return VoiceCorrection.remove(target: _target(words));
  }

  /// "add one more coffee" / "add one water and two teas" — the same item
  /// rules as a spoken bill.
  VoiceCorrection _add(List<String> rest) {
    final words = rest.where((x) => x != 'more').toList();
    if (words.isEmpty) {
      return const VoiceCorrection.unclear(
        'What should be added? Say for example "add one water".',
      );
    }
    final items = <VoiceIntentItem>[];
    for (final seg in RuleBasedIntentParser._segments(words)) {
      final p = RuleBasedIntentParser._item(seg);
      if (p.item == null) {
        return VoiceCorrection.unclear(p.question ?? 'What should be added?');
      }
      items.add(p.item!);
    }
    if (items.isEmpty) {
      return const VoiceCorrection.unclear(
        'What should be added? Say for example "add one water".',
      );
    }
    return VoiceCorrection.add(items);
  }

  /// null = "it" / "that" (only resolved when the bill has one line).
  static String? _target(List<String> words) =>
      words.length == 1 && _pronouns.contains(words.single)
      ? null
      : RuleBasedIntentParser._singular(words).join(' ');

  /// The whole of [w] must be one quantity (+ optional unit).
  static (num, String?)? _quantity(List<String> w) {
    if (w.isEmpty) return null;
    num? q;
    var i = 1;
    final digits = RegExp(r'^\d{1,4}(\.\d{1,3})?$');
    if (digits.hasMatch(w[0])) {
      q = num.parse(w[0]);
      if (q is double && q == q.roundToDouble()) q = q.toInt();
    } else if (RuleBasedIntentParser._tens.containsKey(w[0])) {
      q = RuleBasedIntentParser._tens[w[0]]!;
      final one = w.length > 1 ? RuleBasedIntentParser._ones[w[1]] : null;
      if (one != null && one >= 1 && one <= 9 && w[1] != 'a' && w[1] != 'an') {
        q = q + one;
        i = 2;
      }
    } else if (w[0] != 'a' && w[0] != 'an') {
      q = RuleBasedIntentParser._ones[w[0]]; // null: not a quantity
    }
    if (q == null || q <= 0 || q > RuleBasedIntentParser.maxQuantity) {
      return null;
    }
    String? unit;
    if (i < w.length && RuleBasedIntentParser._units.containsKey(w[i])) {
      unit = RuleBasedIntentParser._units[w[i]];
      i++;
    }
    return i == w.length ? (q, unit) : null;
  }
}

class _Parsed {
  _Parsed(this.item) : spoken = item!.spokenText, question = null, need = null;
  _Parsed.unclear(this.spoken, this.question, this.need) : item = null;
  final VoiceIntentItem? item;
  final String spoken;
  final String? question;
  final ClarificationNeed? need;
}
