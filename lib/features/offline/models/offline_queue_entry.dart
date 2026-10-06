import '../../../core/utils/json_read.dart';

/// Status of an outbox entry (`queue/<local_sale_id>.json`).
///
///   pending     waiting to be sent by a future sync
///   inProgress  being sent (a crash leaves it here; it can be retried)
///   failed      the last attempt failed permanently (a business rejection);
///               only a manual retry moves it back to pending
///   done        the server confirmed it (kept as a record next to the synced sale)
enum OfflineQueueStatus {
  pending('PENDING'),
  inProgress('IN_PROGRESS'),
  failed('FAILED'),
  done('DONE');

  const OfflineQueueStatus(this.wire);
  final String wire;

  static OfflineQueueStatus? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }

  static const _next = {
    OfflineQueueStatus.pending: {OfflineQueueStatus.inProgress},
    OfflineQueueStatus.inProgress: {
      OfflineQueueStatus.done,
      OfflineQueueStatus.failed,
      OfflineQueueStatus.pending,
    },
    OfflineQueueStatus.failed: {
      OfflineQueueStatus.inProgress,
      OfflineQueueStatus.pending,
    },
    OfflineQueueStatus.done: <OfflineQueueStatus>{},
  };

  bool canMoveTo(OfflineQueueStatus to) => _next[this]!.contains(to);
}

/// One outbox record: everything a future sync needs to (re)try uploading
/// one local entity. The payload itself is the entity's own file; this entry
/// references it by id. [idempotencyKey] (the local sale id) must be sent
/// with every attempt so retries are safe.
class OfflineQueueEntry {
  const OfflineQueueEntry({
    required this.localId,
    required this.entityType,
    required this.operation,
    required this.status,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.lastAttemptAt,
    this.nextAttemptAt,
    this.lastError,
  });

  /// The local entity id (local_sale_id).
  final String localId;

  /// 'sale' (the only entity type in this phase).
  final String entityType;

  /// 'create'.
  final String operation;
  final OfflineQueueStatus status;
  final int attemptCount;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastAttemptAt;
  final DateTime? nextAttemptAt;
  final String? lastError;

  String get idempotencyKey => localId;

  OfflineQueueEntry copyWith({
    OfflineQueueStatus? status,
    int? attemptCount,
    DateTime? updatedAt,
    DateTime? lastAttemptAt,
    DateTime? nextAttemptAt,
    String? lastError,
    bool clearNextAttempt = false,
    bool clearError = false,
  }) => OfflineQueueEntry(
    localId: localId,
    entityType: entityType,
    operation: operation,
    status: status ?? this.status,
    attemptCount: attemptCount ?? this.attemptCount,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
    nextAttemptAt: clearNextAttempt
        ? null
        : (nextAttemptAt ?? this.nextAttemptAt),
    lastError: clearError ? null : (lastError ?? this.lastError),
  );

  Map<String, dynamic> toJson() => {
    'local_id': localId,
    'entity_type': entityType,
    'operation': operation,
    'status': status.wire,
    'attempt_count': attemptCount,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'last_attempt_at': lastAttemptAt?.toUtc().toIso8601String(),
    'next_attempt_at': nextAttemptAt?.toUtc().toIso8601String(),
    'last_error': lastError,
  };

  static OfflineQueueEntry? fromJson(Map<String, dynamic> m) {
    final id = asString(m['local_id']);
    final type = asString(m['entity_type']);
    final op = asString(m['operation']);
    final status = OfflineQueueStatus.fromWire(asString(m['status']));
    final created = DateTime.tryParse(asString(m['created_at']) ?? '');
    final updated = DateTime.tryParse(asString(m['updated_at']) ?? '');
    if (id == null ||
        type == null ||
        op == null ||
        status == null ||
        created == null ||
        updated == null) {
      return null;
    }
    return OfflineQueueEntry(
      localId: id,
      entityType: type,
      operation: op,
      status: status,
      attemptCount: asInt(m['attempt_count']) ?? 0,
      createdAt: created.toUtc(),
      updatedAt: updated.toUtc(),
      lastAttemptAt: DateTime.tryParse(asString(m['last_attempt_at']) ?? '')
          ?.toUtc(),
      nextAttemptAt: DateTime.tryParse(asString(m['next_attempt_at']) ?? '')
          ?.toUtc(),
      lastError: asString(m['last_error']),
    );
  }
}
