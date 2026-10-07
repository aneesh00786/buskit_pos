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
}

/// Phase 13F's English wording, unchanged.
class EnglishVoiceResponses implements VoiceResponses {
  const EnglishVoiceResponses();

  static const exampleHint =
      'Say for example "make the coffee three", "remove the water" or "add one water".';

  @override
  String preview(QuickBillPreview? p) {
    if (p == null) return "I couldn't check the bill. Please try again.";
    if (p.isReady) {
      return 'Your bill is ready. The total is ${formatMoney(p.total)}. '
          'Please verify it before confirming.';
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
  String notACorrection() => "That wasn't a correction. $exampleHint";

  @override
  String allRemoved() =>
      'All items were removed. Speak again to start a new bill.';

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

  /// "a", "a അല്ലെങ്കിൽ b", "a, b അല്ലെങ്കിൽ c".
  static String orList(List<String> xs) => switch (xs.length) {
    0 => '',
    1 => xs.single,
    _ => '${xs.sublist(0, xs.length - 1).join(', ')} അല്ലെങ്കിൽ ${xs.last}',
  };
}
