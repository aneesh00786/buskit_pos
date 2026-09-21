import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/error_messages.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

PosApiClient clientFor(
  Future<http.Response> Function(http.Request) handler, {
  String? token = 'tok',
  void Function(String?)? onUnauthorized,
  Duration timeout = const Duration(seconds: 2),
}) => PosApiClient(
  baseUrl: 'http://host:3000',
  httpClient: MockClient(handler),
  tokenProvider: () => token,
  onUnauthorized: onUnauthorized,
  timeout: timeout,
);

void main() {
  group('request construction', () {
    test(
      'builds /api/v1/pos URLs, query params and the Bearer header',
      () async {
        late http.Request seen;
        final c = clientFor((r) async {
          seen = r;
          return json(200, {
            'status_code': 200,
            'status': true,
            'data': {'ok': 1},
          });
        });
        final data = await c.get('/products', query: {'q': 'a b', 'page': '2'});
        expect(data, {'ok': 1});
        expect(seen.method, 'GET');
        expect(seen.url.path, '/api/v1/pos/products');
        expect(seen.url.queryParameters, {'q': 'a b', 'page': '2'});
        expect(seen.headers['Authorization'], 'Bearer tok');
      },
    );

    test('honours a base URL that already has a path prefix', () {
      final c = PosApiClient(baseUrl: 'https://h.example/app/');
      expect(
        c.buildUri('/categories').toString(),
        'https://h.example/app/api/v1/pos/categories',
      );
    });

    test(
      'POST sends a JSON body; explicit token overrides the provider',
      () async {
        late http.Request seen;
        final c = clientFor((r) async {
          seen = r;
          return json(200, {'status': true, 'data': {}});
        });
        await c.post(
          '/auth/staff-login',
          body: {'salesman_id': 'S1', 'pin': '1234'},
          token: 'device-tok',
        );
        expect(seen.headers['Content-Type'], contains('application/json'));
        expect(jsonDecode(seen.body), {'salesman_id': 'S1', 'pin': '1234'});
        expect(seen.headers['Authorization'], 'Bearer device-tok');
      },
    );

    test('unauthenticated requests carry no Authorization header', () async {
      late http.Request seen;
      final c = clientFor((r) async {
        seen = r;
        return json(200, {'status': true, 'data': {}});
      });
      await c.post(
        '/auth/device-login',
        body: {'device_identifier': 'D'},
        authenticated: false,
      );
      expect(seen.headers.containsKey('Authorization'), isFalse);
    });
  });

  group('error handling', () {
    test(
      'keeps error_code, data and message from the backend envelope',
      () async {
        final c = clientFor(
          (r) async => json(422, {
            'status_code': 422,
            'status': false,
            'message': 'Weight-based products cannot be sold',
            'error_code': 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
            'data': {
              'weight_unit_item_ids': [3],
            },
          }),
        );
        final e = await c
            .post('/sales/1/items', body: {})
            .then<ApiException?>(
              (_) => null,
              onError: (Object e) => e as ApiException,
            );
        expect(e, isNotNull);
        expect(e!.kind, ApiErrorKind.validation);
        expect(e.statusCode, 422);
        expect(e.errorCode, PosErrorCodes.weightUnitNotSupported);
        expect(e.dataMap!['weight_unit_item_ids'], [3]);
        expect(
          e.isRetryable,
          isFalse,
          reason: 'validation errors must not be retried',
        );
      },
    );

    test('401 reports WHICH token was rejected', () async {
      final seen = <String?>[];
      final c = clientFor(
        (r) async => json(401, {'status': false, 'message': 'expired'}),
        token: 'old-tok',
        onUnauthorized: seen.add,
      );
      await expectLater(c.get('/products'), throwsA(isA<ApiException>()));
      expect(seen, ['old-tok']);
    });

    test('401 notifies the session once for authenticated calls', () async {
      var notified = 0;
      final c = clientFor(
        (r) async => json(401, {'status': false, 'message': 'Token expired'}),
        onUnauthorized: (_) => notified++,
      );
      await expectLater(
        c.get('/products'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.unauthorized,
          ),
        ),
      );
      expect(notified, 1);
    });

    test('401 from a credential check (notifyUnauthorized:false) does not sign the user out', () async {
      var notified = 0;
      final c = clientFor(
        (r) async => json(401, {
          'status': false,
          'message': 'Invalid staff credentials or account unavailable',
        }),
        onUnauthorized: (_) => notified++,
      );
      await expectLater(
        c.post('/auth/staff-login', body: {}, notifyUnauthorized: false),
        throwsA(isA<ApiException>()),
      );
      expect(notified, 0);
    });

    test('5xx never shows the server message and is retryable', () async {
      final c = clientFor(
        (r) async => json(500, {
          'status': false,
          'message': 'SELECT * FROM secrets failed at /srv/app.js:12',
        }),
      );
      try {
        await c.get('/products');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.server);
        expect(e.isRetryable, isTrue);
        expect(e.message, isNot(contains('SELECT')));
        expect(describeApiError(e), isNot(contains('/srv/')));
      }
    });

    test('409 conflict and 404 are not retryable', () async {
      for (final s in [404, 409, 403]) {
        final c = clientFor(
          (r) async => json(s, {'status': false, 'message': 'nope'}),
        );
        try {
          await c.get('/x');
          fail('should throw');
        } on ApiException catch (e) {
          expect(e.isRetryable, isFalse, reason: '$s');
          expect(e.message, 'nope');
        }
      }
    });

    test('socket errors map to a retryable network error', () async {
      final c = clientFor(
        (r) async => throw const SocketException('boom 10.0.0.5'),
      );
      try {
        await c.get('/products');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.network);
        expect(e.isRetryable, isTrue);
        expect(e.message, isNot(contains('10.0.0.5')));
      }
    });

    test('http ClientException also maps to network', () async {
      final c = clientFor(
        (r) async => throw http.ClientException('conn reset'),
      );
      await expectLater(
        c.get('/products'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.network,
          ),
        ),
      );
    });

    test('timeouts map to a retryable timeout error', () async {
      final c = clientFor(
        (r) => Completer<http.Response>().future,
        timeout: const Duration(milliseconds: 30),
      );
      try {
        await c.get('/products');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.timeout);
        expect(e.isRetryable, isTrue);
      }
    });

    test('a non-JSON success or error body does not crash parsing', () async {
      final ok = clientFor(
        (r) async => http.Response('<html>proxy</html>', 200),
      );
      expect(await ok.get('/products'), isNull);
      final bad = clientFor(
        (r) async => http.Response('<html>bad gateway</html>', 502),
      );
      await expectLater(
        bad.get('/products'),
        throwsA(
          isA<ApiException>().having(
            (e) => e.kind,
            'kind',
            ApiErrorKind.server,
          ),
        ),
      );
    });

    test('status:false inside a 200 is treated as a failure', () async {
      final c = clientFor(
        (r) async => json(200, {'status': false, 'message': 'nope'}),
      );
      await expectLater(c.get('/x'), throwsA(isA<ApiException>()));
    });

    test('very long backend messages are clipped', () async {
      final c = clientFor(
        (r) async => json(422, {'status': false, 'message': 'x' * 2000}),
      );
      try {
        await c.get('/x');
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.message.length, lessThan(400));
      }
    });
  });

  group('describeApiError', () {
    test('weight-unit code gives a friendly, actionable message', () {
      final m = describeApiError(apiErr(PosErrorCodes.weightUnitNotSupported));
      expect(m, contains('sold by weight'));
      expect(m, contains('not been added'));
    });

    test('insufficient stock reads the shortages list', () {
      final m = describeApiError(
        apiErr(
          PosErrorCodes.insufficientStock,
          data: {
            'shortages': [
              {'item_id': 1, 'requested': 5, 'available': 2},
            ],
          },
        ),
      );
      expect(m, 'Not enough stock: 5 requested, 2 available.');
    });

    test('unknown data shapes fall back safely', () {
      expect(
        describeApiError(
          apiErr(PosErrorCodes.insufficientStock, data: 'garbage'),
        ),
        contains('Not enough stock'),
      );
    });
  });
}

ApiException apiErr(String code, {Object? data}) =>
    ApiException.fromStatus(409, message: 'raw', errorCode: code, data: data);
