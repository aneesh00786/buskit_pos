part of 'voice_intent_parser.dart';

/// Phase 13H — Malayalam Quick Bill commands and corrections. Deterministic
/// rules, same output types as English. Malayalam carries the numbers,
/// units, bill / correction words; the PRODUCT is the English name the
/// cashier says ("രണ്ട് coffee"), sent as the query to the existing English
/// catalogue. A Malayalam-only product name is asked about, never searched
/// and never guessed. No product ids, prices or stock here.
class _Malayalam {
  static const _numbers = {
    'ഒന്ന്': 1, 'ഒന്നു': 1, 'ഒരു': 1, //
    'രണ്ട്': 2, 'രണ്ടു': 2,
    'മൂന്ന്': 3, 'മൂന്നു': 3,
    'നാല്': 4, 'നാലു': 4,
    'അഞ്ച്': 5, 'അഞ്ചു': 5,
    'ആറ്': 6, 'ആറു': 6,
    'ഏഴ്': 7, 'ഏഴു': 7,
    'എട്ട്': 8, 'എട്ടു': 8,
    'ഒമ്പത്': 9, 'ഒൻപത്': 9,
    'പത്ത്': 10, 'പത്തു': 10,
  };
  static const _units = {
    'കിലോ': 'kg', 'കിലോഗ്രാം': 'kg', //
    'ഗ്രാം': 'g',
    'ലിറ്റർ': 'l',
    'മില്ലി': 'ml', 'മില്ലിലിറ്റർ': 'ml',
    'പാക്ക്': 'pack', 'പാക്കറ്റ്': 'pack',
    'ബോട്ടിൽ': 'bottle',
    'ബോക്സ്': 'box',
  };
  static const _bill = {'ബിൽ', 'ബില്ല്', 'ബില്'};
  static const _assistant = {'jacky', 'ജാക്കി'};
  static const _and = {'and', 'പിന്നെ', 'കൂടാതെ'};
  static const _pronouns = {'ഇത്', 'ഇതു', 'അത്', 'അതു', 'ഇതിന്റെ', 'അതിന്റെ'};
  static const _make = {'ആക്കൂ', 'ആക്കുക', 'ആക്ക്', 'ആക്കണം', 'ആക്കു'};
  static const _remove = {
    'നീക്കം', 'നീക്കൂ', 'നീക്കുക', 'കളയൂ', 'കളയുക', 'ഒഴിവാക്കൂ', //
  };
  static const _add = {'ചേർക്കൂ', 'ചേർക്കുക', 'ചേർക്ക്'};

  /// Phase 3A: a bill line by its place ("ആദ്യത്തെ ഇനം" = the first item).
  static const _ordinals = {
    'ആദ്യത്തെ': 1, 'ഒന്നാമത്തെ': 1, 'രണ്ടാമത്തെ': 2, 'മൂന്നാമത്തെ': 3, //
    'നാലാമത്തെ': 4, 'അഞ്ചാമത്തെ': 5, 'ആറാമത്തെ': 6, 'ഏഴാമത്തെ': 7,
    'എട്ടാമത്തെ': 8, 'ഒമ്പതാമത്തെ': 9, 'പത്താമത്തെ': 10, 'അവസാനത്തെ': -1,
  };

  static int? _position(List<String> w) {
    final hits = [for (final x in w) ?_ordinals[x]];
    return hits.length == 1 ? hits.single : null;
  }

  static const _latinFillers = {'of', 'the', 'please', 'pls', 'x', 'bill'};

  static const askEnglishName =
      'ഉൽപ്പന്നത്തിന്റെ പേര് ഇംഗ്ലീഷിൽ പറയുക. ഉദാഹരണം: "രണ്ട് coffee".';
  static const askWhat = 'എന്താണ് ബിൽ ചെയ്യേണ്ടത്? ഏത് ഉൽപ്പന്നം?';

  /// Lower case; old-style chillu (consonant + virama + ZWJ) -> atomic
  /// chillu; ZWJ / ZWNJ dropped; Malayalam digits -> 0-9; Latin and
  /// Malayalam runs split ("coffeeയുടെ" -> "coffee യുടെ").
  static List<String> words(String text) {
    var t = text.toLowerCase();
    const chillu = {'ണ': 'ൺ', 'ന': 'ൻ', 'ര': 'ർ', 'ല': 'ൽ', 'ള': 'ൾ'};
    chillu.forEach((c, atomic) => t = t.replaceAll('$c്‍', atomic));
    t = t.replaceAll(RegExp('[‌‍]'), '');
    for (var d = 0; d < 10; d++) {
      t = t.replaceAll(String.fromCharCode(0x0D66 + d), '$d');
    }
    t = t
        .replaceAll('&', ' and ')
        .replaceAll(',', ' and ')
        .replaceAllMapped(
          RegExp('([a-z0-9.])([ഀ-ൿ])'),
          (m) => '${m[1]} ${m[2]}',
        )
        .replaceAllMapped(RegExp('([ഀ-ൿ])([a-z0-9])'), (m) => '${m[1]} ${m[2]}')
        .replaceAll(RegExp('[^a-z0-9.\\sഀ-ൿ]'), ' ')
        .replaceAll(RegExp(r'\.(?!\d)'), ' ');
    return t.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  }

  static bool _isLatin(String w) => RegExp(r'^[a-z]+$').hasMatch(w);

  static num? _number(String w) {
    if (RegExp(r'^\d{1,4}(\.\d{1,3})?$').hasMatch(w)) {
      num q = num.parse(w);
      if (q is double && q == q.roundToDouble()) q = q.toInt();
      return q;
    }
    if (RegExp(r'^\d').hasMatch(w)) return -1; // a number, but not a valid one
    return _numbers[w] ??
        RuleBasedIntentParser._tens[w] ??
        (w == 'a' || w == 'an' ? null : RuleBasedIntentParser._ones[w]);
  }

  static String? _unit(String w) =>
      _units[w] ?? RuleBasedIntentParser._units[w];

  /// Strips "Jacky," (either script) from the front.
  static List<String> _unaddressed(List<String> w) {
    if (w.isNotEmpty && _assistant.contains(w.first)) {
      w = w.sublist(1);
      if (w.isNotEmpty && w.first == 'and') w = w.sublist(1);
    }
    return w;
  }

  static List<List<String>> _segments(List<String> words) {
    final out = <List<String>>[];
    var cur = <String>[];
    for (final w in words) {
      if (_and.contains(w)) {
        if (cur.isNotEmpty) out.add(cur);
        cur = [];
      } else {
        cur.add(w);
      }
    }
    if (cur.isNotEmpty) out.add(cur);
    return out;
  }

  /// One spoken line: exactly one quantity (+ optional unit right after it)
  /// and an ENGLISH product name; Malayalam words around it are ignored.
  static _Parsed item(List<String> seg) {
    final spoken = seg.join(' ');
    final numbers = [
      for (var i = 0; i < seg.length; i++)
        if (_number(seg[i]) != null) i,
    ];
    String? unit;
    final used = <int>{...numbers};
    if (numbers.length == 1) {
      final n = numbers.single;
      if (n + 1 < seg.length && _unit(seg[n + 1]) != null) {
        unit = _unit(seg[n + 1]);
        used.add(n + 1);
      }
    }
    final latin = [
      for (var i = 0; i < seg.length; i++)
        if (!used.contains(i) &&
            _isLatin(seg[i]) &&
            !_latinFillers.contains(seg[i]) &&
            !RuleBasedIntentParser._units.containsKey(seg[i]))
          seg[i],
    ];
    final variants = <String>[];
    var j = 0;
    while (j < latin.length - 1 &&
        RuleBasedIntentParser._variants.contains(latin[j])) {
      variants.add(latin[j]);
      j++;
    }
    final productWords = latin.sublist(j);
    final noProduct =
        productWords.isEmpty ||
        productWords.every(
          (w) =>
              RuleBasedIntentParser._vagueProducts.contains(w) ||
              RuleBasedIntentParser._variants.contains(w),
        );
    final product = noProduct
        ? null
        : RuleBasedIntentParser._singular(productWords).join(' ');
    final malayalamOnly =
        noProduct &&
        seg.any(
          (w) =>
              !_isLatin(w) &&
              _number(w) == null &&
              _unit(w) == null &&
              !_bill.contains(w),
        );

    if (noProduct) {
      return _Parsed.unclear(
        spoken,
        malayalamOnly && numbers.isNotEmpty ? askEnglishName : 'ഏത് ഉൽപ്പന്നം?',
        ClarificationNeed.product,
      );
    }
    if (numbers.isEmpty) {
      return _Parsed.unclear(
        spoken,
        'എത്ര $product?',
        ClarificationNeed.quantity,
      );
    }
    if (numbers.length > 1) {
      return _Parsed.unclear(
        spoken,
        'എത്ര $product? ഒരു എണ്ണം മാത്രം പറയുക.',
        ClarificationNeed.quantity,
      );
    }
    final q = _number(seg[numbers.single])!;
    if (q <= 0 || q > RuleBasedIntentParser.maxQuantity) {
      return _Parsed.unclear(
        spoken,
        'എത്ര $product? ($spoken ശരിയായ എണ്ണമല്ല)',
        ClarificationNeed.quantity,
      );
    }
    if (q is double && unit == null) {
      return _Parsed.unclear(
        spoken,
        'എത്ര $product? (പൂർണ്ണസംഖ്യ, അല്ലെങ്കിൽ കിലോ പോലുള്ള യൂണിറ്റ് പറയുക)',
        ClarificationNeed.quantity,
      );
    }
    return _Parsed(
      VoiceIntentItem(
        spokenText: spoken,
        quantity: q,
        productQuery: product!,
        variantQuery: variants.isEmpty ? null : variants.join(' '),
        unit: unit,
      ),
    );
  }

  /// "രണ്ട് coffee ബിൽ ചെയ്യൂ", "ഒരു water", "മൂന്ന് water ബിൽ ചെയ്യൂ".
  static VoiceIntent intent(
    String recognizedText,
    VoiceIntent Function(
      VoiceIntentType type, {
      List<VoiceIntentItem> items,
      String? clarification,
      ClarificationNeed? need,
      int? orderNumber,
      int? tableNumber,
    })
    make,
  ) {
    final w = _unaddressed(words(recognizedText));
    if (w.isEmpty) return make(VoiceIntentType.unknown);
    // Phase 3A: an existing order / table ("ഓർഡർ 1048 ബിൽ ചെയ്യൂ",
    // "ടേബിൾ 6 കാണിക്കൂ", "ആ ഓർഡർ ബിൽ ചെയ്യൂ").
    final order = _orderCommand(w);
    if (order != null) {
      return make(
        order.type,
        orderNumber: order.order,
        tableNumber: order.table,
        clarification: order.question,
        need: order.question == null ? null : ClarificationNeed.order,
      );
    }
    final triggered =
        w.any(_bill.contains) ||
        w.first == 'bill' ||
        (w.length > 1 && w[0] == 'quick' && w[1] == 'bill');
    final rest = [
      for (var i = 0; i < w.length; i++)
        if (!_bill.contains(w[i]) &&
            w[i] != 'bill' &&
            !(w[i] == 'quick' && i + 1 < w.length && w[i + 1] == 'bill'))
          w[i],
    ];
    final segments = _segments(rest);
    final hasNumber = [
      for (final seg in segments) seg.any((x) => _number(x) != null),
    ];
    if (segments.isEmpty ||
        segments.every(
          (seg) => !seg.any((x) => _isLatin(x) || _number(x) != null),
        )) {
      return triggered
          ? make(
              VoiceIntentType.needsClarification,
              clarification: askWhat,
              need: ClarificationNeed.product,
            )
          : make(VoiceIntentType.unknown);
    }
    // Without a bill word, only an utterance where EVERY line has a number
    // is taken as a quick bill ("രണ്ട് coffee, ഒരു water").
    if (!triggered && hasNumber.contains(false)) {
      return make(VoiceIntentType.unknown);
    }
    final parsed = segments.map(item).toList();
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

  // ---------------- Phase 3A: existing orders and tables ----------------

  static const _orderWords = {
    'ഓർഡർ', 'ഓർഡറ്', 'ഓഡർ', 'ഓർഡറിന്റെ', 'ഓർഡറിലെ', 'order', //
  };
  static const _tableWords = {
    'ടേബിൾ', 'ടേബിള്', 'ടേബിളിലെ', 'ടേബിളിന്റെ', 'ടേബിളിൽ', //
    'മേശ', 'മേശയിലെ', 'മേശയുടെ', 'മേശയിൽ', 'table',
  };

  /// Words that may stand around an order / table request (show, open,
  /// find, bill, do, number, that, this, active, waiting).
  static const _orderFillers = {
    ..._bill, 'bill', 'show', 'open', 'find', 'number', 'no', //
    'ചെയ്യൂ', 'ചെയ്യുക', 'ചെയ്യ്', 'കാണിക്കൂ', 'കാണിക്കുക', 'തുറക്കൂ',
    'തുറക്കുക', 'കണ്ടെത്തൂ', 'കണ്ടെത്തുക', 'നമ്പർ', 'നമ്പറ്',
    'ഉള്ള', 'ലെ', 'ഇലെ', 'സജീവ', 'കാത്തിരിക്കുന്ന', 'എല്ലാ', 'ഓർഡറുകൾ',
    'ഓർഡറുകള്', 'orders', 'the', 'please', 'ദയവായി',
  };
  static const _thatWords = {'ആ', 'ഈ', 'അത്', 'ഇത്', 'that', 'this'};

  static const orderExample = 'ഉദാഹരണം: "ഓർഡർ 1048 ബിൽ ചെയ്യൂ".';
  static const askOrderNumber =
      'ഏത് ഓർഡർ? ഓർഡർ നമ്പർ അക്കങ്ങളായി പറയുക. $orderExample';
  static const askTableNumber =
      'ഏത് ടേബിൾ? ടേബിൾ നമ്പർ പറയുക. ഉദാഹരണം: "ടേബിൾ 6 ബിൽ ചെയ്യൂ".';

  /// An order or table request — the whole utterance must be the order /
  /// table word, ONE number (digits, or a Malayalam / English number word
  /// up to ten) and the words above; anything else (e.g. an English product
  /// name) is not an order request (it may be a quick bill).
  static ({VoiceIntentType type, int? order, int? table, String? question})?
  _orderCommand(List<String> w) {
    final isTable = w.any(_tableWords.contains);
    final isOrder = w.any(_orderWords.contains);
    if (!isTable && !isOrder) return null;
    final numbers = <int>[];
    var that = false;
    var unclear = false;
    for (final x in w) {
      if (_orderWords.contains(x) ||
          _tableWords.contains(x) ||
          _orderFillers.contains(x)) {
        continue;
      }
      if (_thatWords.contains(x)) {
        that = true;
        continue;
      }
      final n = _wholeNumber(x);
      if (n != null) {
        numbers.add(n);
      } else if (_isLatin(x)) {
        return null; // an English (product) word: not an order request
      } else {
        unclear = true; // e.g. a long number said in words: ask, never guess
      }
    }
    if (unclear) {
      return (
        type: VoiceIntentType.needsClarification,
        order: null,
        table: null,
        question: isTable ? askTableNumber : askOrderNumber,
      );
    }
    if (isTable) {
      return numbers.length == 1 && numbers.single > 0
          ? (
              type: VoiceIntentType.tableOrder,
              order: null,
              table: numbers.single,
              question: null,
            )
          : (
              type: VoiceIntentType.needsClarification,
              order: null,
              table: null,
              question: askTableNumber,
            );
    }
    if (numbers.isEmpty && that) {
      return (
        type: VoiceIntentType.billShownOrder,
        order: null,
        table: null,
        question: null,
      );
    }
    return numbers.length == 1 && numbers.single > 0
        ? (
            type: VoiceIntentType.billOrder,
            order: numbers.single,
            table: null,
            question: null,
          )
        : (
            type: VoiceIntentType.needsClarification,
            order: null,
            table: null,
            question: askOrderNumber,
          );
  }

  /// A whole number said as digits (any length) or one number word up to
  /// ten; null otherwise (larger Malayalam number words are asked again).
  static int? _wholeNumber(String x) {
    if (RegExp(r'^\d{1,9}$').hasMatch(x)) return int.parse(x);
    final n = _number(x);
    return n is int && n > 0 ? n : null;
  }

  // ---------------- Phase 3A: answers (yes / no / cancel) ----------------

  static const _yes = {
    'അതെ', 'ഉവ്വ്', 'ഉവ്വ', 'ശരി', 'ശരിയാണ്', 'ഓക്കെ', 'ഓക്കേ', 'ok', 'okay', //
    'yes', 'സ്ഥിരീകരിക്കൂ', 'സ്ഥിരീകരിക്കുക', 'കൺഫേം', 'confirm',
  };
  static const _no = {
    'ഇല്ല', 'വേണ്ട', 'അല്ല', 'തെറ്റ്', 'തെറ്റാണ്', 'ശരിയല്ല', 'no', //
  };
  static const _cancel = {
    'റദ്ദാക്കൂ', 'റദ്ദാക്കുക', 'റദ്ദ്', 'ക്യാൻസൽ', 'cancel', //
  };
  static const _answerFillers = {
    ..._bill, 'bill', 'ചെയ്യൂ', 'ചെയ്യുക', 'ഇത്', 'ഇതു', 'അത്', 'അതു', //
    'ആ', 'ഈ', 'ഓർഡർ', 'എനിക്ക്', 'മാറ്റണം', 'മാറ്റം', 'വേണം', 'എന്തോ',
    'കുറച്ച്', 'ആണ്', 'ദയവായി', 'please', 'the',
  };

  /// "അതെ, ബിൽ ചെയ്യൂ" / "വേണ്ട, എനിക്ക് മാറ്റണം" / "ബിൽ റദ്ദാക്കൂ";
  /// "വേണ്ട, coffee മൂന്ന് ആക്കൂ" is a no carrying its correction ([rest]).
  /// A mix of yes and no is unclear; anything else is not an answer (null).
  static ({VoiceReply reply, String? rest})? reply(String text) {
    final w = _unaddressed(words(text)).where((x) => x != 'and').toList();
    if (w.isEmpty) return null;
    final saysCancel = w.any(_cancel.contains);
    final saysYes = w.any(_yes.contains);
    final saysNo = w.any(_no.contains);
    if (saysCancel && !saysYes && !saysNo) {
      return w.every((x) => _cancel.contains(x) || _answerFillers.contains(x))
          ? (reply: VoiceReply.cancel, rest: null)
          : (reply: VoiceReply.unclear, rest: null);
    }
    if (saysYes && saysNo) return (reply: VoiceReply.unclear, rest: null);
    if (saysYes) {
      return w.every((x) => _yes.contains(x) || _answerFillers.contains(x))
          ? (reply: VoiceReply.confirm, rest: null)
          : (reply: VoiceReply.unclear, rest: null);
    }
    if (saysNo) {
      if (w.every((x) => _no.contains(x) || _answerFillers.contains(x))) {
        return (reply: VoiceReply.reject, rest: null);
      }
      // "വേണ്ട, coffee മൂന്ന് ആക്കൂ": the correction after the no.
      return (
        reply: VoiceReply.reject,
        rest: w.where((x) => !_no.contains(x)).join(' '),
      );
    }
    return null;
  }

  // ---------------- corrections ----------------

  static const exampleHint =
      'ഉദാഹരണം: "coffee മൂന്ന് ആക്കൂ", "water നീക്കം ചെയ്യൂ", '
      '"ഒരു water കൂടി ചേർക്കൂ".';

  /// "coffee മൂന്ന് ആക്കൂ" / "ഇത് മൂന്ന് ആക്കൂ" / "coffee നീക്കം ചെയ്യൂ" /
  /// "ഒരു water കൂടി ചേർക്കൂ". null when it is not a correction.
  static VoiceCorrection? correction(String text) {
    final w = _unaddressed(words(text));
    if (w.isEmpty) return null;
    if (w.any(_add.contains)) {
      final rest = [
        for (final x in w)
          if (!_add.contains(x) && x != 'കൂടി' && x != 'more') x,
      ];
      final items = <VoiceIntentItem>[];
      for (final seg in _segments(rest)) {
        final p = item(seg);
        if (p.item == null) {
          return VoiceCorrection.unclear('${p.question} $exampleHint');
        }
        items.add(p.item!);
      }
      if (items.isEmpty) {
        return const VoiceCorrection.unclear(
          'എന്താണ് ചേർക്കേണ്ടത്? ഉദാഹരണം: "ഒരു water കൂടി ചേർക്കൂ".',
        );
      }
      return VoiceCorrection.add(items);
    }
    if (w.any(_remove.contains)) {
      if (w.any((x) => _number(x) != null)) {
        return const VoiceCorrection.unclear(
          'ഒരു ഇനം മുഴുവനായി മാത്രം നീക്കാം. ഉദാഹരണം: "water നീക്കം ചെയ്യൂ".',
        );
      }
      final position = _position(w);
      if (position != null) return VoiceCorrection.remove(position: position);
      final target = _target(w);
      if (target == '') {
        return const VoiceCorrection.unclear(
          'ഏത് ഇനം നീക്കണം? ഉദാഹരണം: "water നീക്കം ചെയ്യൂ".',
        );
      }
      return VoiceCorrection.remove(target: target);
    }
    if (w.any(_make.contains)) {
      final numbers = [
        for (var i = 0; i < w.length; i++)
          if (_number(w[i]) != null) i,
      ];
      if (numbers.length != 1) {
        return const VoiceCorrection.unclear('എത്ര ആക്കണം? $exampleHint');
      }
      final n = numbers.single;
      final q = _number(w[n])!;
      if (q <= 0 || q > RuleBasedIntentParser.maxQuantity) {
        return const VoiceCorrection.unclear('എത്ര ആക്കണം? $exampleHint');
      }
      String? unit;
      final skip = <int>{n};
      if (n + 1 < w.length && _unit(w[n + 1]) != null) {
        unit = _unit(w[n + 1]);
        skip.add(n + 1);
      }
      final position = _position(w);
      if (position != null) {
        return VoiceCorrection.setQuantity(
          position: position,
          quantity: q,
          unit: unit,
        );
      }
      final target = _target([
        for (var i = 0; i < w.length; i++)
          if (!skip.contains(i)) w[i],
      ]);
      if (target == '') {
        return const VoiceCorrection.unclear(
          'ഏത് ഇനത്തിന്റെ എണ്ണം മാറ്റണം? $exampleHint',
        );
      }
      return VoiceCorrection.setQuantity(
        target: target,
        quantity: q,
        unit: unit,
      );
    }
    return null;
  }

  /// The English product named, null for "ഇത്" / "അത്" (it / that), or ''
  /// when neither was said (a Malayalam-only name is not searched).
  static String? _target(List<String> w) {
    final latin = [
      for (final x in w)
        if (_isLatin(x) && !_latinFillers.contains(x)) x,
    ];
    if (latin.isNotEmpty) {
      return RuleBasedIntentParser._singular(latin).join(' ');
    }
    return w.any(_pronouns.contains) ? null : '';
  }
}
