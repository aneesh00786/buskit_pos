import '../../../core/utils/json_read.dart';

class PosStore {
  const PosStore({
    required this.id,
    required this.storeCode,
    required this.storeName,
    this.address,
    this.town,
    this.state,
    this.zip,
    this.country,
    required this.timezone,
    required this.currency,
    required this.status,
  });

  final int id;
  final String storeCode;
  final String storeName;
  final String? address;
  final String? town;
  final String? state;
  final String? zip;
  final String? country;
  final String timezone;
  final String currency;
  final String status;

  bool get isActive => status == 'active';

  static PosStore? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final storeCode = asString(m['store_code']);
    final storeName = asString(m['store_name']);
    if (id == null || storeCode == null || storeName == null) return null;
    return PosStore(
      id: id,
      storeCode: storeCode,
      storeName: storeName,
      address: asString(m['address']),
      town: asString(m['town']),
      state: asString(m['state']),
      zip: asString(m['zip']),
      country: asString(m['country']),
      timezone: asString(m['timezone']) ?? 'UTC',
      currency: asString(m['currency']) ?? 'AUD',
      status: asString(m['status']) ?? 'active',
    );
  }
}
