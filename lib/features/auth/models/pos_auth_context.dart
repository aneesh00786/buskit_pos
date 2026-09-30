import '../../../core/utils/json_read.dart';

/// `GET /auth/me`'s `staff.role` — a staff member has at most one role today
/// (the backend's `pos_staff_roles` is one row per (company, salesman_id));
/// `null` on [PosAuthContext.role] means no role is assigned at all
/// (deny-by-default — [PosAuthContext.permissions] is `[]` in that case).
class StaffRole {
  const StaffRole({required this.id, required this.name});
  final int id;
  final String name;

  static StaffRole? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['id']);
    final name = asString(m['name']);
    if (id == null || name == null) return null;
    return StaffRole(id: id, name: name);
  }
}

class StaffInfo {
  const StaffInfo({required this.salesmanId, this.name, this.role});
  final String salesmanId;
  final String? name;
  final StaffRole? role;

  static StaffInfo? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final salesmanId = asString(m['salesman_id']);
    if (salesmanId == null) return null;
    return StaffInfo(
      salesmanId: salesmanId,
      name: asString(m['name']),
      role: StaffRole.fromJson(m['role']),
    );
  }
}

/// `GET /auth/me`'s full response — the authenticated staff member's
/// identity, role, and permissions, resolved fresh from the database by the
/// backend on every call. This is a UI/UX convenience ONLY: the backend
/// independently enforces every permission server-side regardless of what
/// this context says, and nothing in this app treats it as an authorization
/// decision. See `PermissionService`.
class PosAuthContext {
  const PosAuthContext({required this.staff, required this.permissions});

  final StaffInfo staff;

  /// The exact permission keys the backend currently grants this staff
  /// member (e.g. `payments.refund`) — never derived from a role NAME.
  final List<String> permissions;

  static PosAuthContext? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final staff = StaffInfo.fromJson(m['staff']);
    if (staff == null) return null;
    return PosAuthContext(
      staff: staff,
      permissions: asList(
        m['permissions'],
      ).map(asString).whereType<String>().toList(),
    );
  }
}
