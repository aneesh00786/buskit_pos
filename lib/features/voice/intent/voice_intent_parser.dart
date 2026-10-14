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
      int? orderNumber,
      int? tableNumber,
    }) => VoiceIntent(
      type: type,
      voiceSessionId: voiceSessionId,
      requestId: requestId,
      recognizedText: recognizedText,
      items: items,
      clarification: clarification,
      need: need,
      orderNumber: orderNumber,
      tableNumber: tableNumber,
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
    // Phase 2 (English): an existing order ("bill order 1048", "show the
    // active order for table 6", "bill that order").
    final order = _orderCommand(rest);
    if (order != null) {
      return make(
        order.type,
        orderNumber: order.order,
        tableNumber: order.table,
        clarification: order.question,
        need: order.question == null ? null : ClarificationNeed.order,
      );
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

  /// Phase 2 — words that may come before "order" / "table".
  static const _orderVerbs = {
    'bill',
    'show',
    'open',
    'find',
    'get',
    'load',
    'display',
    'pull',
    'check',
    'checkout',
    'ring',
    'close',
  };
  static const _orderLead = {
    ..._orderVerbs,
    'up',
    'out',
    'me',
    'the',
    'active',
    'held',
    'current',
    'that',
    'this',
    'please',
    'for',
    'an',
    'a',
    'orders', // Phase 2.1: "find orders for table 6"
    'all',
    'any',
  };

  static const orderExample = 'Say for example "bill order 1048".';

  /// Phase 2: "bill order 1048" / "show the active order for table 6" /
  /// "bill that order" — or null when [w] is not about an existing order.
  static ({VoiceIntentType type, int? order, int? table, String? question})?
  _orderCommand(List<String> w) {
    final k = w.indexWhere((x) => x == 'order' || x == 'table');
    if (k < 0) return null;
    final lead = w.sublist(0, k);
    if (lead.isEmpty ||
        !lead.every(_orderLead.contains) ||
        !lead.any(_orderVerbs.contains)) {
      return null;
    }
    final after = w
        .sublist(k + 1)
        .where((x) => !{'number', 'no', 'num', 'id', 'please'}.contains(x))
        .toList();
    // "... table 6" / "... order for table 6"
    final t = w.indexOf('table');
    if (t >= 0) {
      if (w[k] == 'order' && t != k + 1 && !(t == k + 2 && w[k + 1] == 'for')) {
        return null;
      }
      final n = spokenInteger(
        w.sublist(t + 1).where((x) => x != 'number' && x != 'no').toList(),
      );
      return (
        type: n == null
            ? VoiceIntentType.needsClarification
            : VoiceIntentType.tableOrder,
        order: null,
        table: n,
        question: n == null ? 'Which table? $orderExample' : null,
      );
    }
    if (after.isEmpty) {
      if (lead.contains('that') || lead.contains('this')) {
        return (
          type: VoiceIntentType.billShownOrder,
          order: null,
          table: null,
          question: null,
        );
      }
      return (
        type: VoiceIntentType.needsClarification,
        order: null,
        table: null,
        question: 'Which order? $orderExample',
      );
    }
    final n = spokenInteger(after);
    if (n == null || n < 1) {
      return (
        type: VoiceIntentType.needsClarification,
        order: null,
        table: null,
        question: 'Which order number? $orderExample',
      );
    }
    return (
      type: VoiceIntentType.billOrder,
      order: n,
      table: null,
      question: null,
    );
  }

  static const _digitWords = {
    'zero': 0,
    'oh': 0,
    'o': 0,
    'one': 1,
    'two': 2,
    'three': 3,
    'four': 4,
    'five': 5,
    'six': 6,
    'seven': 7,
    'eight': 8,
    'nine': 9,
  };

  /// Phase 2: a whole spoken number — "1048", "one zero four eight", "ten
  /// forty eight", "one thousand and forty eight", "forty eight". Null when
  /// [w] is not entirely one number (never a partial guess).
  static int? spokenInteger(List<String> w) {
    if (w.isEmpty) return null;
    if (w.length == 1 && RegExp(r'^\d{1,9}$').hasMatch(w.single)) {
      return int.parse(w.single);
    }
    if (w.length >= 2 && w.every(_digitWords.containsKey)) {
      return int.parse(w.map((x) => _digitWords[x]).join());
    }
    if (w.contains('hundred') || w.contains('thousand')) {
      var total = 0, current = 0;
      for (final x in w) {
        if (x == 'and') continue;
        final one = _ones[x];
        final ten = _tens[x];
        if (one != null && x != 'a' && x != 'an') {
          current += one;
        } else if (ten != null) {
          current += ten;
        } else if (x == 'hundred') {
          current = (current == 0 ? 1 : current) * 100;
        } else if (x == 'thousand') {
          total += (current == 0 ? 1 : current) * 1000;
          current = 0;
        } else {
          return null;
        }
      }
      return total + current;
    }
    // Groups of 1-99 ("ten forty eight" = 10 | 48 = 1048).
    final groups = <int>[];
    var i = 0;
    while (i < w.length) {
      final one = _ones[w[i]];
      final ten = _tens[w[i]];
      if (ten != null) {
        final next = i + 1 < w.length ? _ones[w[i + 1]] : null;
        if (next != null &&
            next >= 1 &&
            next <= 9 &&
            w[i + 1] != 'a' &&
            w[i + 1] != 'an') {
          groups.add(ten + next);
          i += 2;
        } else {
          groups.add(ten);
          i++;
        }
      } else if (one != null && w[i] != 'a' && w[i] != 'an') {
        groups.add(one);
        i++;
      } else {
        return null;
      }
    }
    if (groups.length == 1) return groups.single;
    if (groups.length == 2 && groups.first >= 10) {
      return groups.first * 100 + groups.last;
    }
    return null;
  }

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

  /// Phase 1: words that only soften a quantity change ("make that two
  /// instead", "change it to four now").
  static const _softeners = {'instead', 'now', 'then', 'rather'};

  /// Phase 1: a line by its place on the bill ("the first item", "the last
  /// one", "item 2").
  static const _ordinals = {
    'first': 1,
    '1st': 1,
    'second': 2,
    '2nd': 2,
    'third': 3,
    '3rd': 3,
    'fourth': 4,
    '4th': 4,
    'fifth': 5,
    '5th': 5,
    'sixth': 6,
    '6th': 6,
    'seventh': 7,
    '7th': 7,
    'eighth': 8,
    '8th': 8,
    'ninth': 9,
    '9th': 9,
    'tenth': 10,
    '10th': 10,
    'last': -1,
  };
  static const _lineNouns = {'item', 'one', 'line', 'product', 'entry'};

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

  /// "make the coffee three" / "change coffee to 3" / "make it 1.250 kg" /
  /// Phase 1: "change the first item to four" / "make that two instead".
  VoiceCorrection _setQuantity(List<String> rest) {
    final words = rest
        .where((x) => !_fillers.contains(x) && !_softeners.contains(x))
        .toList();
    final to = words.indexOf('to');
    final List<String> target;
    final List<String> amount;
    final positionWords = _positionLength(words);
    if (to >= 0) {
      target = words.sublist(0, to);
      amount = words.sublist(to + 1);
    } else if (positionWords > 0) {
      // "make the second one 3": "one" belongs to the position here.
      target = words.sublist(0, positionWords);
      amount = words.sublist(positionWords);
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
    final position = _position(target);
    return VoiceCorrection.setQuantity(
      target: position == null ? _target(target) : null,
      position: position,
      quantity: q.$1,
      unit: q.$2,
    );
  }

  VoiceCorrection _remove(List<String> rest) {
    final words = rest.where((x) => !_fillers.contains(x)).toList();
    final position = _position(words);
    if (position != null) return VoiceCorrection.remove(position: position);
    if (words.isEmpty || _isNumber(words.first)) {
      return const VoiceCorrection.unclear(
        'Which item should be removed? Say for example "remove the water".',
      );
    }
    return VoiceCorrection.remove(target: _target(words));
  }

  /// How many leading words of [w] name a line by position ("first item",
  /// "last", "item 2"); 0 when they do not.
  static int _positionLength(List<String> w) {
    if (w.isEmpty) return 0;
    if (_ordinals.containsKey(w[0])) {
      return w.length > 1 && _lineNouns.contains(w[1]) ? 2 : 1;
    }
    if (w.length > 1 &&
        (w[0] == 'item' || w[0] == 'line' || w[0] == 'number') &&
        _number(w[1]) != null) {
      return 2;
    }
    return 0;
  }

  /// The position [w] names as a whole (1-based, -1 = last), or null.
  static int? _position(List<String> w) {
    final n = _positionLength(w);
    if (n == 0 || n != w.length) return null;
    return _ordinals[w[0]] ?? _number(w[1]);
  }

  static int? _number(String w) {
    if (RegExp(r'^\d{1,2}$').hasMatch(w)) return int.parse(w);
    final one = RuleBasedIntentParser._ones[w];
    return one == null || w == 'a' || w == 'an' ? null : one;
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

/// Phase 1 (English only) — the answer to "Would you like to confirm this
/// bill?": yes / no / cancel. Only a clear, whole answer counts ("yes",
/// "yes, confirm the bill", "no, I want to change something", "cancel this
/// bill"); "no" followed by a correction hands that correction back in
/// [rest]. Anything else is not an answer (null) — or [VoiceReply.unclear]
/// when it mixes yes and no or adds other words to a "yes".
class RuleBasedReplyParser {
  const RuleBasedReplyParser();

  static const _yes = {
    'yes',
    'yeah',
    'yep',
    'yup',
    'ok',
    'okay',
    'sure',
    'correct',
    'confirm',
    'confirmed',
    'right',
    'perfect',
    'fine',
  };
  static const _no = {'no', 'nope', 'nah', 'wrong', 'incorrect'};
  static const _plainYes = {
    'yes',
    'yeah',
    'yep',
    'yup',
    'ok',
    'okay',
    'sure',
    'confirm',
    'confirmed',
    'perfect',
  };
  static const _cancel = {'cancel', 'discard', 'abort', 'scrap'};

  /// Words allowed around a "yes" ("yes, that's correct, confirm the bill").
  static const _confirmWords = {
    ..._yes,
    'the',
    'bill',
    'it',
    'that',
    'this',
    'is',
    's',
    'its',
    'thats',
    'please',
    'go',
    'ahead',
    'all',
    'looks',
    'good',
    'do',
    'and',
  };

  /// Words allowed around a "no" ("no, I want to change something").
  static const _rejectWords = {
    ..._no,
    'i',
    'want',
    'to',
    'change',
    'something',
    'it',
    'that',
    'this',
    'the',
    'bill',
    'is',
    's',
    'its',
    'thats',
    'not',
    'correct',
    'right',
    'please',
    'need',
    'let',
    'me',
    'edit',
    'isn',
    't',
    'would',
    'like',
    'a',
    'few',
    'things',
    'quite',
    'and',
    'wait',
    'hold',
    'on',
  };

  /// Words allowed after "cancel" ("cancel this bill").
  static const _cancelWords = {
    'this',
    'the',
    'bill',
    'it',
    'that',
    'order',
    'sale',
    'please',
    'whole',
    'everything',
    'and',
  };

  ({VoiceReply reply, String? rest})? parse(
    String text, {
    VoiceLanguage language = VoiceLanguage.english,
  }) {
    if (language == VoiceLanguage.malayalam) return _Malayalam.reply(text);
    if (language != VoiceLanguage.english) return null; // no grammar
    var w = RuleBasedIntentParser._normalize(text);
    if (w.isNotEmpty && w.first == RuleBasedIntentParser.assistantName) {
      w = w.sublist(1);
    }
    w = w.where((x) => x != 'and').toList();
    if (w.isEmpty) return null;

    if (_cancel.contains(w.first) && w.skip(1).every(_cancelWords.contains)) {
      return (reply: VoiceReply.cancel, rest: null);
    }
    // "right" / "correct" / "fine" only mean yes in front ("no, that's not
    // right" is a no).
    final saysYes = _yes.contains(w.first) || w.any(_plainYes.contains);
    final saysNo = w.any(_no.contains);
    if (saysYes && saysNo) return (reply: VoiceReply.unclear, rest: null);
    if (_yes.contains(w.first) || (w.first == 'go' && w.contains('ahead'))) {
      return w.every(_confirmWords.contains)
          ? (reply: VoiceReply.confirm, rest: null)
          : (reply: VoiceReply.unclear, rest: null);
    }
    if (_no.contains(w.first)) {
      if (w.every(_rejectWords.contains)) {
        return (reply: VoiceReply.reject, rest: null);
      }
      // "No, make the coffee three": a "no" with the correction itself.
      return (reply: VoiceReply.reject, rest: w.skip(1).join(' '));
    }
    return null;
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
