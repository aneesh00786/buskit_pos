import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/auth/state/permission_service.dart';
import 'package:flutter_test/flutter_test.dart';

PosAuthContext ctxWith(List<String> permissions) => PosAuthContext(
  staff: const StaffInfo(salesmanId: 'SALES1'),
  permissions: permissions,
);

void main() {
  group('hasPermission', () {
    test('true when the key is granted', () {
      final svc = PermissionService(ctxWith(['payments.refund']));
      expect(svc.hasPermission('payments.refund'), isTrue);
    });

    test('false when the key is not granted', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(svc.hasPermission('payments.refund'), isFalse);
    });

    test('false when there is no context at all (deny-by-default, never allow-by-default)', () {
      const svc = PermissionService(null);
      expect(svc.hasPermission('payments.refund'), isFalse);
    });

    test('false for an empty permission list', () {
      final svc = PermissionService(ctxWith(const []));
      expect(svc.hasPermission('sales.view'), isFalse);
    });
  });

  group('hasAnyPermission', () {
    test('true if at least one key is granted', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(
        svc.hasAnyPermission(['payments.refund', 'sales.view']),
        isTrue,
      );
    });

    test('false if none are granted', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(
        svc.hasAnyPermission(['payments.refund', 'sales.void']),
        isFalse,
      );
    });

    test('false for an empty permission-keys list to check', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(svc.hasAnyPermission(const []), isFalse);
    });

    test('false with no context', () {
      const svc = PermissionService(null);
      expect(svc.hasAnyPermission(['sales.view']), isFalse);
    });
  });

  group('hasAllPermissions', () {
    test('true only when every key is granted', () {
      final svc = PermissionService(ctxWith(['sales.view', 'sales.create']));
      expect(svc.hasAllPermissions(['sales.view', 'sales.create']), isTrue);
    });

    test('false if even one key is missing', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(svc.hasAllPermissions(['sales.view', 'sales.create']), isFalse);
    });

    test('true (vacuously) for an empty list to check', () {
      final svc = PermissionService(ctxWith(['sales.view']));
      expect(svc.hasAllPermissions(const []), isTrue);
    });

    test('false with no context', () {
      const svc = PermissionService(null);
      expect(svc.hasAllPermissions(['sales.view']), isFalse);
    });
  });
}
