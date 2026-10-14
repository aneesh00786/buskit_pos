import '../models/voice_language.dart';

/// Phase 3B — staff-to-customer translation, independent of any provider.
/// Nothing here knows about carts, sales, payments or tax, and nothing is
/// logged or stored: a request and its result live only in memory for as
/// long as the translation screen shows them.

/// Why a translation could not be produced. A failure NEVER carries text
/// that could be mistaken for a translation.
enum TranslationErrorKind {
  /// Nothing (or only spaces) to translate.
  emptyText,

  /// Source and target are the same language.
  sameLanguage,

  /// The provider does not translate between these two languages.
  unsupportedPair,

  /// No translation provider is set up / approved on this installation.
  unavailable,

  network,
  timeout,

  /// The provider answered with something that is not a translation.
  malformed,

  /// The staff member cancelled, or the request was replaced by a newer one.
  cancelled,

  /// Phase 3B.1: longer than [TranslationRequest.maxChars].
  tooLong,

  /// Phase 3B.1: not allowed (no Jacky licence / session, or the server's
  /// provider account is not permitted).
  permissionDenied,

  /// Phase 3B.1: too many translations right now.
  rateLimited,

  /// Phase 3B.1: the provider failed (5xx or refused the text).
  upstream,
}

class TranslationRequest {
  const TranslationRequest({
    required this.source,
    required this.target,
    required this.text,
  });
  final VoiceLanguage source;
  final VoiceLanguage target;

  /// The text to translate, exactly as reviewed by the staff member.
  final String text;

  /// Phase 3B.1: the same limit as the server (POS_TRANSLATION_MAX_CHARS
  /// default), checked here first so an oversized text is never sent.
  static const maxChars = 5000;

  /// Null when the request may be sent; otherwise why it may not (checked
  /// before any provider is called).
  TranslationErrorKind? get problem {
    if (text.trim().isEmpty) return TranslationErrorKind.emptyText;
    if (source == target) return TranslationErrorKind.sameLanguage;
    if (text.trim().runes.length > maxChars) {
      return TranslationErrorKind.tooLong;
    }
    return null;
  }
}

/// Either [text] (a translation) or [error] — never both.
class TranslationResult {
  const TranslationResult.translated(String this.text) : error = null;
  const TranslationResult.failed(TranslationErrorKind this.error) : text = null;

  final String? text;
  final TranslationErrorKind? error;
  bool get isTranslated => text != null;
}

/// Phase 3B.1 — what translation is switched on for (from the provider /
/// the store server): whether it is set up at all, and which source and
/// target languages are enabled. A pair is offered only when [allows] it.
class TranslationSupport {
  const TranslationSupport({
    required this.available,
    this.sources = const {},
    this.targets = const {},
    this.maxChars = TranslationRequest.maxChars,
  });

  /// Nothing set up (or the server could not be asked).
  static const none = TranslationSupport(available: false);

  final bool available;
  final Set<VoiceLanguage> sources;
  final Set<VoiceLanguage> targets;
  final int maxChars;

  bool allows(VoiceLanguage source, VoiceLanguage target) =>
      available &&
      source != target &&
      sources.contains(source) &&
      targets.contains(target);
}

/// A translation provider. Implementations must not log the text, must not
/// keep it after answering, and must return [TranslationResult.failed] (or
/// throw) rather than ever echo the source text back as a "translation".
abstract class TranslationService {
  /// A short name for the provider shown to staff ("On-device", ...), or
  /// null when no provider is set up.
  String? get providerName;

  /// Whether [source] -> [target] can be translated (no network call).
  bool supports(VoiceLanguage source, VoiceLanguage target);

  /// Phase 3B.1: which languages are switched on (asked once per screen).
  /// Never throws: a failure means [TranslationSupport.none].
  Future<TranslationSupport> loadSupport();

  Future<TranslationResult> translate(TranslationRequest request);
}

/// The default until a provider is approved: translation is plainly
/// unavailable. It never returns the original text as if translated.
class UnavailableTranslationService implements TranslationService {
  const UnavailableTranslationService();

  @override
  String? get providerName => null;

  @override
  bool supports(VoiceLanguage source, VoiceLanguage target) => false;

  @override
  Future<TranslationSupport> loadSupport() async => TranslationSupport.none;

  @override
  Future<TranslationResult> translate(TranslationRequest request) async =>
      const TranslationResult.failed(TranslationErrorKind.unavailable);
}
