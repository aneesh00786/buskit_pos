import 'dart:async';

import '../../core/network/api_exception.dart';
import '../../core/network/pos_api_client.dart';
import '../../core/utils/json_read.dart';
import '../auth/models/pos_token_scope.dart';
import 'models/offline_queue_entry.dart';
import 'models/offline_sale.dart';
import 'offline_storage_service.dart';

/// The server's answer to a successful (or replayed) sync.
class OfflineSyncResult {
  const OfflineSyncResult({
    required this.localSaleId,
    required this.serverSaleId,
    this.saleNumber,
    this.replayed = false,
    this.resolvedBy,
    this.resolvedAt,
    this.resolutionReason,
  });
  final String localSaleId;
  final int serverSaleId;
  final String? saleNumber;
  final bool replayed;

  /// Present when the sale was synced through a manager resolution.
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final String? resolutionReason;

  static OfflineSyncResult? fromJson(Object? json) {
    final m = asMap(json);
    final id = asString(m?['local_sale_id']);
    final server = asInt(m?['server_sale_id']);
    if (id == null || server == null) return null;
    final resolution = asMap(m!['resolution']);
    return OfflineSyncResult(
      localSaleId: id,
      serverSaleId: server,
      saleNumber: asString(m['sale_number']),
      replayed: asBool(m['replayed']) ?? false,
      resolvedBy: asString(resolution?['resolved_by']),
      resolvedAt: DateTime.tryParse(asString(resolution?['resolved_at']) ?? '')
          ?.toUtc(),
      resolutionReason: asString(resolution?['reason']),
    );
  }
}

/// `POST /api/v1/pos/offline-sales/sync` (buskit-web
/// posOfflineSaleSyncService.js). Throws [ApiException] on failure.
abstract class OfflineSyncApi {
  Future<OfflineSyncResult> sync(OfflineSale sale);

  /// `POST /offline-sales/:localSaleId/resolve` (Phase 4): the SIGNED-IN
  /// staff member authorizes syncing [sale] whose original shift closed. The
  /// request names only the reason/note — never the resolver or any scope.
  Future<OfflineSyncResult> resolve(
    OfflineSale sale, {
    required String reason,
    String? note,
  });
}

class ApiOfflineSyncApi implements OfflineSyncApi {
  ApiOfflineSyncApi(this._client);
  final PosApiClient _client;

  @override
  Future<OfflineSyncResult> sync(OfflineSale sale) async {
    final data = await _client.post(
      '/offline-sales/sync',
      body: sale.toSyncJson(),
    );
    return _result(data, sale);
  }

  @override
  Future<OfflineSyncResult> resolve(
    OfflineSale sale, {
    required String reason,
    String? note,
  }) async {
    final data = await _client.post(
      '/offline-sales/${sale.localSaleId}/resolve',
      body: {
        'resolution_reason': reason,
        'resolution_note': ?note,
        'previous_status': sale.status.wire,
        'previous_error_code': ?sale.lastErrorCode,
        'sale': sale.toSyncJson(),
      },
    );
    return _result(data, sale);
  }

  static OfflineSyncResult _result(Object? data, OfflineSale sale) {
    final result = OfflineSyncResult.fromJson(data);
    if (result == null || result.localSaleId != sale.localSaleId) {
      // Treated like a lost response: retried with the same id.
      throw const ApiException(
        kind: ApiErrorKind.server,
        message: 'Unexpected response from the server.',
      );
    }
    return result;
  }
}

/// The controlled reasons a manager can give (server enum, migration 031).
/// OTHER needs a short note.
enum OfflineResolutionReason {
  shiftClosed('SHIFT_CLOSED', 'Shift closed before the sale synced'),
  cashierUnavailable('CASHIER_UNAVAILABLE', 'Cashier unavailable'),
  deviceReplaced('DEVICE_REPLACED', 'Device being replaced'),
  managerApproved('MANAGER_APPROVED', 'Manager approved'),
  other('OTHER', 'Other (note required)');

  const OfflineResolutionReason(this.wire, this.label);
  final String wire;
  final String label;
}

/// The result of a manager resolution, for the dialog.
class OfflineResolutionOutcome {
  const OfflineResolutionOutcome.success(this.sale) : message = null;
  const OfflineResolutionOutcome.failure(this.message, [this.sale]);
  final OfflineSale? sale;
  final String? message;
  bool get ok => message == null;
}

/// Whether [sale] is waiting for a manager resolution: its sync failed
/// because the original shift is no longer open, or it is still queued but
/// was recorded by another cashier than [currentSalesmanId] (only that
/// cashier — or a manager, once the shift has closed — can sync it).
///
/// Who may then act is [offlineCanResolve]: never the sale's own cashier
/// (the server enforces the same four-eyes rule).
bool offlineNeedsManagerResolution(
  OfflineSale sale,
  String? currentSalesmanId,
) =>
    (sale.status == OfflineSaleStatus.syncFailed &&
        sale.lastErrorCode == 'OFFLINE_SHIFT_INVALID') ||
    (sale.status == OfflineSaleStatus.queued &&
        currentSalesmanId != null &&
        sale.salesmanId != currentSalesmanId);

/// What one sync run did (for the UI and tests).
class OfflineSyncRunReport {
  final List<String> synced = [];
  final List<String> failed = [];
  final List<String> retryLater = [];

  /// Sales left for another cashier/device to sync (never sent by this one).
  final List<String> skipped = [];
  DateTime? nextRetryAt;
  bool stoppedEarly = false;
}

/// How a failed attempt is treated.
enum SyncFailureKind {
  /// Network, timeout, 5xx, 429, unexpected response: the outcome may be
  /// unknown — retried later with the SAME local_sale_id (the server's
  /// idempotency returns the original sale if it was created).
  retryable,

  /// The session is not usable right now (401/423): not the sale's fault;
  /// stays queued and the run stops until the cashier signs in again.
  paused,

  /// A business rejection (stock, tax, price, product, shift, scope,
  /// payment, payload mismatch, permission): SYNC_FAILED, never retried
  /// automatically.
  permanent,
}

/// Sends QUEUED offline sales to the server, one at a time, oldest first.
///
/// * One runner per process: concurrent triggers (start-up, reconnect,
///   "Sync now") share the run in progress.
/// * A sale is only sent by the cashier on the device that recorded it (the
///   server rejects anything else); other sales are left QUEUED.
/// * State machine (Phase 1): QUEUED -> SYNCING -> SYNCED | SYNC_FAILED |
///   QUEUED; queue PENDING -> IN_PROGRESS -> DONE | FAILED | PENDING.
/// * Success: the synced copy is written with the server sale id and the
///   queue entry marked DONE before anything is removed (crash-safe: a crash
///   after the server succeeded leaves the sale SYNCING/QUEUED and the next
///   run re-sends the same local_sale_id, which the server replays).
/// * Retryable failure: back to QUEUED, bounded exponential backoff, and the
///   run stops (the connection is likely down — later sales wait).
/// * Permanent failure: SYNC_FAILED with a cashier-facing reason; the run
///   continues with the next sale (each sale is validated on its own).
class OfflineSyncService {
  OfflineSyncService({
    required this.storage,
    required this.api,
    required this.scope,
    DateTime Function()? clock,
    this.baseDelay = const Duration(seconds: 30),
    this.maxDelay = const Duration(minutes: 30),
  }) : _clock = clock ?? DateTime.now;

  final OfflineStorageService storage;
  final OfflineSyncApi api;
  final PosTokenScope? Function() scope;
  final DateTime Function() _clock;
  final Duration baseDelay;
  final Duration maxDelay;

  Future<OfflineSyncRunReport>? _running;

  /// Serializes sync runs and manager resolutions: a sale is never sent by
  /// both at once (the server's idempotency is the final guard).
  Future<void>? _lock;

  Future<T> _exclusive<T>(Future<T> Function() action) {
    final previous = _lock;
    final run = previous == null ? action() : previous.then((_) => action());
    _lock = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  bool get isRunning => _running != null;

  /// Delay before retry number [attempts] + 1: base * 2^(attempts-1),
  /// capped at [maxDelay].
  Duration backoff(int attempts) {
    final n = attempts < 1 ? 0 : attempts - 1;
    final ms = baseDelay.inMilliseconds * (1 << (n > 20 ? 20 : n));
    return ms > maxDelay.inMilliseconds ? maxDelay : Duration(milliseconds: ms);
  }

  /// Runs (or joins) a sync run. [force] ignores retry back-off times (an
  /// explicit "Sync now"); it never retries SYNC_FAILED sales — see [retry].
  Future<OfflineSyncRunReport> syncNow({bool force = false}) =>
      _running ??= _exclusive(() => _run(force))
          .whenComplete(() => _running = null);

  /// Manual retry of a SYNC_FAILED sale with the SAME local_sale_id: back to
  /// QUEUED / PENDING, then a forced run.
  Future<OfflineSyncRunReport> retry(String localSaleId) async {
    final sale = await storage.getSale(localSaleId);
    if (sale != null && sale.status == OfflineSaleStatus.syncFailed) {
      await storage.transitionSale(localSaleId, OfflineSaleStatus.queued);
      final entry = await storage.getQueueEntry(localSaleId);
      if (entry != null && entry.status == OfflineQueueStatus.failed) {
        await storage.transitionQueueEntry(
          localSaleId,
          OfflineQueueStatus.pending,
        );
      }
    }
    // Join a run in progress first so the retried sale is not missed.
    final running = _running;
    if (running != null) await running;
    return syncNow(force: true);
  }

  /// Manager resolution (Phase 4) of a sale recorded on this device whose
  /// original shift closed before it synced: the SIGNED-IN staff member (who
  /// must hold sales.resolve_offline — enforced by the server) authorizes the
  /// sync with [reason] (and [note] for OTHER). Same local_sale_id, so a
  /// retry after a lost response returns the original server sale.
  ///
  /// Success: SYNCED (keeping the original cashier/shift; resolver recorded),
  /// queue DONE. Failure: the sale stays SYNC_FAILED (or QUEUED if it was
  /// still queued and the server could not be reached) with the reason —
  /// never deleted, never marked synced.
  Future<OfflineResolutionOutcome> resolve(
    String localSaleId, {
    required OfflineResolutionReason reason,
    String? note,
  }) => _exclusive(() => _resolve(localSaleId, reason, note?.trim()));

  static const resolutionNoteMinLength = 5;

  static const _resolverProblems = {
    'POS_PERMISSION_DENIED',
    'OFFLINE_SELF_RESOLUTION_NOT_ALLOWED',
  };

  static String resolutionMessageFor(ApiException e) {
    switch (e.errorCode) {
      case 'OFFLINE_STOCK_CONFLICT':
        return 'Cannot synchronize because stock is no longer available.';
      case 'OFFLINE_TAX_MISMATCH':
        return 'Cannot synchronize because tax information changed.';
      case 'OFFLINE_PRICE_MISMATCH':
        return 'Cannot synchronize because the product price changed.';
      case 'OFFLINE_RESOLUTION_NOT_REQUIRED':
        return 'The original shift is still open — its cashier can sync this sale normally.';
      case 'POS_PERMISSION_DENIED':
        return 'You do not have permission to resolve offline sales.';
      case 'OFFLINE_SELF_RESOLUTION_NOT_ALLOWED':
        return 'The cashier who made this sale cannot resolve it; another manager must authorize it.';
    }
    if (classify(e) != SyncFailureKind.permanent) {
      return 'Could not connect to the server. Try the resolution again.';
    }
    return messageFor(e).replaceFirst('Could not sync', 'Cannot synchronize');
  }

  Future<OfflineResolutionOutcome> _resolve(
    String id,
    OfflineResolutionReason reason,
    String? note,
  ) async {
    final s = scope();
    if (s == null) {
      return const OfflineResolutionOutcome.failure(
        'Sign in to resolve offline sales.',
      );
    }
    if (reason == OfflineResolutionReason.other &&
        (note == null || note.length < resolutionNoteMinLength)) {
      return const OfflineResolutionOutcome.failure(
        'Add a short note explaining the resolution.',
      );
    }
    var sale = await storage.getSale(id);
    if (sale == null ||
        sale.companyId != s.companyId ||
        sale.storeId != s.storeId ||
        sale.registerId != s.registerId ||
        sale.deviceId != s.deviceId) {
      return const OfflineResolutionOutcome.failure(
        'This sale cannot be resolved on this device.',
      );
    }
    final wasFailed = sale.status == OfflineSaleStatus.syncFailed;
    if (!wasFailed && sale.status != OfflineSaleStatus.queued) {
      return OfflineResolutionOutcome.failure(
        'This sale does not need a resolution.',
        sale,
      );
    }
    final previousCode = sale.lastErrorCode;
    final previousError = sale.lastError;
    // Into the normal sync states: (SYNC_FAILED ->) QUEUED -> SYNCING;
    // queue (FAILED | PENDING) -> IN_PROGRESS.
    if (wasFailed) {
      sale = await storage.transitionSale(id, OfflineSaleStatus.queued);
    }
    await storage.transitionQueueEntry(id, OfflineQueueStatus.inProgress);
    final sending = await storage.transitionSale(id, OfflineSaleStatus.syncing);
    try {
      final result = await api.resolve(
        // The server receives the exact stored snapshot, last status included.
        wasFailed
            ? sending.copyWith(
                status: OfflineSaleStatus.syncFailed,
                lastErrorCode: previousCode,
              )
            : sending,
        reason: reason.wire,
        note: note == null || note.isEmpty ? null : note,
      );
      final synced = await storage.moveToSynced(
        id,
        serverSaleId: result.serverSaleId,
        serverSaleNumber: result.saleNumber,
        resolvedBy: result.resolvedBy,
        resolvedAt: result.resolvedAt,
        resolutionReason: result.resolutionReason,
      );
      return OfflineResolutionOutcome.success(synced);
    } on ApiException catch (e) {
      final message = resolutionMessageFor(e);
      final kind = classify(e);
      if (_resolverProblems.contains(e.errorCode)) {
        // About WHO asked, not about the sale: restore its previous state so
        // an authorized manager can still resolve it.
        await storage.transitionSale(
          id,
          wasFailed ? OfflineSaleStatus.syncFailed : OfflineSaleStatus.queued,
          error: previousError,
          errorCode: previousCode,
        );
        await storage.transitionQueueEntry(
          id,
          wasFailed ? OfflineQueueStatus.failed : OfflineQueueStatus.pending,
          error: e.errorCode,
        );
        return OfflineResolutionOutcome.failure(
          message,
          await storage.getSale(id),
        );
      }
      if (kind == SyncFailureKind.permanent || wasFailed) {
        // A rejection — or a connection problem while resolving a sale that
        // had already failed: stays SYNC_FAILED. A connection problem keeps
        // the previous code so the resolution can simply be tried again.
        final failed = await storage.transitionSale(
          id,
          OfflineSaleStatus.syncFailed,
          error: message,
          errorCode: kind == SyncFailureKind.permanent
              ? (e.errorCode ?? 'HTTP_${e.statusCode ?? 0}')
              : previousCode,
        );
        await storage.transitionQueueEntry(
          id,
          OfflineQueueStatus.failed,
          error: e.errorCode ?? e.kind.name,
        );
        return OfflineResolutionOutcome.failure(message, failed);
      }
      final queued = await storage.transitionSale(
        id,
        OfflineSaleStatus.queued,
        error: message,
      );
      await storage.transitionQueueEntry(
        id,
        OfflineQueueStatus.pending,
        error: e.errorCode ?? e.kind.name,
      );
      return OfflineResolutionOutcome.failure(message, queued);
    } catch (_) {
      try {
        await storage.transitionSale(
          id,
          wasFailed ? OfflineSaleStatus.syncFailed : OfflineSaleStatus.queued,
          error: 'Could not complete the resolution. Try again.',
          errorCode: previousCode,
        );
        await storage.transitionQueueEntry(
          id,
          wasFailed ? OfflineQueueStatus.failed : OfflineQueueStatus.pending,
        );
      } catch (_) {}
      return const OfflineResolutionOutcome.failure(
        'Could not complete the resolution. Try again.',
      );
    }
  }

  static SyncFailureKind classify(ApiException e) {
    if (e.statusCode == 429) return SyncFailureKind.retryable;
    if (e.statusCode == 423) return SyncFailureKind.paused;
    switch (e.kind) {
      case ApiErrorKind.network:
      case ApiErrorKind.timeout:
      case ApiErrorKind.server:
      case ApiErrorKind.unknown:
      case ApiErrorKind.notFound: // endpoint missing on an older server
        return SyncFailureKind.retryable;
      case ApiErrorKind.unauthorized:
        return SyncFailureKind.paused;
      case ApiErrorKind.forbidden:
      case ApiErrorKind.conflict:
      case ApiErrorKind.validation:
        return SyncFailureKind.permanent;
    }
  }

  static const retryMessage =
      'Could not connect to the server. This sale will be retried.';

  /// Cashier-facing reason for a rejection (never SQL, ids or internals).
  static String messageFor(ApiException e) {
    switch (e.errorCode) {
      case 'OFFLINE_STOCK_CONFLICT':
        return 'Could not sync this sale because stock is no longer available.';
      case 'OFFLINE_TAX_MISMATCH':
        return 'Could not sync this sale because tax information changed.';
      case 'OFFLINE_PRICE_MISMATCH':
        return 'Could not sync this sale because a price changed.';
      case 'OFFLINE_SHIFT_INVALID':
        return 'Could not sync this sale because the original shift is no longer valid.';
      case 'OFFLINE_PRODUCT_INVALID':
        return 'Could not sync this sale because a product is no longer available.';
      case 'OFFLINE_CUSTOMER_INVALID':
        return 'Could not sync this sale because the customer no longer exists.';
      case 'OFFLINE_PAYMENT_INVALID':
        return 'Could not sync this sale because its payment is not valid.';
      case 'OFFLINE_SYNC_PAYLOAD_MISMATCH':
        return 'Could not sync this sale because a different sale with the same reference is already on the server.';
      case 'OFFLINE_DRAFT_ALREADY_COMPLETED':
        return 'Could not sync this sale because it was already completed online.';
      case 'OFFLINE_SCOPE_MISMATCH':
      case 'OFFLINE_DEVICE_SCOPE_MISMATCH':
      case 'OFFLINE_STAFF_SCOPE_MISMATCH':
        return 'Could not sync this sale because it belongs to a different device, register or cashier.';
      case 'POS_PERMISSION_DENIED':
        return 'Could not sync this sale because you do not have permission to record it.';
    }
    if (classify(e) != SyncFailureKind.permanent) return retryMessage;
    return 'Could not sync this sale. Please contact support.';
  }

  Future<OfflineSyncRunReport> _run(bool force) async {
    final report = OfflineSyncRunReport();
    final s = scope();
    if (s == null) {
      report.stoppedEarly = true;
      return report;
    }
    final sales = await storage.getPendingSales(); // oldest first
    for (final sale in sales) {
      if (sale.companyId != s.companyId ||
          sale.storeId != s.storeId ||
          sale.registerId != s.registerId ||
          sale.deviceId != s.deviceId ||
          sale.salesmanId != s.salesmanId) {
        report.skipped.add(sale.localSaleId);
        continue;
      }
      if (sale.status == OfflineSaleStatus.syncFailed) continue;

      var current = sale;
      // A missing or unreadable entry is rebuilt from the sale (the source
      // of truth) instead of leaving the sale stuck "waiting" forever.
      var entry =
          await storage.getQueueEntry(sale.localSaleId) ??
          await storage.ensureQueueEntry(sale.localSaleId);
      // A crash mid-sync leaves SYNCING / IN_PROGRESS: the outcome is unknown,
      // so it is simply re-sent with the same id.
      if (current.status == OfflineSaleStatus.syncing) {
        current = await storage.transitionSale(
          current.localSaleId,
          OfflineSaleStatus.queued,
        );
      }
      if (entry != null && entry.status == OfflineQueueStatus.inProgress) {
        entry = await storage.transitionQueueEntry(
          current.localSaleId,
          OfflineQueueStatus.pending,
          nextAttemptAt: entry.nextAttemptAt,
        );
      }
      // A queued sale whose entry was left FAILED (e.g. a crash during a
      // manager resolution) is back in the normal flow.
      if (entry != null &&
          entry.status == OfflineQueueStatus.failed &&
          current.status == OfflineSaleStatus.queued) {
        entry = await storage.transitionQueueEntry(
          current.localSaleId,
          OfflineQueueStatus.pending,
        );
      }
      if (current.status == OfflineSaleStatus.completedLocal) continue;
      if (entry == null || entry.status != OfflineQueueStatus.pending) {
        continue; // missing/odd entry: start-up recovery repairs it
      }
      final due = entry.nextAttemptAt;
      if (!force && due != null && due.isAfter(_clock())) {
        // Strict oldest-first: later sales wait behind a sale in back-off
        // (they could otherwise take stock the older sale needs).
        report.retryLater.add(current.localSaleId);
        _noteRetry(report, due);
        report.stoppedEarly = true;
        break;
      }

      final outcome = await _syncOne(current, report);
      if (outcome == SyncFailureKind.retryable ||
          outcome == SyncFailureKind.paused) {
        report.stoppedEarly = true;
        break;
      }
    }
    return report;
  }

  void _noteRetry(OfflineSyncRunReport report, DateTime at) {
    final n = report.nextRetryAt;
    if (n == null || at.isBefore(n)) report.nextRetryAt = at;
  }

  /// Returns null on success, otherwise how the failure was treated.
  Future<SyncFailureKind?> _syncOne(
    OfflineSale sale,
    OfflineSyncRunReport report,
  ) async {
    final id = sale.localSaleId;
    final entry = await storage.transitionQueueEntry(
      id,
      OfflineQueueStatus.inProgress,
    );
    final sending = await storage.transitionSale(id, OfflineSaleStatus.syncing);
    try {
      final result = await api.sync(sending);
      await storage.moveToSynced(
        id,
        serverSaleId: result.serverSaleId,
        serverSaleNumber: result.saleNumber,
      );
      report.synced.add(id);
      return null;
    } on ApiException catch (e) {
      final kind = classify(e);
      final message = messageFor(e);
      if (kind == SyncFailureKind.permanent) {
        await storage.transitionSale(
          id,
          OfflineSaleStatus.syncFailed,
          error: message,
          errorCode: e.errorCode ?? 'HTTP_${e.statusCode ?? 0}',
        );
        await storage.transitionQueueEntry(
          id,
          OfflineQueueStatus.failed,
          error: e.errorCode ?? 'HTTP_${e.statusCode ?? 0}',
        );
        report.failed.add(id);
        return kind;
      }
      final next = _clock().add(backoff(entry.attemptCount));
      await storage.transitionSale(
        id,
        OfflineSaleStatus.queued,
        error: kind == SyncFailureKind.paused
            ? 'Sign in again to sync this sale.'
            : message,
        errorCode: e.errorCode,
      );
      await storage.transitionQueueEntry(
        id,
        OfflineQueueStatus.pending,
        error: e.errorCode ?? e.kind.name,
        nextAttemptAt: kind == SyncFailureKind.paused ? null : next,
      );
      report.retryLater.add(id);
      if (kind == SyncFailureKind.retryable) _noteRetry(report, next);
      return kind;
    } catch (e) {
      // Anything unexpected (e.g. local storage): leave it for a retry.
      final next = _clock().add(backoff(entry.attemptCount));
      try {
        await storage.transitionSale(
          id,
          OfflineSaleStatus.queued,
          error: retryMessage,
        );
        await storage.transitionQueueEntry(
          id,
          OfflineQueueStatus.pending,
          nextAttemptAt: next,
        );
      } catch (_) {}
      report.retryLater.add(id);
      _noteRetry(report, next);
      return SyncFailureKind.retryable;
    }
  }
}

/// Whether the signed-in staff member ([currentSalesmanId], holding
/// sales.resolve_offline — [hasPermission]) may resolve [sale]: it needs a
/// resolution and was recorded by someone else.
bool offlineCanResolve(
  OfflineSale sale, {
  required bool hasPermission,
  required String? currentSalesmanId,
}) =>
    hasPermission &&
    currentSalesmanId != null &&
    sale.salesmanId != currentSalesmanId &&
    offlineNeedsManagerResolution(sale, currentSalesmanId);
