import 'package:buskit_pos/features/settings/models/pos_device.dart';
import 'package:buskit_pos/features/settings/models/pos_register.dart';
import 'package:buskit_pos/features/settings/models/pos_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_settings_service.dart';

void main() {
  group('PosStore.fromJson', () {
    test('parses a full row', () {
      final s = PosStore.fromJson(storeJson())!;
      expect(s.storeCode, 'STORE1');
      expect(s.storeName, 'Main Store');
      expect(s.isActive, isTrue);
    });

    test('missing id, store_code or store_name yields null', () {
      final row = storeJson();
      expect(PosStore.fromJson({...row, 'id': null}), isNull);
      expect(PosStore.fromJson({...row, 'store_code': null}), isNull);
      expect(PosStore.fromJson({...row, 'store_name': null}), isNull);
      expect(PosStore.fromJson(null), isNull);
    });

    test('timezone/currency/status default sensibly when missing', () {
      final s = PosStore.fromJson({
        'id': 1,
        'store_code': 'S1',
        'store_name': 'S',
      })!;
      expect(s.timezone, 'UTC');
      expect(s.currency, 'AUD');
      expect(s.status, 'active');
    });
  });

  group('PosRegister.fromJson', () {
    test('parses a full row', () {
      final r = PosRegister.fromJson(registerJson())!;
      expect((r.registerCode, r.registerName), ('REG1', 'Register 1'));
      expect(r.isActive, isTrue);
    });

    test(
      'missing id, store_id, register_code or register_name yields null',
      () {
        final row = registerJson();
        expect(PosRegister.fromJson({...row, 'id': null}), isNull);
        expect(PosRegister.fromJson({...row, 'store_id': null}), isNull);
        expect(PosRegister.fromJson({...row, 'register_code': null}), isNull);
        expect(PosRegister.fromJson({...row, 'register_name': null}), isNull);
      },
    );

    test('inactive status is reflected in isActive', () {
      final r = PosRegister.fromJson(registerJson(status: 'inactive'))!;
      expect(r.isActive, isFalse);
    });
  });

  group('PosDevice.fromJson', () {
    test('parses a full row', () {
      final d = PosDevice.fromJson(deviceJson())!;
      expect(d.deviceIdentifier, 'TEST-TAB-1');
      expect(d.isActive, isTrue);
      expect(d.isRevoked, isFalse);
    });

    test('missing id, store_id or device_identifier yields null', () {
      final row = deviceJson();
      expect(PosDevice.fromJson({...row, 'id': null}), isNull);
      expect(PosDevice.fromJson({...row, 'store_id': null}), isNull);
      expect(PosDevice.fromJson({...row, 'device_identifier': null}), isNull);
    });

    test('a revoked device reports isRevoked, not isActive', () {
      final d = PosDevice.fromJson(deviceJson(status: 'revoked'))!;
      expect(d.isRevoked, isTrue);
      expect(d.isActive, isFalse);
    });
  });
}
