import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/dev/dev_credentials.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DevCredentialsStore store;
  setUp(() => store = DevCredentialsStore(MemoryTokenStore()));

  test('loads null when nothing has ever been saved', () async {
    expect(await store.load(), isNull);
  });

  test('save/load round-trips all four fields', () async {
    const c = DevCredentials(
      deviceIdentifier: 'DEV-1',
      deviceSecret: 'abcd1234',
      staffId: 'SALES1',
      pin: '4321',
    );
    await store.save(c);
    final loaded = await store.load();
    expect(loaded!.deviceIdentifier, 'DEV-1');
    expect(loaded.deviceSecret, 'abcd1234');
    expect(loaded.staffId, 'SALES1');
    expect(loaded.pin, '4321');
  });

  test(
    'loads null until BOTH the device half and the staff half are present',
    () async {
      await store.rememberDevice('DEV-1', 'secret1');
      expect(await store.load(), isNull, reason: 'staff half missing');
      await store.rememberStaff('SALES1', '1234');
      expect(await store.load(), isNotNull);
    },
  );

  test(
    'rememberDevice/rememberStaff each overwrite only their own half',
    () async {
      await store.save(
        const DevCredentials(
          deviceIdentifier: 'OLD',
          deviceSecret: 'old-secret',
          staffId: 'S1',
          pin: '1',
        ),
      );
      await store.rememberDevice('NEW', 'new-secret');
      final loaded = await store.load();
      expect(
        (loaded!.deviceIdentifier, loaded.deviceSecret),
        ('NEW', 'new-secret'),
      );
      expect(
        (loaded.staffId, loaded.pin),
        ('S1', '1'),
        reason: 'staff half untouched',
      );
    },
  );

  test('copyWith replaces only the device fields', () {
    const c = DevCredentials(
      deviceIdentifier: 'A',
      deviceSecret: 'a',
      staffId: 'S',
      pin: 'P',
    );
    final updated = c.copyWith(deviceIdentifier: 'B', deviceSecret: 'b');
    expect(
      (
        updated.deviceIdentifier,
        updated.deviceSecret,
        updated.staffId,
        updated.pin,
      ),
      ('B', 'b', 'S', 'P'),
    );
  });
}
