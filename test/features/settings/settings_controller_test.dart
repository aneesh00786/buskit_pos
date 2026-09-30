import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/settings/models/pos_register.dart';
import 'package:buskit_pos/features/settings/models/pos_store.dart';
import 'package:buskit_pos/features/settings/state/settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_settings_service.dart';

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

void main() {
  group('load', () {
    test('idle -> loading -> loaded, auto-selecting the first store', () async {
      final svc = FakeSettingsService();
      final c = SettingsController(svc);
      expect(c.status, SettingsStatus.idle);
      final f = c.load();
      expect(c.status, SettingsStatus.loading);
      await f;
      expect(c.status, SettingsStatus.loaded);
      expect(c.selectedStore?.id, 1);
      expect(c.registers, isNotEmpty);
      expect(c.devices, isNotEmpty);
    });

    test(
      'no stores at all leaves registers/devices empty, without erroring',
      () async {
        final svc = FakeSettingsService();
        svc.onListStores = () async => [];
        final c = SettingsController(svc);
        await c.load();
        expect(c.status, SettingsStatus.loaded);
        expect(c.selectedStore, isNull);
        expect(c.registers, isEmpty);
        expect(c.devices, isEmpty);
      },
    );

    test(
      'a failure with nothing loaded shows the error state; retry can recover',
      () async {
        final svc = FakeSettingsService();
        svc.onListStores = () async => throw netDown;
        final c = SettingsController(svc);
        await c.load();
        expect(c.status, SettingsStatus.error);
        svc.onListStores = () async => [PosStore.fromJson(storeJson())!];
        await c.retry();
        expect(c.status, SettingsStatus.loaded);
      },
    );
  });

  group('selectStore', () {
    test(
      'switching stores reloads that store\'s registers and devices',
      () async {
        final svc = FakeSettingsService();
        svc.onListStores = () async => [
          PosStore.fromJson(storeJson(id: 1, storeName: 'Store 1'))!,
          PosStore.fromJson(storeJson(id: 2, storeName: 'Store 2'))!,
        ];
        final c = SettingsController(svc);
        await c.load();
        expect(c.selectedStore!.id, 1);
        await c.selectStore(c.stores.firstWhere((s) => s.id == 2));
        expect(c.selectedStore!.id, 2);
        expect(c.registers.single.storeId, 2);
        expect(c.devices.single.storeId, 2);
      },
    );

    test('selecting the already-selected store is a no-op', () async {
      final svc = FakeSettingsService();
      final c = SettingsController(svc);
      await c.load();
      final callsBefore = svc.updateStoreCalls.length;
      await c.selectStore(c.selectedStore!);
      expect(svc.updateStoreCalls.length, callsBefore);
    });
  });

  group('updateStore', () {
    test(
      'a successful update replaces the selected store and its list entry',
      () async {
        final svc = FakeSettingsService();
        final c = SettingsController(svc);
        await c.load();
        final ok = await c.updateStore({'store_name': 'Renamed'});
        expect(ok, isTrue);
        expect(c.selectedStore!.storeName, 'Renamed');
        expect(c.stores.single.storeName, 'Renamed');
      },
    );

    test(
      'a failure reports mutationError and leaves the store unchanged',
      () async {
        final svc = FakeSettingsService();
        svc.onUpdateStore = (_) async => throw netDown;
        final c = SettingsController(svc);
        await c.load();
        final before = c.selectedStore!.storeName;
        final ok = await c.updateStore({'store_name': 'Renamed'});
        expect(ok, isFalse);
        expect(c.mutationError, netDown);
        expect(c.selectedStore!.storeName, before);
      },
    );

    test('no double-submit while a mutation is already in flight', () async {
      final svc = FakeSettingsService();
      final gate = Completer<PosStore?>();
      svc.onUpdateStore = (_) => gate.future;
      final c = SettingsController(svc);
      await c.load();
      final first = c.updateStore({'store_name': 'A'});
      final second = await c.updateStore({'store_name': 'B'});
      expect(
        second,
        isFalse,
        reason: 'rejected while another mutation is in flight',
      );
      gate.complete(PosStore.fromJson(storeJson(storeName: 'A')));
      await first;
      expect(svc.updateStoreCalls.length, 1);
    });

    test('clearMutationError resets it', () async {
      final svc = FakeSettingsService();
      svc.onUpdateStore = (_) async => throw netDown;
      final c = SettingsController(svc);
      await c.load();
      await c.updateStore({'store_name': 'X'});
      expect(c.mutationError, isNotNull);
      c.clearMutationError();
      expect(c.mutationError, isNull);
    });
  });

  group('setRegisterStatus / setDeviceStatus', () {
    test(
      'toggling a register updates only that register in the list',
      () async {
        final svc = FakeSettingsService();
        svc.onListRegisters = (storeId) async => [
          PosRegister.fromJson(registerJson(id: 1, storeId: storeId))!,
          PosRegister.fromJson(registerJson(id: 2, storeId: storeId))!,
        ];
        final c = SettingsController(svc);
        await c.load();
        final ok = await c.setRegisterStatus(1, 'inactive');
        expect(ok, isTrue);
        expect(c.registers.firstWhere((r) => r.id == 1).isActive, isFalse);
      },
    );

    test('revoking a device marks it revoked in the list', () async {
      final svc = FakeSettingsService();
      final c = SettingsController(svc);
      await c.load();
      final deviceId = c.devices.single.id;
      final ok = await c.setDeviceStatus(deviceId, 'revoked');
      expect(ok, isTrue);
      expect(c.devices.single.isRevoked, isTrue);
    });

    test('a failed status change is reported via mutationError', () async {
      final svc = FakeSettingsService();
      svc.onSetDeviceStatus = (_) async => throw netDown;
      final c = SettingsController(svc);
      await c.load();
      final ok = await c.setDeviceStatus(c.devices.single.id, 'revoked');
      expect(ok, isFalse);
      expect(c.mutationError, netDown);
    });
  });
}
