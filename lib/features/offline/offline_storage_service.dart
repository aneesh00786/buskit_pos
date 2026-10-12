import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/offline/json_file_store.dart';
import '../../core/utils/uuid.dart';
import 'models/offline_catalogue.dart';
import 'models/offline_context.dart';
import 'models/offline_queue_entry.dart';
import 'models/offline_sale.dart';
import 'offline_payment_policy.dart';

/// The single entry point for offline POS data. Callers work with typed
/// models; JSON files are an implementation detail of this service.
///
/// Layout (under the app's support directory, `<support>/offline/`):
///   products.json, customers.json, inventory.json   caches (replaceable)
///   settings.json, current_shift.json, device.json  context
///   sales/`<local_sale_id>`.json    one file per offline sale (source of truth)
///   queue/`<local_sale_id>`.json    one outbox entry per unsynced sale
///   synced/`<local_sale_id>`.json   sales the server has confirmed
///
/// Sale + queue are two files, not a transaction. The SALE file is written
/// first and is the source of truth; the queue entry is derived from it and
/// re-created by [initialize] if missing (e.g. the app died between the two
/// writes). So a completed offline sale can never silently drop out of a
/// future sync, and no queue entry can exist for a sale that was not saved.
class OfflineStorageService {
  OfflineStorageService(Directory root, {DateTime Function()? clock})
    : _store = JsonFileStore(root),
      _clock = clock ?? DateTime.now {
    for (final t in _types) {
      _store.registerType(t, current: 1);
    }
  }

  /// The production location: `<application support>/offline`.
  static Future<OfflineStorageService> openDefault() async {
    final base = await getApplicationSupportDirectory();
    final service = OfflineStorageService(
      Directory('${base.path}${Platform.pathSeparator}offline'),
    );
    await service.initialize();
    return service;
  }

  final JsonFileStore _store;
  final DateTime Function() _clock;

  static const _tCatalogue = 'catalogue';
  static const _tCustomers = 'customers';
  static const _tInventory = 'inventory';
  static const _tSettings = 'settings';
  static const _tShift = 'shift';
  static const _tDevice = 'device';
  static const _tSale = 'sale';
  static const _tQueue = 'queue';
  static const _tRecovery = 'payment_recovery';
  static const _types = [
    _tRecovery,
    _tCatalogue,
    _tCustomers,
    _tInventory,
    _tSettings,
    _tShift,
    _tDevice,
    _tSale,
    _tQueue,
  ];

  static const _products = 'products.json';
  static const _customers = 'customers.json';
  static const _inventory = 'inventory.json';
  static const _settings = 'settings.json';
  static const _shift = 'current_shift.json';
  static const _device = 'device.json';
  static const _recovery = 'payment_recovery.json';

  String _salePath(String id) => 'sales/$id.json';
  String _queuePath(String id) => 'queue/$id.json';
  String _syncedPath(String id) => 'synced/$id.json';

  final List<OfflineStorageIssue> _issues = [];

  /// Problems found while reading (corrupt / incompatible files). Offline
  /// sales are never deleted because of them — they are reported here.
  List<OfflineStorageIssue> get issues => List.unmodifiable(_issues);

  List<OfflineProduct>? _productsMemo;
  DateTime? _catalogueCachedAtMemo; // loaded together with _productsMemo

  DateTime get _now => _clock().toUtc();

  void _report(String path, String problem) {
    if (_issues.any((i) => i.path == path && i.problem == problem)) return;
    _issues.add(OfflineStorageIssue(path, problem));
  }

  static void _checkId(String id) {
    if (!OfflineSale.idPattern.hasMatch(id)) {
      throw OfflineStorageException('Invalid local sale id');
    }
  }

  // ---------------------------------------------------------------- setup

  /// Creates the folders, removes temp files left by an interrupted write,
  /// and repairs sale/queue consistency (see the class comment).
  Future<OfflineRecoveryReport> initialize() async {
    _syncedMemo = null;
    await _store.root.create(recursive: true);
    for (final d in const ['sales', 'queue', 'synced', 'drafts']) {
      await _store.ensureDir(d);
    }
    final report = OfflineRecoveryReport();
    report.tempFilesRemoved = await _store.removeStaleTempFiles(const [
      '.',
      'sales',
      'queue',
      'synced',
      'drafts',
    ]);

    // A sale already in synced/ but still in sales/ (crash during the move):
    // the synced copy wins.
    for (final name in await _store.list('synced')) {
      final id = name.substring(0, name.length - 5);
      if (_store.exists(_salePath(id))) {
        await _store.withLocks([_salePath(id), _queuePath(id)], () async {
          await _markQueueDoneHeld(id);
          await _store.deleteHeld(_salePath(id));
        });
        report.finishedSyncMoves.add(id);
      }
    }

    for (final name in await _store.list('sales')) {
      final id = name.substring(0, name.length - 5);
      final r = await _store.read(_salePath(id), type: _tSale);
      final sale = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (sale == null) {
        _report(_salePath(id), r.problem ?? 'unreadable sale');
        report.unreadableSales.add(id);
        continue;
      }
      if (!sale.status.isUnsynced) continue;
      await _store.withLocks([_salePath(id), _queuePath(id)], () async {
        await _repairHeld(sale, report);
      });
    }

    for (final name in await _store.list('queue')) {
      final id = name.substring(0, name.length - 5);
      if (!_store.exists(_salePath(id)) && !_store.exists(_syncedPath(id))) {
        _report(_queuePath(id), 'queue entry without a sale file');
        report.orphanQueueEntries.add(id);
      }
    }
    return report;
  }

  /// Ensures an unsynced sale has its queue entry and is QUEUED. Caller holds
  /// the sale and queue locks. Never creates a second entry for a sale.
  Future<OfflineSale> _repairHeld(
    OfflineSale sale,
    OfflineRecoveryReport? report,
  ) async {
    final id = sale.localSaleId;
    if (_store.exists(_queuePath(id))) {
      // An entry that cannot be read (corrupt, half-written, newer format)
      // would block the sale forever: the SALE file is the source of truth,
      // so the bad entry is moved aside (kept, never deleted) and rebuilt.
      final r = await _store.read(_queuePath(id), type: _tQueue);
      final entry = r.isOk ? OfflineQueueEntry.fromJson(r.data!) : null;
      if (entry == null) {
        final kept = await _store.quarantineHeld(_queuePath(id));
        _report(kept, r.problem ?? 'unreadable queue entry (kept, rebuilt)');
        report?.quarantinedQueueEntries.add(id);
      }
    }
    if (!_store.exists(_queuePath(id))) {
      await _store.writeHeld(
        _queuePath(id),
        type: _tQueue,
        data: _newQueueEntry(id).toJson(),
      );
      report?.recreatedQueueEntries.add(id);
    }
    if (sale.status != OfflineSaleStatus.completedLocal) return sale;
    final queued = sale.copyWith(
      status: OfflineSaleStatus.queued,
      updatedAt: _now,
    );
    await _store.writeHeld(_salePath(id), type: _tSale, data: queued.toJson());
    report?.promotedToQueued.add(id);
    return queued;
  }

  /// Completes the save of a sale whose [recordCompletedSale] was cut short
  /// AFTER the sale file was written (e.g. the queue write failed): makes sure
  /// its queue entry exists and it is QUEUED — the same repair [initialize]
  /// performs at start-up, for one sale, without a restart. Returns the
  /// stored sale, or null when no readable sale file exists for [localSaleId]
  /// (then nothing was saved and the sale may be recorded normally).
  Future<OfflineSale?> finishInterruptedSale(String localSaleId) async {
    _checkId(localSaleId);
    final id = localSaleId;
    return _store.withLocks([_salePath(id), _queuePath(id)], () async {
      if (!_store.exists(_salePath(id))) return null;
      final r = await _store.read(_salePath(id), type: _tSale);
      final sale = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (sale == null) {
        _report(_salePath(id), r.problem ?? 'unreadable sale');
        throw OfflineStorageException('Sale $id exists but cannot be read');
      }
      if (!sale.status.isUnsynced) return sale;
      return _repairHeld(sale, null);
    });
  }

  /// The queue entry of an unsynced sale, repaired if it is missing or
  /// unreadable (see [_repairHeld]); null when the sale itself is missing,
  /// unreadable or not unsynced.
  Future<OfflineQueueEntry?> ensureQueueEntry(String localSaleId) async {
    _checkId(localSaleId);
    final id = localSaleId;
    return _store.withLocks([_salePath(id), _queuePath(id)], () async {
      final r = await _store.read(_salePath(id), type: _tSale);
      final sale = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (sale == null || !sale.status.isUnsynced) return null;
      await _repairHeld(sale, null);
      final q = await _store.read(_queuePath(id), type: _tQueue);
      return q.isOk ? OfflineQueueEntry.fromJson(q.data!) : null;
    });
  }

  OfflineQueueEntry _newQueueEntry(String id) => OfflineQueueEntry(
    localId: id,
    entityType: 'sale',
    operation: 'create',
    status: OfflineQueueStatus.pending,
    attemptCount: 0,
    createdAt: _now,
    updatedAt: _now,
  );

  // ------------------------------------------------------------- catalogue

  Future<void> saveCatalogue(OfflineCatalogue catalogue) async {
    await _store.write(_products, type: _tCatalogue, data: catalogue.toJson());
    _productsMemo = null;
  }

  /// The cached catalogue, or null when missing / unreadable (reported in
  /// [issues]; the caller should refresh it online when possible).
  Future<OfflineCatalogue?> getCatalogue() async {
    final r = await _store.read(_products, type: _tCatalogue);
    if (r.state == JsonReadState.missing) return null;
    final c = r.isOk ? OfflineCatalogue.fromJson(r.data!) : null;
    if (c == null) _report(_products, r.problem ?? 'unreadable catalogue');
    return c;
  }

  Future<List<OfflineProduct>> getProducts() async {
    if (_productsMemo == null) {
      final c = await getCatalogue();
      _catalogueCachedAtMemo = c?.cachedAt;
      _productsMemo = c?.products ?? const [];
    }
    return _productsMemo!;
  }

  /// Phase 14G — when the cached catalogue was last refreshed from the
  /// server (`products.json` `cached_at`, UTC); null when the catalogue is
  /// missing or unreadable (including a missing / malformed timestamp).
  Future<DateTime?> getCatalogueCachedAt() async {
    await getProducts();
    return _catalogueCachedAtMemo;
  }

  Future<OfflineProduct?> getProduct(int productVariationId) async {
    for (final p in await getProducts()) {
      if (p.productVariationId == productVariationId) return p;
    }
    return null;
  }

  /// Exact barcode or product-code match (what a scanner sends).
  Future<OfflineProduct?> findByCode(String code) async {
    final c = code.trim();
    if (c.isEmpty) return null;
    for (final p in await getProducts()) {
      if (p.barcode == c || p.productCode == c) return p;
    }
    return null;
  }

  /// In-memory search over name, variation name, product code and barcode.
  Future<List<OfflineProduct>> searchProducts(
    String query, {
    int limit = 50,
  }) async {
    final q = query.trim().toLowerCase();
    final all = await getProducts();
    if (q.isEmpty) return all.take(limit).toList();
    return all
        .where(
          (p) =>
              p.productName.toLowerCase().contains(q) ||
              (p.variationName?.toLowerCase().contains(q) ?? false) ||
              (p.productCode?.toLowerCase().contains(q) ?? false) ||
              (p.barcode?.toLowerCase().contains(q) ?? false),
        )
        .take(limit)
        .toList();
  }

  // ------------------------------------------------------------- customers

  Future<void> saveCustomers(
    List<OfflineCustomer> customers, {
    DateTime? cachedAt,
  }) => _store.write(
    _customers,
    type: _tCustomers,
    data: {
      'cached_at': (cachedAt ?? _now).toUtc().toIso8601String(),
      'customers': customers.map((c) => c.toJson()).toList(),
    },
  );

  /// Adds or refreshes [customers] (matched by customer id) in the cache,
  /// keeping at most [maxEntries] (the most recently seen win).
  Future<void> upsertCustomers(
    List<OfflineCustomer> customers, {
    int maxEntries = 20000,
  }) async {
    if (customers.isEmpty) return;
    await _store.update(
      _customers,
      type: _tCustomers,
      change: (current) {
        final raw = current?['customers'];
        final byId = <String, OfflineCustomer>{};
        for (final c
            in (raw is List ? raw : const [])
                .map(OfflineCustomer.fromJson)
                .whereType<OfflineCustomer>()) {
          byId[c.customerId] = c;
        }
        for (final c in customers) {
          byId.remove(c.customerId); // re-insert last = most recent
          byId[c.customerId] = c;
        }
        var list = byId.values.toList();
        if (list.length > maxEntries) {
          list = list.sublist(list.length - maxEntries);
        }
        return {
          'cached_at': _now.toUtc().toIso8601String(),
          'customers': list.map((c) => c.toJson()).toList(),
        };
      },
    );
  }

  /// The cached customer with this customer id, or null.
  Future<OfflineCustomer?> getCustomer(String customerId) async {
    for (final c in await getCustomers()) {
      if (c.customerId == customerId) return c;
    }
    return null;
  }

  Future<List<OfflineCustomer>> getCustomers() async {
    final r = await _store.read(_customers, type: _tCustomers);
    if (r.state == JsonReadState.missing) return const [];
    if (!r.isOk) {
      _report(_customers, r.problem!);
      return const [];
    }
    final raw = r.data!['customers'];
    return (raw is List ? raw : const [])
        .map(OfflineCustomer.fromJson)
        .whereType<OfflineCustomer>()
        .toList();
  }

  Future<List<OfflineCustomer>> searchCustomers(
    String query, {
    int limit = 30,
  }) async {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    return (await getCustomers())
        .where(
          (c) =>
              c.fullname.toLowerCase().contains(q) ||
              (c.mobileno?.contains(q) ?? false) ||
              (c.email?.toLowerCase().contains(q) ?? false) ||
              c.customerId.toLowerCase() == q,
        )
        .take(limit)
        .toList();
  }

  // ------------------------------------------------------------- inventory

  Future<void> saveInventory(InventorySnapshot snapshot) =>
      _store.write(_inventory, type: _tInventory, data: snapshot.toJson());

  Future<InventorySnapshot?> getInventory() async {
    final r = await _store.read(_inventory, type: _tInventory);
    if (r.state == JsonReadState.missing) return null;
    final s = r.isOk ? InventorySnapshot.fromJson(r.data!) : null;
    if (s == null) _report(_inventory, r.problem ?? 'unreadable inventory');
    return s;
  }

  /// Offline availability per variation: last server quantity minus the
  /// quantities in local sales the server has not confirmed yet. Derived,
  /// never stored, so it cannot drift from the sales themselves.
  Future<Map<int, OfflineStockLevel>> getStockLevels() async {
    final snapshot = await getInventory();
    if (snapshot == null) return const {};
    final consumed = <int, double>{};
    // Unsynced sales, plus sales the server confirmed AFTER this snapshot was
    // taken (the snapshot cannot include them yet) — until the next refresh.
    final syncedSince = (await getSyncedSales()).where(
      (s) => s.syncedAt != null && s.syncedAt!.isAfter(snapshot.syncedAt),
    );
    for (final s in [...await getPendingSales(), ...syncedSince]) {
      for (final l in s.lines) {
        consumed[l.productVariationId] =
            (consumed[l.productVariationId] ?? 0) + l.quantity;
      }
    }
    return {
      for (final e in snapshot.entries)
        e.productVariationId: OfflineStockLevel(
          productVariationId: e.productVariationId,
          serverQuantity: e.serverQuantity,
          offlineConsumedQuantity: consumed[e.productVariationId] ?? 0,
          lastSyncedAt: snapshot.syncedAt,
        ),
    };
  }

  // ------------------------------------------------------ shift / device

  Future<void> saveCurrentShift(OfflineShiftContext shift) =>
      _store.write(_shift, type: _tShift, data: shift.toJson());

  Future<OfflineShiftContext?> getCurrentShift() async {
    final r = await _store.read(_shift, type: _tShift);
    if (r.state == JsonReadState.missing) return null;
    final s = r.isOk ? OfflineShiftContext.fromJson(r.data!) : null;
    if (s == null) _report(_shift, r.problem ?? 'unreadable shift');
    return s;
  }

  Future<void> clearCurrentShift() => _store.delete(_shift);

  /// This installation's identity — created once, then always the same.
  /// A corrupt device.json is never replaced silently.
  Future<OfflineDeviceInfo> getOrCreateDeviceInfo({
    String? deviceIdentifier,
  }) async {
    final data = await _store.update(
      _device,
      type: _tDevice,
      change: (current) {
        final existing = current == null
            ? null
            : OfflineDeviceInfo.fromJson(current);
        if (existing != null) {
          if (deviceIdentifier == null ||
              existing.deviceIdentifier == deviceIdentifier) {
            return null;
          }
          return existing.copyWith(deviceIdentifier: deviceIdentifier).toJson();
        }
        return OfflineDeviceInfo(
          installationId: generateUuidV4(),
          createdAt: _now,
          deviceIdentifier: deviceIdentifier,
        ).toJson();
      },
    );
    if (data != null) return OfflineDeviceInfo.fromJson(data)!;
    final r = await _store.read(_device, type: _tDevice);
    return OfflineDeviceInfo.fromJson(r.data!)!;
  }

  Future<OfflineSettings> getSettings() async {
    final r = await _store.read(_settings, type: _tSettings);
    if (r.state == JsonReadState.missing) return const OfflineSettings();
    if (!r.isOk) {
      _report(_settings, r.problem!);
      return const OfflineSettings();
    }
    return OfflineSettings.fromJson(r.data!);
  }

  Future<void> saveSettings(OfflineSettings settings) =>
      _store.write(_settings, type: _tSettings, data: settings.toJson());

  // ------------------------------------------------- payment recovery

  /// Phase 6: ids of SERVER sales this device started a provider payment
  /// for (card terminal / UPI QR) and has not yet seen completed. Only the
  /// sale id — the payment state stays on the server (authoritative), and
  /// no provider data or credentials are ever stored here. After a restart
  /// the app asks the server about them (a sale completed just before the
  /// app died is then reported, never charged or created again).
  Future<List<int>> getPaymentRecoveryMarkers() async {
    final r = await _store.read(_recovery, type: _tRecovery);
    if (!r.isOk) return const [];
    final raw = r.data!['sale_ids'];
    return (raw is List ? raw : const [])
        .map((e) => e is int ? e : int.tryParse('$e'))
        .whereType<int>()
        .toList();
  }

  Future<void> addPaymentRecoveryMarker(int saleId) =>
      _changeRecoveryMarkers((ids) => {...ids, saleId});

  Future<void> removePaymentRecoveryMarker(int saleId) =>
      _changeRecoveryMarkers((ids) => ids.where((i) => i != saleId).toSet());

  /// Read-modify-write under the file's lock. An unreadable markers file is
  /// moved aside (kept) and replaced: these are reminders, never money.
  Future<void> _changeRecoveryMarkers(Set<int> Function(List<int>) change) {
    return _store.withLocks([_recovery], () async {
      final r = await _store.read(_recovery, type: _tRecovery);
      var current = <int>[];
      if (r.isOk) {
        final raw = r.data!['sale_ids'];
        current = (raw is List ? raw : const [])
            .map((e) => e is int ? e : int.tryParse('$e'))
            .whereType<int>()
            .toList();
      } else if (r.state != JsonReadState.missing) {
        final kept = await _store.quarantineHeld(_recovery);
        _report(kept, r.problem ?? 'unreadable recovery markers (kept)');
      }
      final next = change(current).toList()..sort();
      await _store.writeHeld(
        _recovery,
        type: _tRecovery,
        data: {
          'sale_ids': next.length > 50 ? next.sublist(next.length - 50) : next,
          'updated_at': _now.toUtc().toIso8601String(),
        },
      );
    });
  }

  // ---------------------------------------------------------------- sales

  /// Stores a sale paid offline and queues it for a future sync.
  ///
  /// Refused (nothing written) when: the sale is not COMPLETED_LOCAL or is
  /// inconsistent; a payment is not allowed offline; there is no open local
  /// shift or the sale's scope differs from it; a line's product is not in
  /// the cached catalogue or is not sellable (PIECE); or the id already
  /// exists.
  Future<OfflineSale> recordCompletedSale(OfflineSale sale) async {
    _checkId(sale.localSaleId);
    if (sale.status != OfflineSaleStatus.completedLocal) {
      throw const OfflineStorageException(
        'Only a COMPLETED_LOCAL sale can be recorded',
      );
    }
    final invalid = sale.validateCompleted();
    if (invalid != null) throw OfflineStorageException(invalid);

    final policy = OfflinePaymentPolicy(await getSettings());
    for (final p in sale.payments) {
      final problem = policy.check(method: p.method);
      if (problem != null) throw OfflinePaymentNotAllowed(p.method, problem);
    }

    final shift = await getCurrentShift();
    if (shift == null || !shift.isOpen) {
      throw const OfflineStorageException(
        'No open shift is stored on this device',
      );
    }
    if (shift.companyId != sale.companyId ||
        shift.storeId != sale.storeId ||
        shift.registerId != sale.registerId ||
        shift.shiftId != sale.shiftId) {
      throw const OfflineStorageException(
        'The sale does not belong to the current shift',
      );
    }
    for (final l in sale.lines) {
      final p = await getProduct(l.productVariationId);
      if (p == null) {
        throw OfflineStorageException(
          'Product ${l.productVariationId} is not in the offline catalogue',
        );
      }
      if (!p.isPosSellable) {
        throw OfflineStorageException(
          'Product ${l.productVariationId} cannot be sold at the POS (${p.sellingMode})',
        );
      }
    }

    final id = sale.localSaleId;
    return _store.withLocks([_salePath(id), _queuePath(id)], () async {
      if (_store.exists(_salePath(id)) || _store.exists(_syncedPath(id))) {
        throw OfflineStorageException('Sale $id already exists');
      }
      final completed = sale.copyWith(
        updatedAt: _now,
        completedAt: sale.completedAt ?? _now,
      );
      // 1. the sale (source of truth), 2. its queue entry, 3. mark queued.
      await _store.writeHeld(
        _salePath(id),
        type: _tSale,
        data: completed.toJson(),
      );
      await _store.writeHeld(
        _queuePath(id),
        type: _tQueue,
        data: _newQueueEntry(id).toJson(),
      );
      final queued = completed.copyWith(
        status: OfflineSaleStatus.queued,
        updatedAt: _now,
      );
      await _store.writeHeld(
        _salePath(id),
        type: _tSale,
        data: queued.toJson(),
      );
      return queued;
    });
  }

  /// Saves a DRAFT (not yet paid) sale; never queued.
  Future<void> saveDraft(OfflineSale sale) async {
    _checkId(sale.localSaleId);
    if (sale.status != OfflineSaleStatus.draft) {
      throw const OfflineStorageException(
        'Only a DRAFT can be saved as a draft',
      );
    }
    await _store.update(
      _salePath(sale.localSaleId),
      type: _tSale,
      change: (current) {
        final existing = current == null ? null : OfflineSale.fromJson(current);
        if (existing != null && existing.status != OfflineSaleStatus.draft) {
          throw const OfflineStorageException('That sale is no longer a draft');
        }
        return sale.copyWith(updatedAt: _now).toJson();
      },
    );
  }

  // ------------------------------------------------- unpaid cart drafts

  /// Phase 6X: the durable copy of an unpaid cart started offline, one file
  /// per cart in drafts/ (its own folder, so sales/ keeps meaning "recorded
  /// sales": drafts are never repaired, queued, synced or counted against
  /// stock). Same [OfflineSale] model with status DRAFT and the cart's stable
  /// local sale id, which the recorded sale later reuses.
  String _cartDraftPath(String id) => 'drafts/$id.json';

  /// Writes (creates or replaces) an unpaid cart's draft. Refused when the
  /// sale is not a DRAFT or when a sale with this id is already recorded
  /// (the cart was paid — its draft must not come back).
  Future<void> saveCartDraft(OfflineSale draft) async {
    _checkId(draft.localSaleId);
    if (draft.status != OfflineSaleStatus.draft) {
      throw const OfflineStorageException(
        'Only a DRAFT can be saved as a cart draft',
      );
    }
    final id = draft.localSaleId;
    await _store.ensureDir('drafts');
    await _store.withLocks([_cartDraftPath(id), _salePath(id)], () async {
      if (_store.exists(_salePath(id)) || _store.exists(_syncedPath(id))) {
        throw OfflineStorageException('Sale $id is already recorded');
      }
      await _store.writeHeld(
        _cartDraftPath(id),
        type: _tSale,
        data: draft.copyWith(updatedAt: _now).toJson(),
      );
    });
  }

  /// Unpaid cart drafts, newest first. A draft whose sale is already recorded
  /// (the app stopped between recording the sale and deleting its draft) is
  /// deleted here, never returned. Unreadable files are reported and kept.
  Future<List<OfflineSale>> getCartDrafts() async {
    final out = <OfflineSale>[];
    for (final name in await _store.list('drafts')) {
      final id = name.substring(0, name.length - 5);
      if (!OfflineSale.idPattern.hasMatch(id)) continue;
      if (_store.exists(_salePath(id)) || _store.exists(_syncedPath(id))) {
        await deleteCartDraft(id);
        continue;
      }
      final r = await _store.read(_cartDraftPath(id), type: _tSale);
      final d = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (d == null || d.status != OfflineSaleStatus.draft) {
        _report(_cartDraftPath(id), r.problem ?? 'unreadable cart draft');
        continue;
      }
      out.add(d);
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  /// Deletes an unpaid cart's draft (missing = nothing to do). Only ever a
  /// file in drafts/: a recorded sale is never touched.
  Future<void> deleteCartDraft(String localSaleId) async {
    _checkId(localSaleId);
    await _store.delete(_cartDraftPath(localSaleId));
  }

  /// The sale (from sales/ or synced/), or null when missing or unreadable
  /// (reported in [issues]; the file is left exactly as it is).
  Future<OfflineSale?> getSale(String localSaleId) async {
    _checkId(localSaleId);
    for (final path in [_salePath(localSaleId), _syncedPath(localSaleId)]) {
      final r = await _store.read(path, type: _tSale);
      if (r.state == JsonReadState.missing) continue;
      final s = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (s == null) _report(path, r.problem ?? 'unreadable sale');
      return s;
    }
    return null;
  }

  /// All readable sales still on the device (not the synced/ archive),
  /// oldest first. Unreadable files are reported, never dropped.
  Future<List<OfflineSale>> getSales() => _listSales('sales');

  /// Sales the server confirmed, kept for local history. Read from disk ONCE
  /// per app run and then kept in memory (updated by [moveToSynced]): the
  /// synced/ folder only grows, and stock levels consult it on every offline
  /// add-to-cart, search and checkout (Phase 5: 3,000 files took ~1 s per
  /// call when re-read every time).
  Future<List<OfflineSale>> getSyncedSales() async =>
      List.unmodifiable(_syncedMemo ??= await _listSales('synced'));

  List<OfflineSale>? _syncedMemo;

  /// File names in sales/ that cannot be read as a sale (kept untouched and
  /// reported) — surfaced to staff so a completed offline sale is never lost
  /// silently.
  Future<List<String>> unreadableSaleFiles() async {
    final out = <String>[];
    for (final name in await _store.list('sales')) {
      final r = await _store.read('sales/$name', type: _tSale);
      if (!r.isOk || OfflineSale.fromJson(r.data!) == null) out.add(name);
    }
    return out;
  }

  /// Sales paid on this device and not yet confirmed by the server.
  Future<List<OfflineSale>> getPendingSales() async =>
      (await getSales()).where((s) => s.status.isUnsynced).toList();

  Future<List<OfflineSale>> _listSales(String dir) async {
    final out = <OfflineSale>[];
    for (final name in await _store.list(dir)) {
      final path = '$dir/$name';
      final r = await _store.read(path, type: _tSale);
      final s = r.isOk ? OfflineSale.fromJson(r.data!) : null;
      if (s == null) {
        _report(path, r.problem ?? 'unreadable sale');
      } else {
        out.add(s);
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  /// Moves a sale through its state machine (not to SYNCED — see
  /// [moveToSynced]). Throws on a transition the state machine forbids.
  Future<OfflineSale> transitionSale(
    String localSaleId,
    OfflineSaleStatus to, {
    String? error,
    String? errorCode,
  }) async {
    _checkId(localSaleId);
    if (to == OfflineSaleStatus.synced) {
      throw const OfflineStorageException(
        'Use moveToSynced with the server sale id',
      );
    }
    final data = await _store.update(
      _salePath(localSaleId),
      type: _tSale,
      change: (current) {
        final s = current == null ? null : OfflineSale.fromJson(current);
        if (s == null) {
          throw OfflineStorageException('Sale $localSaleId not found');
        }
        if (!s.status.canMoveTo(to)) {
          throw OfflineStorageException(
            'Cannot move a ${s.status.wire} sale to ${to.wire}',
          );
        }
        return s
            .copyWith(
              status: to,
              updatedAt: _now,
              lastError: error,
              lastErrorCode: errorCode,
              clearError: error == null,
            )
            .toJson();
      },
    );
    return OfflineSale.fromJson(data!)!;
  }

  /// The server confirmed the sale: write it to synced/ (SYNCED, server id,
  /// sync time), mark its queue entry DONE (kept as a record), then remove
  /// the pending sales/ file. Nothing is deleted before the synced copy is
  /// safely written; a crash in between is finished by [initialize]
  /// (synced/ wins). The synced copy stays for local history.
  Future<OfflineSale> moveToSynced(
    String localSaleId, {
    required int serverSaleId,
    String? serverSaleNumber,
    String? resolvedBy,
    DateTime? resolvedAt,
    String? resolutionReason,
  }) async {
    _checkId(localSaleId);
    return _store.withLocks(
      [
        _salePath(localSaleId),
        _queuePath(localSaleId),
        _syncedPath(localSaleId),
      ],
      () async {
        final r = await _store.read(_salePath(localSaleId), type: _tSale);
        final s = r.isOk ? OfflineSale.fromJson(r.data!) : null;
        if (s == null) {
          throw OfflineStorageException(
            'Sale $localSaleId not found or unreadable',
          );
        }
        if (!s.status.canMoveTo(OfflineSaleStatus.synced)) {
          throw OfflineStorageException(
            'Cannot mark a ${s.status.wire} sale as synced',
          );
        }
        final synced = s.copyWith(
          status: OfflineSaleStatus.synced,
          serverSaleId: serverSaleId,
          serverSaleNumber: serverSaleNumber,
          resolvedBy: resolvedBy,
          resolvedAt: resolvedAt,
          resolutionReason: resolutionReason,
          updatedAt: _now,
          syncedAt: _now,
          clearError: true,
        );
        await _store.writeHeld(
          _syncedPath(localSaleId),
          type: _tSale,
          data: synced.toJson(),
        );
        await _markQueueDoneHeld(localSaleId);
        await _store.deleteHeld(_salePath(localSaleId));
        final memo = _syncedMemo;
        if (memo != null) {
          _syncedMemo = [
            ...memo.where((x) => x.localSaleId != localSaleId),
            synced,
          ];
        }
        return synced;
      },
    );
  }

  /// Rewrites the sale's queue entry as DONE (caller holds the queue lock).
  /// A missing or unreadable entry is left alone — the synced sale file is
  /// the record that matters.
  Future<void> _markQueueDoneHeld(String id) async {
    final r = await _store.read(_queuePath(id), type: _tQueue);
    final e = r.isOk ? OfflineQueueEntry.fromJson(r.data!) : null;
    if (e == null || e.status == OfflineQueueStatus.done) return;
    await _store.writeHeld(
      _queuePath(id),
      type: _tQueue,
      data: e
          .copyWith(
            status: OfflineQueueStatus.done,
            updatedAt: _now,
            clearNextAttempt: true,
          )
          .toJson(),
    );
  }

  // ---------------------------------------------------------------- queue

  Future<List<OfflineQueueEntry>> getQueueEntries() async {
    final out = <OfflineQueueEntry>[];
    for (final name in await _store.list('queue')) {
      final path = 'queue/$name';
      final r = await _store.read(path, type: _tQueue);
      final e = r.isOk ? OfflineQueueEntry.fromJson(r.data!) : null;
      if (e == null) {
        _report(path, r.problem ?? 'unreadable queue entry');
      } else {
        out.add(e);
      }
    }
    out.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return out;
  }

  Future<OfflineQueueEntry?> getQueueEntry(String localSaleId) async {
    _checkId(localSaleId);
    final r = await _store.read(_queuePath(localSaleId), type: _tQueue);
    return r.isOk ? OfflineQueueEntry.fromJson(r.data!) : null;
  }

  /// Moves a queue entry through its state machine. Starting an attempt
  /// (IN_PROGRESS) counts it and stamps the time; a failure keeps the error
  /// and the earliest retry time.
  Future<OfflineQueueEntry> transitionQueueEntry(
    String localSaleId,
    OfflineQueueStatus to, {
    String? error,
    DateTime? nextAttemptAt,
  }) async {
    _checkId(localSaleId);
    final data = await _store.update(
      _queuePath(localSaleId),
      type: _tQueue,
      change: (current) {
        final e = current == null ? null : OfflineQueueEntry.fromJson(current);
        if (e == null) {
          throw OfflineStorageException('Queue entry $localSaleId not found');
        }
        if (!e.status.canMoveTo(to)) {
          throw OfflineStorageException(
            'Cannot move a ${e.status.wire} queue entry to ${to.wire}',
          );
        }
        final starting = to == OfflineQueueStatus.inProgress;
        return e
            .copyWith(
              status: to,
              updatedAt: _now,
              attemptCount: starting ? e.attemptCount + 1 : null,
              lastAttemptAt: starting ? _now : null,
              nextAttemptAt: nextAttemptAt,
              clearNextAttempt: nextAttemptAt == null,
              lastError: error,
              clearError: error == null,
            )
            .toJson();
      },
    );
    return OfflineQueueEntry.fromJson(data!)!;
  }

  // -------------------------------------------------------------- cleanup

  /// Drops the replaceable caches (catalogue, customers, inventory). Sales,
  /// queue, shift and device identity are untouched.
  Future<void> clearCache() async {
    for (final f in const [_products, _customers, _inventory]) {
      await _store.delete(f);
    }
    _productsMemo = null;
  }

  /// Removes all offline data except the device identity — refused while any
  /// sale or queue file is still on the device (unsynced work is never
  /// deleted).
  Future<void> deleteOfflineData() async {
    // Only DONE queue entries (synced sales) may go; anything else — or an
    // entry that cannot be read — means a sale may still need syncing.
    final entries = await getQueueEntries();
    final names = await _store.list('queue');
    if ((await _store.list('sales')).isNotEmpty ||
        entries.length != names.length ||
        entries.any((e) => e.status != OfflineQueueStatus.done)) {
      throw const OfflineStorageException(
        'Unsynced offline sales exist; nothing was deleted',
      );
    }
    await clearCache();
    for (final f in const [_settings, _shift]) {
      await _store.delete(f);
    }
    for (final name in names) {
      await _store.delete('queue/$name');
    }
    for (final name in await _store.list('synced')) {
      await _store.delete('synced/$name');
    }
    // Phase 6X: unpaid cart drafts (never sales) go with the device's data.
    for (final name in await _store.list('drafts')) {
      await _store.delete('drafts/$name');
    }
    _syncedMemo = null;
  }
}

class OfflineStorageIssue {
  const OfflineStorageIssue(this.path, this.problem);

  /// Relative path of the affected file (no contents are kept here).
  final String path;
  final String problem;
}

/// What [OfflineStorageService.initialize] repaired or found.
class OfflineRecoveryReport {
  int tempFilesRemoved = 0;
  final List<String> recreatedQueueEntries = [];
  final List<String> promotedToQueued = [];
  final List<String> finishedSyncMoves = [];
  final List<String> unreadableSales = [];
  final List<String> orphanQueueEntries = [];

  /// Unreadable queue entries moved aside and rebuilt from their sale.
  final List<String> quarantinedQueueEntries = [];
}

class OfflinePaymentNotAllowed extends OfflineStorageException {
  const OfflinePaymentNotAllowed(this.method, String message) : super(message);
  final String method;
}
