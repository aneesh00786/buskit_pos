import '../models/pos_auth_context.dart';

/// The single place permission checks happen in the UI — never scatter
/// `context.permissions.contains('x')` across widgets. Backed by whatever
/// [PosAuthContext] `SessionController` currently holds (`null` before the
/// first successful fetch, or after a failed one).
///
/// IMPORTANT: this is UI/UX convenience only. Every permission is
/// independently and authoritatively re-checked by the backend on every
/// request — hiding a button here never replaces a server-side check, and a
/// stale/missing context here must never be treated as "allowed".
class PermissionService {
  const PermissionService(this._context);

  final PosAuthContext? _context;

  bool hasPermission(String permission) =>
      _context?.permissions.contains(permission) ?? false;

  bool hasAnyPermission(List<String> permissions) =>
      permissions.any(hasPermission);

  bool hasAllPermissions(List<String> permissions) =>
      permissions.every(hasPermission);
}
