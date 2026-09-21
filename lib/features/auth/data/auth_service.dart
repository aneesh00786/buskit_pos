import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';

abstract class AuthService {
  Future<String> deviceLogin({
    required String deviceIdentifier,
    required String deviceSecret,
  });
  Future<String> staffLogin({
    required String deviceToken,
    required String salesmanId,
    required String pin,
  });
  Future<int?> openShift({
    required String staffToken,
    required double openingAmount,
  });
}

/// Verified against the backend:
///  * `POST /auth/device-login {device_identifier, device_secret}` -> `{token}`
///  * `POST /auth/staff-login {salesman_id, pin}` with the DEVICE token -> `{token}`
///  * `POST /shifts/open {opening_amount}` with the STAFF token -> shift row
class ApiAuthService implements AuthService {
  ApiAuthService(this._client);
  final PosApiClient _client;

  @override
  Future<String> deviceLogin({
    required String deviceIdentifier,
    required String deviceSecret,
  }) async {
    final data = await _client.post(
      '/auth/device-login',
      body: {
        'device_identifier': deviceIdentifier,
        'device_secret': deviceSecret,
      },
      authenticated: false,
    );
    return _token(data);
  }

  @override
  Future<String> staffLogin({
    required String deviceToken,
    required String salesmanId,
    required String pin,
  }) async {
    // A 401 here means wrong staff credentials, not an expired session.
    final data = await _client.post(
      '/auth/staff-login',
      body: {'salesman_id': salesmanId, 'pin': pin},
      token: deviceToken,
      notifyUnauthorized: false,
    );
    return _token(data);
  }

  @override
  Future<int?> openShift({
    required String staffToken,
    required double openingAmount,
  }) async {
    final data = await _client.post(
      '/shifts/open',
      body: {'opening_amount': openingAmount},
      token: staffToken,
    );
    return asInt(asMap(data)?['id']);
  }

  String _token(Object? data) {
    final t = asString(asMap(data)?['token']);
    if (t == null || t.isEmpty) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return t;
  }
}
