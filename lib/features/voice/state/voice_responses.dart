import '../../../core/utils/format.dart';
import '../models/quick_bill_preview.dart';
import '../models/voice_language.dart';

/// Phase 13G/13H — what Jacky says and asks, per language: the spoken
/// replies and the on-screen correction questions. Short forms of what the
/// screen already shows (never ids, intents or technical detail); product
/// and candidate names always come from the bill / the server.
abstract class VoiceResponses {
  /// The provider for [language]; null when it has none (nothing spoken).
  static VoiceResponses? forLanguage(VoiceLanguage language) {
    if (language == VoiceLanguage.english) return const EnglishVoiceResponses();
    if (language == VoiceLanguage.malayalam) {
      return const MalayalamVoiceResponses();
    }
    return null;
  }

  // ---- spoken ----

  /// A preview answer (null = the preview could not be loaded).
  String preview(QuickBillPreview? p);

  /// A screen question, spoken (its typed example left out).
  String question(String screenQuestion);

  /// "it" on a bill with several lines.
  String whichItem(List<String> lines);

  /// A name that fits several lines.
  String whichNamed(String said, List<String> lines);

  /// A name that fits no line.
  String noSuchLine(String said);

  String checking();

  // ---- on screen (Phase 13H) ----

  String whichItemScreen(String lines);
  String whichNamedScreen(String said, String lines);
  String noSuchLineScreen(String said, String lines);
  String notACorrection();
  String allRemoved();

  // ---- Phase 3A: every reply of the Phase 1 / 2 / 2.1 flows ----
  // Amounts are the server's, passed in already formatted (never changed).

  String whatToChange();
  String yesOrNo();
  String notReadyToConfirm();
  String billCancelled();
  String whichOrder();
  String orderPrompt(int order, String total);
  String orderNotFound(int order);
  String orderMismatch();
  String orderNetwork();
  String orderLoadFailed();
  String orderChanged();
  String orderIneligible();
  String orderUncertain();
  String orderAnswerHint();
  String orderLeftAsIs();
  String orderOpenFailed();
  String tableUnsupported();
  String noTableOrders(String table);
  String tableChoose(int count, String table);
  String tableMismatch();
  String tableNetwork(String table);
  String tableLoadFailed(String table);
  String staleBill();
  String noCart();
  String offline();
  String busyCart();

  /// The device cannot recognise speech in this language.
  String recognitionUnavailable(String language);

  /// The device cannot speak this language (replies stay on screen).
  String spokenRepliesUnavailable(String language);
}

/// Phase 13F's English wording (Phase 1: the confirmation question and the
/// yes / no hint).
class EnglishVoiceResponses implements VoiceResponses {
  const EnglishVoiceResponses();

  static const exampleHint =
      'Say for example "make the coffee three", "remove the water" or "add one water".';

  @override
  String preview(QuickBillPreview? p) {
    if (p == null) return "I couldn't check the bill. Please try again.";
    if (p.isReady) {
      // Phase 1: the server-calculated total, then the yes / no question.
      return 'The total is ${formatMoney(p.total)}. '
          'Would you like to confirm this bill?';
    }
    final issue = p.issues.firstOrNull;
    if (issue == null) return 'I need some clarification.';
    if (issue.candidates.length > 1) {
      final names = [
        for (final c in issue.candidates.take(3))
          [c.productName, c.variantName].nonNulls.join(' '),
      ];
      final more = issue.candidates.length > 3 ? ', or another' : '';
      return 'I need some clarification. Which ${issue.said} would you like: '
          '${orList(names)}$more?';
    }
    return 'I need some clarification. ${issue.message}';
  }

  @override
  String question(String screenQuestion) {
    final cut = screenQuestion.indexOf(' Say for example');
    return (cut < 0 ? screenQuestion : screenQuestion.substring(0, cut))
        .replaceAll('"', '');
  }

  @override
  String whichItem(List<String> lines) => 'Which item? ${orList(lines)}?';

  @override
  String whichNamed(String said, List<String> lines) =>
      'Which $said? ${orList(lines)}?';

  @override
  String noSuchLine(String said) => 'There is no $said on this bill.';

  @override
  String checking() => 'Checking the bill.';

  @override
  String whichItemScreen(String lines) =>
      'Which item? This bill has $lines. Say for example "make the coffee three".';

  @override
  String whichNamedScreen(String said, String lines) =>
      'Which $said? This bill has $lines.';

  @override
  String noSuchLineScreen(String said, String lines) =>
      'There is no $said on this bill. It has $lines.';

  @override
  String notACorrection() =>
      "I didn't understand that. Say yes to confirm the bill, no to change "
      'it, or a correction. $exampleHint';

  @override
  String allRemoved() =>
      'All items were removed. Speak again to start a new bill.';

  @override
  String whatToChange() => 'What would you like to change? $exampleHint';
  @override
  String yesOrNo() => 'Please say yes to confirm the bill, or no to change it.';
  @override
  String notReadyToConfirm() =>
      'This bill still needs a clarification before it can be confirmed.';
  @override
  String billCancelled() => 'The bill was cancelled. Nothing was billed.';
  @override
  String whichOrder() => 'Which order? Say for example "bill order 1048".';
  @override
  String orderPrompt(int order, String total) =>
      'Order $order. The total is $total. Would you like to bill this order?';
  @override
  String orderNotFound(int order) =>
      'No order $order is waiting to be billed in this store.';
  @override
  String orderMismatch() => 'The order did not match this request. Try again.';
  @override
  String orderNetwork() =>
      'Could not reach the server to find this order. Check the connection and tap Retry.';
  @override
  String orderLoadFailed() =>
      'The order could not be loaded. Please try again.';
  @override
  String orderChanged() =>
      'This order was changed or billed by someone else after it was shown. '
      'Reload it to review it again.';
  @override
  String orderIneligible() =>
      'This order can no longer be billed here. Reload it, or check Orders.';
  @override
  String orderUncertain() =>
      'Could not reach the server to open this order. Reload it to check '
      'whether it was opened before trying again.';
  @override
  String orderAnswerHint() =>
      'Please say yes to bill this order, or cancel. You can also tap '
      'Bill this order.';
  @override
  String orderLeftAsIs() => 'The order was left as it is. Nothing was billed.';
  @override
  String orderOpenFailed() =>
      'The order could not be opened. Please try again.';
  @override
  String tableUnsupported() =>
      'Table orders are not available here. Say "bill order" and the order '
      'number, for example "bill order 1048".';
  @override
  String noTableOrders(String table) =>
      'No held orders are waiting for billing at table $table.';
  @override
  String tableChoose(int count, String table) =>
      'There are $count orders at table $table. Choose one on the screen.';
  @override
  String tableMismatch() =>
      'The table result did not match this request. Try again.';
  @override
  String tableNetwork(String table) =>
      'Could not reach the server to find the orders at table $table. Check the connection and tap Retry.';
  @override
  String tableLoadFailed(String table) =>
      'The orders at table $table could not be loaded. Please try again.';
  @override
  String staleBill() =>
      'This bill is no longer current. Please check it again.';
  @override
  String noCart() => 'Open Voice bill from the cart to continue to checkout.';
  @override
  String offline() => 'Voice billing needs a connection to the server.';
  @override
  String busyCart() =>
      'Finish, hold or clear the current sale before billing by voice.';
  @override
  String recognitionUnavailable(String language) =>
      '$language speech recognition is not available on this device. Add the '
      '$language language to the device\'s voice typing / speech settings, or '
      'choose another language.';
  @override
  String spokenRepliesUnavailable(String language) =>
      'Spoken replies are not available in $language on this device. Replies '
      'are shown on screen.';

  /// "a", "a or b", "a, b, or c".
  static String orList(List<String> xs) => switch (xs.length) {
    0 => '',
    1 => xs.single,
    2 => '${xs.first} or ${xs.last}',
    _ => '${xs.sublist(0, xs.length - 1).join(', ')}, or ${xs.last}',
  };
}

/// Phase 13H — Malayalam wording. Totals, product and candidate names are
/// the server's / the bill's own (product names stay as in the catalogue).
class MalayalamVoiceResponses implements VoiceResponses {
  const MalayalamVoiceResponses();

  static const clarify = 'എനിക്ക് കുറച്ച് വ്യക്തത വേണം.';

  @override
  String preview(QuickBillPreview? p) {
    if (p == null) {
      return 'ബിൽ പരിശോധിക്കാൻ കഴിഞ്ഞില്ല. ദയവായി വീണ്ടും ശ്രമിക്കുക.';
    }
    if (p.isReady) {
      return 'നിങ്ങളുടെ ബിൽ തയ്യാറാണ്. മൊത്തം ${formatMoney(p.total)} ആണ്. '
          'സ്ഥിരീകരിച്ച ശേഷം മാത്രം ബിൽ പൂർത്തിയാക്കുക.';
    }
    final issue = p.issues.firstOrNull;
    if (issue != null && issue.candidates.length > 1) {
      final names = [
        for (final c in issue.candidates.take(3))
          [c.productName, c.variantName].nonNulls.join(' '),
      ];
      final more = issue.candidates.length > 3 ? ', അല്ലെങ്കിൽ മറ്റൊന്ന്' : '';
      return '$clarify ഏത് ${issue.said} ആണ് വേണ്ടത്: ${orList(names)}$more?';
    }
    return clarify;
  }

  @override
  String question(String screenQuestion) {
    final cut = screenQuestion.indexOf(' ഉദാഹരണം:');
    return (cut < 0 ? screenQuestion : screenQuestion.substring(0, cut))
        .replaceAll('"', '');
  }

  @override
  String whichItem(List<String> lines) => 'ഏത് ഇനമാണ്? ${orList(lines)}?';

  @override
  String whichNamed(String said, List<String> lines) =>
      'ഏത് $said ആണ്? ${orList(lines)}?';

  @override
  String noSuchLine(String said) => 'ഈ ബില്ലിൽ ആ ഇനം ഇല്ല.';

  @override
  String checking() => 'ബിൽ പരിശോധിക്കുകയാണ്.';

  @override
  String whichItemScreen(String lines) =>
      'ഏത് ഇനമാണ്? ഈ ബില്ലിൽ: $lines. ഉദാഹരണം: "coffee മൂന്ന് ആക്കൂ".';

  @override
  String whichNamedScreen(String said, String lines) =>
      'ഏത് $said ആണ്? ഈ ബില്ലിൽ: $lines.';

  @override
  String noSuchLineScreen(String said, String lines) =>
      'ഈ ബില്ലിൽ $said ഇല്ല. ബില്ലിൽ: $lines.';

  @override
  String notACorrection() =>
      'അതൊരു തിരുത്തൽ അല്ല. ഉദാഹരണം: "coffee മൂന്ന് ആക്കൂ", '
      '"water നീക്കം ചെയ്യൂ", "ഒരു water കൂടി ചേർക്കൂ".';

  @override
  String allRemoved() =>
      'എല്ലാ ഇനങ്ങളും നീക്കം ചെയ്തു. പുതിയ ബിൽ ആരംഭിക്കാൻ വീണ്ടും പറയുക.';

  @override
  String whatToChange() =>
      'എന്താണ് മാറ്റേണ്ടത്? ഉദാഹരണം: "coffee മൂന്ന് ആക്കൂ", '
      '"water നീക്കം ചെയ്യൂ", "ഒരു water കൂടി ചേർക്കൂ".';
  @override
  String yesOrNo() =>
      'ബിൽ സ്ഥിരീകരിക്കാൻ "അതെ" എന്നും മാറ്റാൻ "വേണ്ട" എന്നും പറയുക.';
  @override
  String notReadyToConfirm() =>
      'ഈ ബിൽ സ്ഥിരീകരിക്കുന്നതിന് മുമ്പ് ഒരു കാര്യം വ്യക്തമാക്കണം.';
  @override
  String billCancelled() => 'ബിൽ റദ്ദാക്കി. ഒന്നും ബിൽ ചെയ്തിട്ടില്ല.';
  @override
  String whichOrder() => 'ഏത് ഓർഡർ? ഉദാഹരണം: "ഓർഡർ 1048 ബിൽ ചെയ്യൂ".';
  @override
  String orderPrompt(int order, String total) =>
      'ഓർഡർ $order. മൊത്തം $total ആണ്. ഈ ഓർഡർ ബിൽ ചെയ്യട്ടെ?';
  @override
  String orderNotFound(int order) =>
      'ഈ സ്റ്റോറിൽ ബിൽ ചെയ്യാൻ കാത്തിരിക്കുന്ന ഓർഡർ $order ഇല്ല.';
  @override
  String orderMismatch() =>
      'ലഭിച്ച ഓർഡർ ഈ അഭ്യർത്ഥനയുടേതല്ല. വീണ്ടും ശ്രമിക്കുക.';
  @override
  String orderNetwork() =>
      'ഓർഡർ കണ്ടെത്താൻ സെർവറുമായി ബന്ധപ്പെടാൻ കഴിഞ്ഞില്ല. കണക്ഷൻ പരിശോധിച്ച് Retry അമർത്തുക.';
  @override
  String orderLoadFailed() =>
      'ഓർഡർ ലോഡ് ചെയ്യാൻ കഴിഞ്ഞില്ല. ദയവായി വീണ്ടും ശ്രമിക്കുക.';
  @override
  String orderChanged() =>
      'ഈ ഓർഡർ കാണിച്ച ശേഷം മറ്റൊരാൾ മാറ്റുകയോ ബിൽ ചെയ്യുകയോ ചെയ്തു. '
      'വീണ്ടും പരിശോധിക്കാൻ ഓർഡർ റീലോഡ് ചെയ്യുക.';
  @override
  String orderIneligible() =>
      'ഈ ഓർഡർ ഇനി ഇവിടെ ബിൽ ചെയ്യാൻ കഴിയില്ല. റീലോഡ് ചെയ്യുക, അല്ലെങ്കിൽ Orders പരിശോധിക്കുക.';
  @override
  String orderUncertain() =>
      'ഓർഡർ തുറക്കാൻ സെർവറുമായി ബന്ധപ്പെടാൻ കഴിഞ്ഞില്ല. വീണ്ടും ശ്രമിക്കുന്നതിന് '
      'മുമ്പ് ഓർഡർ റീലോഡ് ചെയ്ത് പരിശോധിക്കുക.';
  @override
  String orderAnswerHint() =>
      'ഈ ഓർഡർ ബിൽ ചെയ്യാൻ "അതെ" എന്നോ ഒഴിവാക്കാൻ "റദ്ദാക്കൂ" എന്നോ പറയുക. '
      'Bill this order അമർത്താനും കഴിയും.';
  @override
  String orderLeftAsIs() =>
      'ഓർഡർ മാറ്റമില്ലാതെ വെച്ചു. ഒന്നും ബിൽ ചെയ്തിട്ടില്ല.';
  @override
  String orderOpenFailed() =>
      'ഓർഡർ തുറക്കാൻ കഴിഞ്ഞില്ല. ദയവായി വീണ്ടും ശ്രമിക്കുക.';
  @override
  String tableUnsupported() =>
      'ടേബിൾ ഓർഡറുകൾ ഇവിടെ ലഭ്യമല്ല. "ഓർഡർ" എന്നും ഓർഡർ നമ്പറും പറയുക. '
      'ഉദാഹരണം: "ഓർഡർ 1048 ബിൽ ചെയ്യൂ".';
  @override
  String noTableOrders(String table) =>
      'ടേബിൾ $table-ൽ ബിൽ ചെയ്യാൻ കാത്തിരിക്കുന്ന ഓർഡറുകൾ ഇല്ല.';
  @override
  String tableChoose(int count, String table) =>
      'ടേബിൾ $table-ൽ $count ഓർഡറുകൾ ഉണ്ട്. സ്ക്രീനിൽ ഒന്ന് തിരഞ്ഞെടുക്കുക.';
  @override
  String tableMismatch() =>
      'ലഭിച്ച ടേബിൾ വിവരം ഈ അഭ്യർത്ഥനയുടേതല്ല. വീണ്ടും ശ്രമിക്കുക.';
  @override
  String tableNetwork(String table) =>
      'ടേബിൾ $table-ലെ ഓർഡറുകൾ കണ്ടെത്താൻ സെർവറുമായി ബന്ധപ്പെടാൻ കഴിഞ്ഞില്ല. കണക്ഷൻ പരിശോധിച്ച് Retry അമർത്തുക.';
  @override
  String tableLoadFailed(String table) =>
      'ടേബിൾ $table-ലെ ഓർഡറുകൾ ലോഡ് ചെയ്യാൻ കഴിഞ്ഞില്ല. ദയവായി വീണ്ടും ശ്രമിക്കുക.';
  @override
  String staleBill() =>
      'ഈ ബിൽ ഇപ്പോൾ നിലവിലുള്ളതല്ല. ദയവായി വീണ്ടും പരിശോധിക്കുക.';
  @override
  String noCart() =>
      'ചെക്കൗട്ടിലേക്ക് തുടരാൻ കാർട്ടിൽ നിന്ന് Voice bill തുറക്കുക.';
  @override
  String offline() => 'വോയ്‌സ് ബില്ലിംഗിന് സെർവറുമായി കണക്ഷൻ വേണം.';
  @override
  String busyCart() =>
      'വോയ്‌സ് വഴി ബിൽ ചെയ്യുന്നതിന് മുമ്പ് നിലവിലെ വിൽപ്പന പൂർത്തിയാക്കുക, '
      'ഹോൾഡ് ചെയ്യുക, അല്ലെങ്കിൽ ക്ലിയർ ചെയ്യുക.';
  @override
  String recognitionUnavailable(String language) =>
      'ഈ ഉപകരണത്തിൽ മലയാളം സംഭാഷണം തിരിച്ചറിയൽ ലഭ്യമല്ല. ഉപകരണത്തിന്റെ '
      'വോയ്‌സ് ടൈപ്പിംഗ് ക്രമീകരണങ്ങളിൽ മലയാളം ചേർക്കുക, അല്ലെങ്കിൽ മറ്റൊരു ഭാഷ '
      'തിരഞ്ഞെടുക്കുക.';
  @override
  String spokenRepliesUnavailable(String language) =>
      'ഈ ഉപകരണത്തിൽ മലയാളത്തിൽ സംസാരിച്ചുള്ള മറുപടി ലഭ്യമല്ല. മറുപടികൾ '
      'സ്ക്രീനിൽ കാണിക്കും.';

  /// "a", "a അല്ലെങ്കിൽ b", "a, b അല്ലെങ്കിൽ c".
  static String orList(List<String> xs) => switch (xs.length) {
    0 => '',
    1 => xs.single,
    _ => '${xs.sublist(0, xs.length - 1).join(', ')} അല്ലെങ്കിൽ ${xs.last}',
  };
}
