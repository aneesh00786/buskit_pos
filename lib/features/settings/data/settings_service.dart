import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../models/pos_device.dart';
import '../models/pos_register.dart';
import '../models/pos_store.dart';

abstract class SettingsService {
  /// Every store visible to this company. Most deployments have exactly one.
  Future<List<PosStore>> listStores();
  Future<PosStore?> updateStore(int id, Map<String, dynamic> fields);
  Future<List<PosRegister>> listRegisters(int storeId);
  Future<PosRegister?> setRegisterStatus(int id, String status);
  Future<List<PosDevice>> listDevices(int storeId);
  Future<PosDevice?> setDeviceStatus(int id, String status);
}

/// Verified against the backend: `GET /stores`, `PATCH /stores/:id`,
/// `GET /stores/:storeId/registers`, `PATCH /registers/:id/status`,
/// `GET /stores/:storeId/devices`, `PATCH /devices/:id/status` — all already
/// existed (Phase 2/2.1); this is the first Flutter surface to use them.
/// Company scope always comes from the device/staff token.
class ApiSettingsService implements SettingsService {
  ApiSettingsService(this._client);
  final PosApiClient _client;

  @override
  Future<List<PosStore>> listStores() async {
    final data = await _client.get('/stores');
    return asList(data).map(PosStore.fromJson).whereType<PosStore>().toList();
  }

  @override
  Future<PosStore?> updateStore(int id, Map<String, dynamic> fields) async {
    final data = await _client.patch('/stores/$id', body: fields);
    return PosStore.fromJson(data);
  }

  @override
  Future<List<PosRegister>> listRegisters(int storeId) async {
    final data = await _client.get('/stores/$storeId/registers');
    return asList(data)
        .map(PosRegister.fromJson)
        .whereType<PosRegister>()
        .toList();
  }

  @override
  Future<PosRegister?> setRegisterStatus(int id, String status) async {
    final data = await _client.patch(
      '/registers/$id/status',
      body: {'status': status},
    );
    return PosRegister.fromJson(data);
  }

  @override
  Future<List<PosDevice>> listDevices(int storeId) async {
    final data = await _client.get('/stores/$storeId/devices');
    return asList(data).map(PosDevice.fromJson).whereType<PosDevice>().toList();
  }

  @override
  Future<PosDevice?> setDeviceStatus(int id, String status) async {
    final data = await _client.patch(
      '/devices/$id/status',
      body: {'status': status},
    );
    return PosDevice.fromJson(data);
  }
}
