import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('StaffRole.fromJson', () {
    test('parses a valid role', () {
      final role = StaffRole.fromJson({'id': 5, 'name': 'Cashier'});
      expect(role!.id, 5);
      expect(role.name, 'Cashier');
    });

    test('null input yields null', () {
      expect(StaffRole.fromJson(null), isNull);
    });

    test('missing id or name yields null (no crash on a malformed row)', () {
      expect(StaffRole.fromJson({'name': 'Cashier'}), isNull);
      expect(StaffRole.fromJson({'id': 5}), isNull);
    });
  });

  group('StaffInfo.fromJson', () {
    test('parses staff with a role', () {
      final staff = StaffInfo.fromJson({
        'salesman_id': 'SALES1',
        'name': 'Raj P',
        'role': {'id': 5, 'name': 'Cashier'},
      });
      expect(staff!.salesmanId, 'SALES1');
      expect(staff.name, 'Raj P');
      expect(staff.role!.name, 'Cashier');
    });

    test('a staff member with no assigned role parses role as null', () {
      final staff = StaffInfo.fromJson({
        'salesman_id': 'SALES1',
        'name': 'Raj P',
        'role': null,
      });
      expect(staff!.role, isNull);
    });

    test('missing salesman_id yields null', () {
      expect(StaffInfo.fromJson({'name': 'Raj P'}), isNull);
    });
  });

  group('PosAuthContext.fromJson', () {
    test('parses the full GET /auth/me response shape', () {
      final ctx = PosAuthContext.fromJson({
        'staff': {
          'salesman_id': 'SALES1',
          'name': 'Raj P',
          'role': {'id': 5, 'name': 'Cashier'},
        },
        'permissions': ['sales.view', 'sales.create', 'sales.hold'],
      });
      expect(ctx!.staff.salesmanId, 'SALES1');
      expect(ctx.staff.role!.id, 5);
      expect(ctx.permissions, ['sales.view', 'sales.create', 'sales.hold']);
    });

    test('a staff member with no role gets an empty permission list', () {
      final ctx = PosAuthContext.fromJson({
        'staff': {'salesman_id': 'SALES1', 'name': 'Raj P', 'role': null},
        'permissions': <String>[],
      });
      expect(ctx!.staff.role, isNull);
      expect(ctx.permissions, isEmpty);
    });

    test('missing permissions field defaults to an empty list, not a crash', () {
      final ctx = PosAuthContext.fromJson({
        'staff': {'salesman_id': 'SALES1'},
      });
      expect(ctx!.permissions, isEmpty);
    });

    test('missing staff yields null (no crash on a malformed response)', () {
      expect(PosAuthContext.fromJson({'permissions': []}), isNull);
    });

    test('null/non-map input yields null', () {
      expect(PosAuthContext.fromJson(null), isNull);
      expect(PosAuthContext.fromJson('not a map'), isNull);
    });
  });
}
