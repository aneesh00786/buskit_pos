import 'dart:io';

import 'package:flutter/foundation.dart';

/// Phase 6ZA — only ONE copy of the POS may own a computer's offline storage.
///
/// The offline store's own locks are per process (in memory), so two copies of
/// the app writing the same folder could interleave writes. On desktop the app
/// therefore takes an OS-level exclusive lock on a file inside the same
/// application-support folder before anything else runs, and keeps it open for
/// the life of the process. The operating system releases it when the process
/// ends — also after a crash or a forced quit — so a stale lock cannot block
/// the next start. Android / iOS are not affected (one app process by design).
enum InstanceOwnership {
  /// This process owns the storage.
  acquired,

  /// Another running copy owns it.
  heldElsewhere,

  /// The lock could not be checked (folder not writable, I/O error): the app
  /// does not start, rather than risk two writers.
  failed,
}

class InstanceClaim {
  const InstanceClaim(this.ownership, {this.detail});
  final InstanceOwnership ownership;

  /// Diagnostic text for [InstanceOwnership.failed] (never shown verbatim).
  final String? detail;

  bool get acquired => ownership == InstanceOwnership.acquired;
}

class SingleInstanceLock {
  SingleInstanceLock._();

  static const fileName = '.thrivewoo_pos.instance.lock';

  /// The open, locked file of this process (kept for the process lifetime).
  static RandomAccessFile? _held;
  static String? _heldPath;

  /// True on the platforms that need the guard (desktop).
  static bool appliesTo(TargetPlatform platform) =>
      !kIsWeb &&
      (platform == TargetPlatform.macOS ||
          platform == TargetPlatform.windows ||
          platform == TargetPlatform.linux);

  /// Phase 6ZB: waits before reporting "held elsewhere". Windows releases the
  /// locks of a terminated process but documents that this may be delayed;
  /// a short re-check keeps a restart right after a crash from being refused.
  /// It never lets a second copy in while the first is still running.
  static const retryDelays = [
    Duration(milliseconds: 500),
    Duration(milliseconds: 1500),
  ];

  /// Windows ERROR_SHARING_VIOLATION: the file is held open exclusively by
  /// another process — i.e. another copy, not a broken folder.
  static const _windowsSharingViolation = 32;

  /// How a failure to OPEN the lock file is reported (pure; tested).
  static InstanceOwnership classifyOpenFailure(
    FileSystemException e, {
    required bool windows,
  }) => windows && e.osError?.errorCode == _windowsSharingViolation
      ? InstanceOwnership.heldElsewhere
      : InstanceOwnership.failed;

  /// Claims [directory] for this process. Idempotent within one process.
  static Future<InstanceClaim> acquire(
    Directory directory, {
    List<Duration> retry = retryDelays,
  }) async {
    final path = '${directory.path}${Platform.pathSeparator}$fileName';
    if (_held != null && _heldPath == path) {
      return const InstanceClaim(InstanceOwnership.acquired);
    }
    for (var attempt = 0; ; attempt++) {
      final claim = await _tryOnce(directory, path);
      if (claim.ownership != InstanceOwnership.heldElsewhere ||
          attempt >= retry.length)
        return claim;
      await Future<void>.delayed(retry[attempt]);
    }
  }

  static Future<InstanceClaim> _tryOnce(
    Directory directory,
    String path,
  ) async {
    RandomAccessFile? file;
    try {
      await directory.create(recursive: true);
      file = await File(path).open(mode: FileMode.append);
    } on FileSystemException catch (e) {
      return InstanceClaim(
        classifyOpenFailure(e, windows: Platform.isWindows),
        detail: e.message,
      );
    }
    try {
      // Non-blocking (POSIX fcntl / Windows LockFileEx with FAIL_IMMEDIATELY):
      // fails at once when another process holds it.
      await file.lock(FileLock.exclusive);
    } on FileSystemException {
      await file.close();
      return const InstanceClaim(InstanceOwnership.heldElsewhere);
    }
    _held = file;
    _heldPath = path;
    return const InstanceClaim(InstanceOwnership.acquired);
  }

  /// Releases this process's claim (tests; the app keeps it until it exits).
  static Future<void> release() async {
    final f = _held;
    _held = null;
    _heldPath = null;
    if (f == null) return;
    try {
      await f.unlock();
    } catch (_) {}
    await f.close();
  }
}
