import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/storage/token_store.dart';
import '../data/auth_service.dart';

/// Where the cashier is in the sign-in sequence.
enum SessionPhase { restoring, deviceLogin, staffLogin, shiftOpen, ready }

/// Device login -> staff PIN login -> open shift. Only the device token and
/// identifier are persisted (secure storage); the staff token lives in memory
/// and the PIN/secret are never stored.
class SessionController extends ChangeNotifier {
  SessionController(this._auth, this._store);

  final AuthService _auth;
  final TokenStore _store;

  SessionPhase _phase = SessionPhase.restoring;
  String? _deviceToken;
  String? _staffToken;
  String? _deviceIdentifier;
  String? _salesmanId;
  bool _busy = false;
  ApiException? _error;
  String? _notice;
  bool _disposed = false;

  SessionPhase get phase => _phase;
  bool get busy => _busy;
  ApiException? get error => _error;
  String? get notice => _notice;
  String? get deviceIdentifier => _deviceIdentifier;
  String? get salesmanId => _salesmanId;

  /// Token used for browsing and cart calls: the staff token once signed in.
  String? get activeToken => _staffToken ?? _deviceToken;

  Future<void> restore() async {
    _deviceToken = await _store.read(TokenKeys.deviceToken);
    _deviceIdentifier = await _store.read(TokenKeys.deviceIdentifier);
    _phase = (_deviceToken == null || _deviceToken!.isEmpty)
        ? SessionPhase.deviceLogin
        : SessionPhase.staffLogin;
    _notify();
  }

  Future<bool> loginDevice(String identifier, String secret) async {
    if (_busy) return false;
    return _run(() async {
      final token = await _auth.deviceLogin(
        deviceIdentifier: identifier.trim(),
        deviceSecret: secret,
      );
      _deviceToken = token;
      _deviceIdentifier = identifier.trim();
      await _store.write(TokenKeys.deviceToken, token);
      await _store.write(TokenKeys.deviceIdentifier, _deviceIdentifier!);
      _phase = SessionPhase.staffLogin;
    });
  }

  Future<bool> loginStaff(String salesmanId, String pin) async {
    final device = _deviceToken;
    if (_busy || device == null) return false;
    return _run(() async {
      final token = await _auth.staffLogin(
        deviceToken: device,
        salesmanId: salesmanId.trim(),
        pin: pin,
      );
      _staffToken = token;
      _salesmanId = salesmanId.trim();
      _phase = SessionPhase.shiftOpen;
    });
  }

  /// Opens a shift. The backend answers 409 when the register already has an
  /// open shift; that is not a failure — the cashier can simply continue.
  Future<bool> openShift(double openingAmount) async {
    final staff = _staffToken;
    if (_busy || staff == null) return false;
    return _run(() async {
      try {
        await _auth.openShift(staffToken: staff, openingAmount: openingAmount);
      } on ApiException catch (e) {
        if (e.kind != ApiErrorKind.conflict) rethrow;
        _notice =
            'This register already has an open shift — continuing with it.';
      }
      _phase = SessionPhase.ready;
    });
  }

  /// Called by the API client on a 401 from an authenticated request.
  ///
  /// [failedToken] is the token the server rejected. If it is no longer the
  /// active token (a parallel request already triggered the same sign-out), the
  /// call is ignored — otherwise one expiry would cascade into forgetting the
  /// device as well.
  void handleUnauthorized([String? failedToken]) {
    if (failedToken != null && failedToken != activeToken) return;
    if (_phase == SessionPhase.deviceLogin ||
        _phase == SessionPhase.restoring) {
      return;
    }
    if (_staffToken != null) {
      _staffToken = null;
      _phase = SessionPhase.staffLogin;
      _error = const ApiException(
        kind: ApiErrorKind.unauthorized,
        message: 'Your session has expired. Please sign in again.',
      );
    } else {
      _forgetDevice();
      _phase = SessionPhase.deviceLogin;
      _error = const ApiException(
        kind: ApiErrorKind.unauthorized,
        message: 'This device needs to be signed in again.',
      );
    }
    _notify();
  }

  /// Staff sign-out: back to the PIN screen, device stays registered.
  void logoutStaff() {
    _staffToken = null;
    _salesmanId = null;
    _error = null;
    _notice = null;
    _phase = SessionPhase.staffLogin;
    _notify();
  }

  /// Forget this device entirely (e.g. wrong device selected).
  Future<void> changeDevice() async {
    _staffToken = null;
    await _store.delete(TokenKeys.deviceToken);
    _deviceToken = null;
    _error = null;
    _notice = null;
    _phase = SessionPhase.deviceLogin;
    _notify();
  }

  void _forgetDevice() {
    _deviceToken = null;
    _store.delete(TokenKeys.deviceToken);
  }

  void clearError() {
    if (_error == null && _notice == null) return;
    _error = null;
    _notice = null;
    _notify();
  }

  Future<bool> _run(Future<void> Function() body) async {
    _busy = true;
    _error = null;
    _notice = null;
    _notify();
    try {
      await body();
      return true;
    } on ApiException catch (e) {
      _error = e;
      return false;
    } finally {
      _busy = false;
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
