import 'package:buskit_pos/features/settings/data/settings_service.dart';
import 'package:buskit_pos/features/settings/models/pos_device.dart';
import 'package:buskit_pos/features/settings/models/pos_register.dart';
import 'package:buskit_pos/features/settings/models/pos_store.dart';

Map<String, dynamic> storeJson({
  int id = 1,
  String storeCode = 'STORE1',
  String storeName = 'Main Store',
  String? address = '1 Main St',
  String? town = 'Springfield',
  String? state = 'NSW',
  String? zip = '2000',
  String? country = 'AU',
  String timezone = 'Australia/Sydney',
  String currency = 'AUD',
  String status = 'active',
}) => {
  'id': id,
  'store_code': storeCode,
  'store_name': storeName,
  'address': address,
  'town': town,
  'state': state,
  'zip': zip,
  'country': country,
  'timezone': timezone,
  'currency': currency,
  'status': status,
};

Map<String, dynamic> registerJson({
  int id = 1,
  int storeId = 1,
  String registerCode = 'REG1',
  String registerName = 'Register 1',
  String status = 'active',
}) => {
  'id': id,
  'store_id': storeId,
  'register_code': registerCode,
  'register_name': registerName,
  'status': status,
};

Map<String, dynamic> deviceJson({
  int id = 1,
  int storeId = 1,
  int? registerId,
  String deviceIdentifier = 'TEST-TAB-1',
  String? deviceName = 'Front counter tablet',
  String? platform = 'android',
  String status = 'active',
  String? lastSeenAt,
}) => {
  'id': id,
  'store_id': storeId,
  'register_id': registerId,
  'device_identifier': deviceIdentifier,
  'device_name': deviceName,
  'platform': platform,
  'status': status,
  'last_seen_at': lastSeenAt,
};

class UpdateStoreCall {
  UpdateStoreCall(this.id, this.fields);
  final int id;
  final Map<String, dynamic> fields;
}

class StatusCall {
  StatusCall(this.id, this.status);
  final int id;
  final String status;
}

class FakeSettingsService implements SettingsService {
  final List<UpdateStoreCall> updateStoreCalls = [];
  final List<StatusCall> setRegisterStatusCalls = [];
  final List<StatusCall> setDeviceStatusCalls = [];

  Future<List<PosStore>> Function() onListStores = () async => [
    PosStore.fromJson(storeJson())!,
  ];
  Future<PosStore?> Function(UpdateStoreCall call) onUpdateStore = (
    call,
  ) async => PosStore.fromJson({...storeJson(id: call.id), ...call.fields});
  Future<List<PosRegister>> Function(int storeId) onListRegisters = (
    storeId,
  ) async => [PosRegister.fromJson(registerJson(storeId: storeId))!];
  Future<PosRegister?> Function(StatusCall call) onSetRegisterStatus =
      (call) async =>
          PosRegister.fromJson(registerJson(id: call.id, status: call.status));
  Future<List<PosDevice>> Function(int storeId) onListDevices = (
    storeId,
  ) async => [PosDevice.fromJson(deviceJson(storeId: storeId))!];
  Future<PosDevice?> Function(StatusCall call) onSetDeviceStatus = (
    call,
  ) async => PosDevice.fromJson(deviceJson(id: call.id, status: call.status));

  @override
  Future<List<PosStore>> listStores() => onListStores();

  @override
  Future<PosStore?> updateStore(int id, Map<String, dynamic> fields) {
    final call = UpdateStoreCall(id, fields);
    updateStoreCalls.add(call);
    return onUpdateStore(call);
  }

  @override
  Future<List<PosRegister>> listRegisters(int storeId) =>
      onListRegisters(storeId);

  @override
  Future<PosRegister?> setRegisterStatus(int id, String status) {
    final call = StatusCall(id, status);
    setRegisterStatusCalls.add(call);
    return onSetRegisterStatus(call);
  }

  @override
  Future<List<PosDevice>> listDevices(int storeId) => onListDevices(storeId);

  @override
  Future<PosDevice?> setDeviceStatus(int id, String status) {
    final call = StatusCall(id, status);
    setDeviceStatusCalls.add(call);
    return onSetDeviceStatus(call);
  }
}
