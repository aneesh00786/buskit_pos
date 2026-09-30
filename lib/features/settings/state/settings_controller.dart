import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../data/settings_service.dart';
import '../models/pos_device.dart';
import '../models/pos_register.dart';
import '../models/pos_store.dart';

enum SettingsStatus { idle, loading, loaded, error }

/// Store info, registers and devices for this company — most deployments
/// have exactly one store, so it's auto-selected; a simple switcher covers
/// the (rare) multi-store case. No staff/PIN management and no tax settings
/// here — neither has a backend endpoint yet (see the plan's "deferred").
class SettingsController extends ChangeNotifier {
  SettingsController(this._service);
  final SettingsService _service;

  SettingsStatus _status = SettingsStatus.idle;
  List<PosStore> _stores = [];
  PosStore? _selectedStore;
  List<PosRegister> _registers = [];
  List<PosDevice> _devices = [];
  ApiException? _error;
  bool _mutating = false;
  ApiException? _mutationError;
  bool _disposed = false;

  SettingsStatus get status => _status;
  List<PosStore> get stores => List.unmodifiable(_stores);
  PosStore? get selectedStore => _selectedStore;
  List<PosRegister> get registers => List.unmodifiable(_registers);
  List<PosDevice> get devices => List.unmodifiable(_devices);
  ApiException? get error => _error;
  bool get isMutating => _mutating;
  ApiException? get mutationError => _mutationError;

  Future<void> load() async {
    _status = SettingsStatus.loading;
    _error = null;
    _notify();
    try {
      final stores = await _service.listStores();
      _stores = stores;
      _selectedStore = stores.isNotEmpty ? stores.first : null;
      await _loadStoreDetails();
      _status = SettingsStatus.loaded;
    } on ApiException catch (e) {
      _error = e;
      _status = SettingsStatus.error;
    } finally {
      _notify();
    }
  }

  Future<void> retry() => load();

  Future<void> _loadStoreDetails() async {
    final store = _selectedStore;
    if (store == null) {
      _registers = [];
      _devices = [];
      return;
    }
    final results = await Future.wait([
      _service.listRegisters(store.id),
      _service.listDevices(store.id),
    ]);
    _registers = results[0] as List<PosRegister>;
    _devices = results[1] as List<PosDevice>;
  }

  Future<void> selectStore(PosStore store) async {
    if (store.id == _selectedStore?.id) return;
    _selectedStore = store;
    _registers = [];
    _devices = [];
    _notify();
    try {
      await _loadStoreDetails();
    } on ApiException catch (e) {
      _error = e;
    } finally {
      _notify();
    }
  }

  void clearMutationError() {
    if (_mutationError == null) return;
    _mutationError = null;
    _notify();
  }

  Future<bool> updateStore(Map<String, dynamic> fields) async {
    final store = _selectedStore;
    if (_mutating || store == null) return false;
    _mutating = true;
    _mutationError = null;
    _notify();
    try {
      final updated = await _service.updateStore(store.id, fields);
      if (updated != null) {
        _selectedStore = updated;
        final i = _stores.indexWhere((s) => s.id == updated.id);
        if (i != -1) _stores[i] = updated;
      }
      return updated != null;
    } on ApiException catch (e) {
      _mutationError = e;
      return false;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  Future<bool> setRegisterStatus(int id, String status) async {
    if (_mutating) return false;
    _mutating = true;
    _mutationError = null;
    _notify();
    try {
      final updated = await _service.setRegisterStatus(id, status);
      if (updated != null) {
        final i = _registers.indexWhere((r) => r.id == id);
        if (i != -1) _registers[i] = updated;
      }
      return updated != null;
    } on ApiException catch (e) {
      _mutationError = e;
      return false;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  Future<bool> setDeviceStatus(int id, String status) async {
    if (_mutating) return false;
    _mutating = true;
    _mutationError = null;
    _notify();
    try {
      final updated = await _service.setDeviceStatus(id, status);
      if (updated != null) {
        final i = _devices.indexWhere((d) => d.id == id);
        if (i != -1) _devices[i] = updated;
      }
      return updated != null;
    } on ApiException catch (e) {
      _mutationError = e;
      return false;
    } finally {
      _mutating = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
