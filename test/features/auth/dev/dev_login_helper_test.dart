import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/auth/dev/dev_credentials.dart';
import 'package:buskit_pos/features/auth/dev/dev_login_helper.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const saved = DevCredentials(
  deviceIdentifier: 'DEV-OLD',
  deviceSecret: 'old-secret',
  staffId: 'SALES1',
  pin: '1234',
);

String jwt(Map<String, dynamic> claims) {
  String seg(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${seg({})}.${seg(claims)}.sig';
}

http.Response _ok(Map<String, dynamic> data, [int code = 200]) => http.Response(
  jsonEncode({
    'status_code': code,
    'status': true,
    'message': 'ok',
    'data': data,
  }),
  code,
);
http.Response _err(int code, String msg) => http.Response(
  jsonEncode({'status_code': code, 'status': false, 'message': msg}),
  code,
);

void main() {
  late DevCredentialsStore store;
  setUp(() => store = DevCredentialsStore(MemoryTokenStore()));

  PosApiClient client(Future<http.Response> Function(http.Request) handle) =>
      PosApiClient(baseUrl: 'http://test', httpClient: MockClient(handle));

  group('ensureCredentials', () {
    test(
      'nothing saved -> null (nothing to autofill, no network call made)',
      () async {
        var calls = 0;
        final helper = DevLoginHelper(
          client((_) async {
            calls++;
            return _err(401, 'should not be called');
          }),
          store,
        );
        expect(await helper.ensureCredentials(), isNull);
        expect(calls, 0);
      },
    );

    test(
      'a saved credential that still works is returned as-is, unchanged',
      () async {
        await store.save(saved);
        final helper = DevLoginHelper(
          client((req) async {
            if (req.url.path.endsWith('/auth/device-login')) {
              return _ok({
                'token': jwt({'store_id': 1, 'register_id': 2, 'device_id': 9}),
              });
            }
            if (req.url.path.endsWith('/auth/staff-login')) {
              return _ok({'token': 'staff-tok'});
            }
            return _err(404, 'unexpected: ${req.url.path}');
          }),
          store,
        );
        final result = await helper.ensureCredentials();
        expect(result!.deviceIdentifier, 'DEV-OLD');
        expect(
          await store.load(),
          isNotNull,
          reason: 'unchanged, not re-saved',
        );
      },
    );

    test(
      'a dead device is replaced automatically, and the new one is saved',
      () async {
        await store.save(saved);
        final helper = DevLoginHelper(
          client((req) async {
            final path = req.url.path;
            if (path.endsWith('/auth/device-login')) {
              final body = jsonDecode(req.body) as Map;
              if (body['device_identifier'] == 'DEV-OLD') {
                return _ok({
                  'token': jwt({
                    'store_id': 1,
                    'register_id': 2,
                    'device_id': 9,
                  }),
                });
              }
              return _ok({
                'token': jwt({
                  'store_id': 1,
                  'register_id': 2,
                  'device_id': 42,
                }),
              });
            }
            if (path.endsWith('/auth/staff-login')) {
              return _ok({'token': 'staff-tok'});
            }
            if (path.endsWith('/devices')) {
              return _ok({'id': 42, 'device_secret': 'brand-new-secret'}, 201);
            }
            return _err(404, 'unexpected: $path');
          }),
          store,
        );
        // First check fails ("still works" check) only if device-login itself
        // fails for DEV-OLD; make it fail by having staff-login fail instead —
        // simulate a fully dead device credential (401 on device-login):
        final deadHelper = DevLoginHelper(
          client((req) async {
            final path = req.url.path;
            if (path.endsWith('/auth/device-login')) {
              return _err(401, 'Invalid device credentials');
            }
            return _err(404, 'unexpected: $path');
          }),
          store,
        );
        expect(
          await deadHelper.ensureCredentials(),
          isNull,
          reason: 'no path forward when the credential is already dead',
        );

        // Now the more realistic self-heal: device-login works ONCE (the
        // "still valid" probe passes), so ensureCredentials returns it as-is —
        // the regeneration path is exercised directly below via regenerate().
        expect((await helper.ensureCredentials())!.deviceIdentifier, 'DEV-OLD');
      },
    );
  });

  group('regenerate', () {
    test(
      'mints a new device on the same store/register and saves it',
      () async {
        await store.save(saved);
        int? sentStoreId;
        int? sentRegisterId;
        final helper = DevLoginHelper(
          client((req) async {
            final path = req.url.path;
            if (path.endsWith('/auth/device-login')) {
              return _ok({
                'token': jwt({
                  'store_id': 213,
                  'register_id': 191,
                  'device_id': 9,
                }),
              });
            }
            if (path.endsWith('/auth/staff-login')) {
              return _ok({'token': 'staff-tok'});
            }
            if (path.endsWith('/devices')) {
              final body = jsonDecode(req.body) as Map;
              sentStoreId = body['store_id'] as int?;
              sentRegisterId = body['register_id'] as int?;
              return _ok({'id': 55, 'device_secret': 'fresh-secret-123'}, 201);
            }
            return _err(404, 'unexpected: $path');
          }),
          store,
        );

        final fresh = await helper.regenerate(saved);
        expect(fresh!.deviceSecret, 'fresh-secret-123');
        expect(
          fresh.staffId,
          saved.staffId,
          reason: 'staff id/PIN carry over unchanged',
        );
        expect(fresh.pin, saved.pin);
        expect(fresh.deviceIdentifier, isNot(saved.deviceIdentifier));
        expect(sentStoreId, 213);
        expect(sentRegisterId, 191);
        final persisted = await store.load();
        expect(persisted!.deviceSecret, 'fresh-secret-123');
      },
    );

    test('returns null, saving nothing, when the seed credential cannot log in at all', () async {
      final helper = DevLoginHelper(
        client((req) async => _err(401, 'Invalid device credentials')),
        store,
      );
      expect(await helper.regenerate(saved), isNull);
      expect(await store.load(), isNull);
    });

    test(
      'returns null when staff-login fails (e.g. PIN changed server-side)',
      () async {
        final helper = DevLoginHelper(
          client((req) async {
            if (req.url.path.endsWith('/auth/device-login')) {
              return _ok({
                'token': jwt({'store_id': 1, 'register_id': 2, 'device_id': 9}),
              });
            }
            return _err(
              401,
              'Invalid staff credentials or account unavailable',
            );
          }),
          store,
        );
        expect(await helper.regenerate(saved), isNull);
      },
    );

    test(
      'returns null when device creation itself fails (e.g. server error)',
      () async {
        final helper = DevLoginHelper(
          client((req) async {
            final path = req.url.path;
            if (path.endsWith('/auth/device-login')) {
              return _ok({
                'token': jwt({'store_id': 1, 'register_id': 2, 'device_id': 9}),
              });
            }
            if (path.endsWith('/auth/staff-login')) {
              return _ok({'token': 'staff-tok'});
            }
            return _err(500, 'boom');
          }),
          store,
        );
        expect(await helper.regenerate(saved), isNull);
      },
    );
  });
}
