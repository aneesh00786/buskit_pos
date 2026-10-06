import 'dart:convert';

import '../../../core/utils/json_read.dart';

/// The POS scope the server put in the staff token (buskit-web
/// posStaffAuthService.staffLogin: company_id, store_id, register_id,
/// device_id, salesman_id).
///
/// Read WITHOUT verifying the signature: the token came straight from this
/// app's own login call, and the scope is used only to stamp and check
/// sales recorded on this device while offline. It grants nothing — the
/// server re-validates every id when such a sale is eventually synced.
/// The token itself is never stored or logged here.
class PosTokenScope {
  const PosTokenScope({
    required this.companyId,
    required this.storeId,
    required this.registerId,
    required this.deviceId,
    required this.salesmanId,
  });

  final int companyId;
  final int storeId;
  final int registerId;
  final int deviceId;
  final String salesmanId;

  /// Null unless [token] is a JWT whose payload carries the full staff scope.
  static PosTokenScope? fromToken(String? token) {
    if (token == null) return null;
    final parts = token.split('.');
    if (parts.length != 3) return null;
    Map<String, dynamic>? claims;
    try {
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      claims = asMap(jsonDecode(decoded));
    } catch (_) {
      return null;
    }
    if (claims == null || asString(claims['authType']) != 'staff') {
      return null;
    }
    final company = asInt(claims['company_id']);
    final store = asInt(claims['store_id']);
    final register = asInt(claims['register_id']);
    final device = asInt(claims['device_id']);
    final staff = asString(claims['salesman_id']);
    if (company == null ||
        store == null ||
        register == null ||
        device == null ||
        staff == null) {
      return null;
    }
    return PosTokenScope(
      companyId: company,
      storeId: store,
      registerId: register,
      deviceId: device,
      salesmanId: staff,
    );
  }
}
