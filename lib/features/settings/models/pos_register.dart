import '../../../core/utils/json_read.dart';

class PosRegister {
  const PosRegister({
    required this.id,
    required this.storeId,
    required this.registerCode,
    required this.registerName,
    required this.status,
  });

  final int id;
  final int storeId;
  final String registerCode;
  final String registerName;
  final String status;

  bool get isActive => status == 'active';

  static PosRegister? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final storeId = asInt(m['store_id']);
    final registerCode = asString(m['register_code']);
    final registerName = asString(m['register_name']);
    if (id == null ||
        storeId == null ||
        registerCode == null ||
        registerName == null) {
      return null;
    }
    return PosRegister(
      id: id,
      storeId: storeId,
      registerCode: registerCode,
      registerName: registerName,
      status: asString(m['status']) ?? 'active',
    );
  }
}
