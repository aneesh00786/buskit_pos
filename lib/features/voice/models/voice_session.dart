import '../../../core/utils/uuid.dart';
import '../../auth/models/pos_token_scope.dart';
import 'voice_language.dart';

/// Phase 13A — one voice session of one signed-in staff member on one
/// device. Isolation: a session belongs to exactly one staff / device /
/// company scope (taken from the existing signed-in POS session, never
/// invented); a different staff member, device or company always gets a NEW
/// session with a new [voiceSessionId] — nothing is carried across.
class VoiceSession {
  VoiceSession._({
    required this.voiceSessionId,
    required this.startedAt,
    this.companyId,
    this.storeId,
    this.registerId,
    this.deviceId,
    this.staffId,
    this.language = VoiceLanguage.english,
  });

  /// A new session (new UUID) for [scope] — null when nobody is signed in,
  /// in which case every context id stays null.
  /// Phase 13G: the session keeps the [language] it started with; every
  /// request and correction in it uses that language.
  factory VoiceSession.start(
    PosTokenScope? scope, {
    DateTime? now,
    VoiceLanguage language = VoiceLanguage.english,
  }) => VoiceSession._(
    voiceSessionId: generateUuidV4(),
    startedAt: now ?? DateTime.now(),
    companyId: scope?.companyId,
    storeId: scope?.storeId,
    registerId: scope?.registerId,
    deviceId: scope?.deviceId,
    staffId: scope?.salesmanId,
    language: language,
  );

  final String voiceSessionId;
  final DateTime startedAt;
  final int? companyId;
  final int? storeId;
  final int? registerId;
  final int? deviceId;
  final String? staffId;
  final VoiceLanguage language;

  /// True when [scope] is the same staff / device / company this session
  /// was started for (so the session may continue).
  bool belongsTo(PosTokenScope? scope) =>
      companyId == scope?.companyId &&
      deviceId == scope?.deviceId &&
      staffId == scope?.salesmanId;
}

/// One spoken request within a session: its own [requestId] (new UUID per
/// request) and, once recognized, the text. Nothing else — no intent, no
/// POS action (Phase 13B).
class VoiceRequest {
  VoiceRequest._(this.voiceSessionId, this.requestId, this.startedAt);

  factory VoiceRequest.start(VoiceSession session, {DateTime? now}) =>
      VoiceRequest._(
        session.voiceSessionId,
        generateUuidV4(),
        now ?? DateTime.now(),
      );

  final String voiceSessionId;
  final String requestId;
  final DateTime startedAt;
  String text = '';
  DateTime? recognizedAt;
}
