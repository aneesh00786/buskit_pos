import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/voice_language.dart';
import 'translation_service.dart';

/// Phase 3B.1 — translation by the store server
/// (`POST /translation/translate`), which calls Google Cloud Translation with
/// its own server-side credentials. Only the reviewed text and the two
/// language codes are sent; the staff session identifies who asks. Nothing
/// is logged or kept here; a failure is always an error (never the source
/// text in place of a translation).
class ApiTranslationService implements TranslationService {
  ApiTranslationService(this._client);
  final PosApiClient _client;

  @override
  String? get providerName =>
      'Google Cloud Translation (through the store server)';

  /// The configured languages; the server checks its own allowlist too.
  @override
  bool supports(VoiceLanguage source, VoiceLanguage target) =>
      source != target && source.isSupported && target.isSupported;

  /// Phase 3B.1 — `GET /translation/languages`: whether the store server's
  /// translation is set up and which languages are switched on (English
  /// source only, targets enabled deliberately). Languages the app does not
  /// know are ignored; any failure means "not available".
  @override
  Future<TranslationSupport> loadSupport() async {
    try {
      final m = asMap(await _client.get('/translation/languages'));
      if (m == null || m['available'] != true) return TranslationSupport.none;
      Set<VoiceLanguage> langs(Object? codes) => {
        for (final c in asList(codes))
          ...VoiceLanguage.supported.where((l) => l.code == c),
      };
      final max = m['max_chars'];
      return TranslationSupport(
        available: true,
        sources: langs(m['source_languages']),
        targets: langs(m['target_languages']),
        maxChars: max is int && max > 0 ? max : TranslationRequest.maxChars,
      );
    } on Object {
      // Never throws: unreachable / refused / unreadable means "not set up".
      return TranslationSupport.none;
    }
  }

  @override
  Future<TranslationResult> translate(TranslationRequest request) async {
    final Object? data;
    try {
      data = await _client.post(
        '/translation/translate',
        body: {
          'text': request.text,
          'source_language': request.source.code,
          'target_language': request.target.code,
        },
      );
    } on ApiException catch (e) {
      return TranslationResult.failed(errorFor(e));
    }
    // Only a real string is a translation (a number or anything else is a
    // malformed answer, never shown as text).
    final raw = asMap(data)?['translated_text'];
    final text = raw is String ? raw.trim() : null;
    if (text == null || text.isEmpty) {
      return const TranslationResult.failed(TranslationErrorKind.malformed);
    }
    return TranslationResult.translated(text);
  }

  /// The server's error code first, then its HTTP status.
  static TranslationErrorKind errorFor(ApiException e) {
    switch (e.errorCode) {
      case 'POS_TRANSLATION_EMPTY':
        return TranslationErrorKind.emptyText;
      case 'POS_TRANSLATION_SAME_LANGUAGE':
        return TranslationErrorKind.sameLanguage;
      case 'POS_TRANSLATION_UNSUPPORTED_LANGUAGE':
        return TranslationErrorKind.unsupportedPair;
      case 'POS_TRANSLATION_TOO_LONG':
        return TranslationErrorKind.tooLong;
      case 'POS_TRANSLATION_UNAVAILABLE':
        return TranslationErrorKind.unavailable;
      case 'POS_TRANSLATION_PROVIDER_DENIED':
        return TranslationErrorKind.permissionDenied;
      case 'POS_TRANSLATION_RATE_LIMITED':
      case 'POS_TRANSLATION_BUSY':
        return TranslationErrorKind.rateLimited;
      case 'POS_TRANSLATION_TIMEOUT':
        return TranslationErrorKind.timeout;
      case 'POS_TRANSLATION_NETWORK':
        return TranslationErrorKind.network;
      case 'POS_TRANSLATION_MALFORMED':
        return TranslationErrorKind.malformed;
      case 'POS_TRANSLATION_UPSTREAM_REJECTED':
      case 'POS_TRANSLATION_UPSTREAM_ERROR':
        return TranslationErrorKind.upstream;
    }
    if (e.statusCode == 429) return TranslationErrorKind.rateLimited;
    if (e.statusCode == 504) return TranslationErrorKind.timeout;
    if (e.statusCode == 503) return TranslationErrorKind.unavailable;
    return switch (e.kind) {
      ApiErrorKind.network => TranslationErrorKind.network,
      ApiErrorKind.timeout => TranslationErrorKind.timeout,
      ApiErrorKind.unauthorized ||
      ApiErrorKind.forbidden => TranslationErrorKind.permissionDenied,
      ApiErrorKind.validation => TranslationErrorKind.unsupportedPair,
      ApiErrorKind.notFound => TranslationErrorKind.unavailable,
      _ => TranslationErrorKind.upstream,
    };
  }
}
