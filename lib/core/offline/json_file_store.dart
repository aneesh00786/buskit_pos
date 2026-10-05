import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// Low-level JSON document storage for offline POS data. The ONLY code in the
/// app that touches the offline files; everything else goes through
/// `OfflineStorageService` with typed models.
///
/// Every document is an envelope:
///   `{ "schema_version": N, "type": "<doc type>", "data": <payload> }`
///
/// Writes are atomic: the new content is written and flushed to a temporary
/// file in the same directory, then renamed over the target (an atomic
/// replace on the platforms we ship), so a crash leaves either the old or the
/// new document — never a truncated one.
///
/// Writes to the same key are serialised in-process (one lock per key);
/// [update] does read-modify-write under that lock so two updates cannot lose
/// each other's changes. Not designed for several processes sharing a folder.
class JsonFileStore {
  JsonFileStore(this.root);

  /// The offline storage root (an application-owned directory).
  final Directory root;

  final Map<String, Future<void>> _locks = {};
  final Map<String, Map<int, Map<String, dynamic> Function(Map<String, dynamic>)>> _migrations = {};
  final Map<String, int> _currentVersions = {};
  final Random _random = Random.secure();

  Future<void> ensureDir(String relative) => Directory(_path(relative)).create(recursive: true);

  /// Declares the current schema version of a document type, with the
  /// upgrade steps from older versions: `{1: v1ToV2, 2: v2ToV3}`. A document
  /// older than [current] is upgraded on read (and written back on its next
  /// save); a NEWER one is reported as incompatible, never guessed at.
  void registerType(String type, {required int current, Map<int, Map<String, dynamic> Function(Map<String, dynamic>)> migrations = const {}}) {
    _currentVersions[type] = current;
    _migrations[type] = Map.of(migrations);
  }

  int currentVersion(String type) => _currentVersions[type] ?? 1;

  String _path(String relative) => '${root.path}${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

  bool exists(String relative) => File(_path(relative)).existsSync();

  /// File names (not paths) of `*.json` documents directly inside [dir], sorted.
  Future<List<String>> list(String dir) async {
    final d = Directory(_path(dir));
    if (!await d.exists()) return const [];
    final names = <String>[];
    await for (final e in d.list(followLinks: false)) {
      if (e is File) {
        final name = e.uri.pathSegments.last;
        if (name.endsWith('.json')) names.add(name);
      }
    }
    names.sort();
    return names;
  }

  /// Reads and validates a document. Never throws for bad content: the
  /// result says what was found.
  Future<JsonReadResult> read(String relative, {required String type}) async {
    final f = File(_path(relative));
    if (!await f.exists()) return const JsonReadResult.missing();
    String raw;
    try {
      raw = await f.readAsString();
    } on FileSystemException catch (e) {
      return JsonReadResult.corrupt('unreadable: ${e.osError?.message ?? e.message}');
    }
    if (raw.trim().isEmpty) return const JsonReadResult.corrupt('empty file');
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return const JsonReadResult.corrupt('malformed JSON');
    }
    if (decoded is! Map<String, dynamic> || decoded['data'] is! Map<String, dynamic> || decoded['schema_version'] is! int) {
      return const JsonReadResult.corrupt('not a versioned document');
    }
    if (decoded['type'] != type) return JsonReadResult.corrupt('unexpected document type ${decoded['type']}');
    var version = decoded['schema_version'] as int;
    var data = decoded['data'] as Map<String, dynamic>;
    final current = currentVersion(type);
    if (version > current) return JsonReadResult.incompatible(version);
    final steps = _migrations[type] ?? const {};
    while (version < current) {
      final step = steps[version];
      if (step == null) return JsonReadResult.incompatible(version);
      data = step(data);
      version++;
    }
    return JsonReadResult.ok(data, version);
  }

  /// Atomically replaces [relative] with [data] at the type's current version.
  Future<void> write(String relative, {required String type, required Map<String, dynamic> data}) =>
      _withLock(relative, () => _writeUnlocked(relative, type, data));

  /// Read-modify-write under the key's lock. [change] receives the current
  /// payload (null when the file is missing) and returns the new one, or null
  /// to leave the file untouched. A corrupt or incompatible existing document
  /// is never overwritten: [OfflineStorageException] is thrown instead.
  Future<Map<String, dynamic>?> update(
    String relative, {
    required String type,
    required FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic>? current) change,
  }) {
    return _withLock(relative, () async {
      final r = await read(relative, type: type);
      if (r.state == JsonReadState.corrupt || r.state == JsonReadState.incompatible) {
        throw OfflineStorageException('Refusing to overwrite $relative: ${r.problem}');
      }
      final next = await change(r.data);
      if (next != null) await _writeUnlocked(relative, type, next);
      return next;
    });
  }

  /// Deletes a document (no-op if missing), under its lock.
  Future<void> delete(String relative) => _withLock(relative, () async {
    final f = File(_path(relative));
    if (await f.exists()) await f.delete();
  });

  /// Runs [action] while holding the locks of every key in [keys] (taken in
  /// a fixed order, so two multi-key operations cannot deadlock).
  Future<T> withLocks<T>(List<String> keys, Future<T> Function() action) {
    final sorted = [...{...keys}]..sort();
    Future<T> run(int i) => i == sorted.length ? action() : _withLock(sorted[i], () => run(i + 1));
    return run(0);
  }

  /// Unlocked write — only for callers already inside [withLocks].
  Future<void> writeHeld(String relative, {required String type, required Map<String, dynamic> data}) =>
      _writeUnlocked(relative, type, data);

  /// Unlocked delete — only for callers already inside [withLocks].
  Future<void> deleteHeld(String relative) async {
    final f = File(_path(relative));
    if (await f.exists()) await f.delete();
  }

  Future<void> _writeUnlocked(String relative, String type, Map<String, dynamic> data) async {
    final target = File(_path(relative));
    await target.parent.create(recursive: true);
    final tmp = File('${target.path}.tmp-${_random.nextInt(1 << 32).toRadixString(16)}');
    final envelope = {'schema_version': currentVersion(type), 'type': type, 'data': data};
    try {
      final sink = tmp.openWrite();
      sink.write(jsonEncode(envelope));
      await sink.flush();
      await sink.close();
      await tmp.rename(target.path);
    } catch (e) {
      if (await tmp.exists()) {
        try {
          await tmp.delete();
        } catch (_) {}
      }
      throw OfflineStorageException('Could not save $relative: $e');
    }
  }

  /// Removes temporary files left behind by a crash during a write (the
  /// target document is intact: rename is the last step). Returns how many.
  Future<int> removeStaleTempFiles(List<String> dirs) async {
    var removed = 0;
    for (final dir in dirs) {
      final d = Directory(_path(dir));
      if (!await d.exists()) continue;
      await for (final e in d.list(followLinks: false)) {
        if (e is File && e.uri.pathSegments.last.contains('.json.tmp-')) {
          try {
            await e.delete();
            removed++;
          } catch (_) {}
        }
      }
    }
    return removed;
  }

  Future<T> _withLock<T>(String key, Future<T> Function() action) {
    final previous = _locks[key] ?? Future<void>.value();
    final done = Completer<void>();
    final mine = done.future;
    _locks[key] = mine;
    return previous.then((_) => action()).whenComplete(() {
      done.complete();
      if (identical(_locks[key], mine)) _locks.remove(key);
    });
  }
}

enum JsonReadState { ok, missing, corrupt, incompatible }

class JsonReadResult {
  const JsonReadResult._(this.state, this.data, this.version, this.problem);
  const JsonReadResult.missing() : this._(JsonReadState.missing, null, null, null);
  const JsonReadResult.corrupt(String problem) : this._(JsonReadState.corrupt, null, null, problem);
  JsonReadResult.incompatible(int version) : this._(JsonReadState.incompatible, null, version, 'unsupported schema version $version');
  const JsonReadResult.ok(Map<String, dynamic> data, int version) : this._(JsonReadState.ok, data, version, null);

  final JsonReadState state;
  final Map<String, dynamic>? data;
  final int? version;
  final String? problem;

  bool get isOk => state == JsonReadState.ok;
}

class OfflineStorageException implements Exception {
  const OfflineStorageException(this.message);
  final String message;
  @override
  String toString() => 'OfflineStorageException: $message';
}
