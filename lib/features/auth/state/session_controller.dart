import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/storage/token_store.dart';
import '../data/auth_service.dart';
import '../models/pos_auth_context.dart';
import '../models/pos_token_scope.dart';
import 'permission_service.dart';

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

  // Phase 17.1 — POS auth context (role + permissions), fetched once right
  // after staff login and on an explicit refreshAuthContext() call only.
  // In-memory only: never persisted, never derived from the JWT. UI/UX
  // convenience only — see PermissionService's own header comment for why
  // this never substitutes for the backend's own enforcement.
  PosAuthContext? _authContext;
  ApiException? _authContextError;

  // The shift this session opened itself (null when it joined a shift that
  // was already open — the server answers that with a 409 and no shift).
  int? _openedShiftId;
  DateTime? _openedShiftAt;

  SessionPhase get phase => _phase;
  bool get busy => _busy;
  ApiException? get error => _error;
  String? get notice => _notice;
  String? get deviceIdentifier => _deviceIdentifier;
  String? get salesmanId => _salesmanId;

  PosAuthContext? get authContext => _authContext;
  ApiException? get authContextError => _authContextError;
  PermissionService get permissions => PermissionService(_authContext);

  /// The single, centralized "should a UI action be hidden?" rule (Phase
  /// 17.2) — true only when the context has POSITIVELY loaded and does NOT
  /// grant [permission]. Never true just because the context hasn't loaded
  /// yet or a fetch failed: [PermissionService.hasPermission] already
  /// denies in that case for any actual authorization decision, but a
  /// button should stay visible (letting the backend's own 403 decide)
  /// rather than disappearing on missing data. Every permission-gated
  /// widget in the app should call this instead of re-deriving the same
  /// `authContext != null && !hasPermission(...)` check inline.
  /// Phase 15D — the signed-in business's type, from `GET /auth/me` only
  /// (null until loaded, or when the server reports none).
  BusinessType? get businessType => _authContext?.businessType;

  /// Phase 15D — whether the signed-in staff member holds an active
  /// ThriveWoo POS licence. Display only: licensed features are still
  /// checked by the server on every request.
  bool get isLicensed => _authContext?.licensed ?? false;

  bool isDenied(String permission) =>
      _authContext != null && !permissions.hasPermission(permission);

  /// True only when the loaded context positively lacks EVERY one of
  /// [permissions] — for screens the backend opens with any one of several
  /// (e.g. analytics: any reports.* permission). Same "never hide on
  /// missing data" rule as [isDenied].
  bool isDeniedAll(List<String> permissions) =>
      _authContext != null && permissions.every(isDenied);

  /// Token used for browsing and cart calls: the staff token once signed in.
  String? get activeToken => _staffToken ?? _deviceToken;

  /// Company/store/register/device/staff of the signed-in staff session, as
  /// the server stated it in the staff token (null when not signed in). Only
  /// used to stamp/check sales recorded on this device while offline.
  PosTokenScope? get tokenScope => PosTokenScope.fromToken(_staffToken);

  /// The shift opened by THIS session (see [openShift]), if any.
  int? get openedShiftId => _openedShiftId;
  DateTime? get openedShiftAt => _openedShiftAt;

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
      try {
        final token = await _auth.staffLogin(
          deviceToken: device,
          salesmanId: salesmanId.trim(),
          pin: pin,
        );
        _staffToken = token;
        _salesmanId = salesmanId.trim();
        _phase = SessionPhase.shiftOpen;
        // Phase 15D: a new sign-in never inherits the previous staff
        // member's context (business type, licence, permissions), even when
        // the fetch below fails.
        _authContext = null;
        _authContextError = null;
        // Best-effort: this is a UI/UX convenience fetch, not part of the
        // authentication flow itself — a failure here must never block a
        // cashier who successfully entered a correct PIN from getting into
        // the POS. The error is kept (authContextError) only so the UI/tests
        // can see it happened; it is never rethrown.
        await _loadAuthContext(token);
      } on ApiException catch (e) {
        // Every wrong-PIN/unknown-staff/locked/inactive failure carries this
        // one stable code (never leaked by status/message alone — see the
        // backend's genericStaffLoginFailure). Any OTHER 401 here means the
        // DEVICE token itself was rejected (expired/revoked/invalid) before
        // the PIN was ever checked — recover the same way handleUnauthorized
        // already does for every other authenticated call, instead of
        // showing that raw backend message on the PIN screen as if the PIN
        // were wrong.
        if (e.kind != ApiErrorKind.unauthorized ||
            e.errorCode == PosErrorCodes.invalidStaffCredentials) {
          rethrow;
        }
        _forgetDevice();
        _phase = SessionPhase.deviceLogin;
        throw const ApiException(
          kind: ApiErrorKind.unauthorized,
          message: 'This device needs to be signed in again.',
        );
      }
    });
  }

  /// Opens a shift. The backend answers 409 when the register already has an
  /// open shift; that is not a failure — the cashier can simply continue.
  Future<bool> openShift(double openingAmount) async {
    final staff = _staffToken;
    if (_busy || staff == null) return false;
    return _run(() async {
      try {
        _openedShiftId = await _auth.openShift(
          staffToken: staff,
          openingAmount: openingAmount,
        );
        _openedShiftAt = DateTime.now().toUtc();
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
      _authContext = null;
      _authContextError = null;
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
  /// [notice] is shown on the sign-in screen (e.g. after closing the shift).
  void logoutStaff({String? notice}) {
    _staffToken = null;
    _openedShiftId = null;
    _openedShiftAt = null;
    _salesmanId = null;
    _error = null;
    _notice = notice;
    _authContext = null;
    _authContextError = null;
    _phase = SessionPhase.staffLogin;
    _notify();
  }

  Future<void> _loadAuthContext(String staffToken) async {
    try {
      _authContext = await _auth.getAuthContext(staffToken: staffToken);
      _authContextError = null;
    } on ApiException catch (e) {
      _authContextError = e;
      // Deliberately NOT cleared to null on failure: a transient error
      // fetching a REFRESH must not silently revoke a context the UI is
      // already correctly showing. A first-ever fetch failure (no prior
      // context) simply leaves it null, which PermissionService already
      // treats as "no permissions" — never as "allowed".
    }
    _notify();
  }

  /// Re-fetches `GET /auth/me` and replaces the in-memory context — e.g.
  /// after an admin changes this staff member's role/permissions and the
  /// cashier wants to try again without signing out. No polling, no
  /// automatic background refresh (Phase 17.1 scope).
  Future<void> refreshAuthContext() async {
    final staff = _staffToken;
    if (staff == null) return;
    await _loadAuthContext(staff);
  }

  /// Forget this device entirely (e.g. wrong device selected).
  Future<void> changeDevice() async {
    _staffToken = null;
    await _store.delete(TokenKeys.deviceToken);
    _deviceToken = null;
    _authContext = null;
    _authContextError = null;
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
