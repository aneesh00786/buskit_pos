import 'dart:convert';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';

void main() {
  late List<http.Request> seen;
  late ApiCartService service;
  late http.Response Function(http.Request) respond;

  setUp(() {
    seen = [];
    respond = (r) => http.Response(
      jsonEncode({'status': true, 'data': saleJson(id: 7, version: 2)}),
      200,
    );
    service = ApiCartService(
      PosApiClient(
        baseUrl: 'http://h',
        tokenProvider: () => 'staff-tok',
        httpClient: MockClient((r) async {
          seen.add(r);
          return respond(r);
        }),
      ),
    );
  });

  test('createSale: POST /sales with an empty body — no company/store/shift from the client', () async {
    final s = await service.createSale();
    expect(seen.single.method, 'POST');
    expect(seen.single.url.path, '/api/v1/pos/sales');
    expect(jsonDecode(seen.single.body), <String, dynamic>{});
    expect(seen.single.headers['Authorization'], 'Bearer staff-tok');
    expect(s.id, 7);
  });

  test('addItem: POST /sales/:id/items with the verified contract', () async {
    await service.addItem(
      saleId: 7,
      productVariationId: 42,
      quantity: 3,
      expectedVersion: 1,
    );
    final r = seen.single;
    expect(r.method, 'POST');
    expect(r.url.path, '/api/v1/pos/sales/7/items');
    expect(jsonDecode(r.body), {
      'product_variation_id': 42,
      'quantity': 3,
      'expected_version': 1,
    });
    expect(r.headers['Authorization'], 'Bearer staff-tok');
    expect(r.headers['Content-Type'], contains('application/json'));
  });

  test(
    'addItem body has exactly the three verified keys, with integer types',
    () async {
      await service.addItem(
        saleId: 7,
        productVariationId: 42,
        quantity: 3,
        expectedVersion: 1,
      );
      final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {
        'product_variation_id',
        'quantity',
        'expected_version',
      });
      expect(body.values.every((v) => v is int), isTrue);
    },
  );

  test('getSale: GET /sales/:id', () async {
    await service.getSale(7);
    expect(seen.single.method, 'GET');
    expect(seen.single.url.path, '/api/v1/pos/sales/7');
  });

  test(
    'the server response is what is returned: totals are not recomputed',
    () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': saleJson(
            id: 7,
            version: 3,
            items: [
              {
                'id': 1,
                'product_variation_id': 42,
                'quantity': 3,
                'product_name': 'Tea',
                'availability_status': 'available',
                'unit_price': 10,
                'tax_amount': 3.6,
                'tax_included': false,
                'line_total': 33.6,
              },
            ],
            subtotal: 30,
            tax: 3.6,
            total: 33.6,
          ),
        }),
        200,
      );
      final s = await service.addItem(
        saleId: 7,
        productVariationId: 42,
        quantity: 3,
        expectedVersion: 2,
      );
      expect(s.version, 3);
      expect(s.totals.grandTotal, 33.6);
      expect(s.items.single.lineTotal, 33.6);
      expect(s.itemCount, 3);
    },
  );

  test(
    'POS_WEIGHT_UNIT_NOT_SUPPORTED (422) is preserved with its code and data',
    () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status_code': 422,
          'status': false,
          'message': 'Weight-based products (KG/GR) cannot be sold',
          'error_code': 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        }),
        422,
      );
      try {
        await service.addItem(
          saleId: 7,
          productVariationId: 6,
          quantity: 1,
          expectedVersion: 1,
        );
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.errorCode, 'POS_WEIGHT_UNIT_NOT_SUPPORTED');
        expect(e.kind, ApiErrorKind.validation);
        expect(e.isRetryable, isFalse);
      }
    },
  );

  test('a malformed sale payload becomes a clean error, not a crash', () async {
    respond = (r) => http.Response(
      jsonEncode({
        'status': true,
        'data': {'nope': 1},
      }),
      200,
    );
    await expectLater(service.createSale(), throwsA(isA<ApiException>()));
  });

  group('update and remove', () {
    test('updateItem: PATCH /sales/:id/items/:itemId with {quantity, expected_version} and the staff token', () async {
      await service.updateItem(
        saleId: 7,
        itemId: 3,
        quantity: 5,
        expectedVersion: 2,
      );
      final r = seen.single;
      expect(r.method, 'PATCH');
      expect(r.url.path, '/api/v1/pos/sales/7/items/3');
      expect(jsonDecode(r.body), {'quantity': 5, 'expected_version': 2});
      expect(r.headers['Authorization'], 'Bearer staff-tok');
      expect(r.headers['Content-Type'], contains('application/json'));
    });

    test('updateItem sends only integer quantity and expected_version — no price, tax or total', () async {
      await service.updateItem(
        saleId: 7,
        itemId: 3,
        quantity: 5,
        expectedVersion: 2,
      );
      final body = jsonDecode(seen.single.body) as Map<String, dynamic>;
      expect(body.keys.toSet(), {'quantity', 'expected_version'});
      expect(body.values.every((v) => v is int), isTrue);
    });

    test(
      'removeItem: DELETE /sales/:id/items/:itemId?expected_version=N, no body',
      () async {
        await service.removeItem(saleId: 7, itemId: 3, expectedVersion: 4);
        final r = seen.single;
        expect(r.method, 'DELETE');
        expect(r.url.path, '/api/v1/pos/sales/7/items/3');
        expect(r.url.queryParameters, {'expected_version': '4'});
        expect(r.body, isEmpty);
        expect(r.headers['Authorization'], 'Bearer staff-tok');
      },
    );

    test('the refreshed sale in the response is returned as-is', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': saleJson(
            id: 7,
            version: 5,
            items: [lineJson(id: 3, quantity: 5)],
            subtotal: 50,
            tax: 6,
            total: 56,
          ),
        }),
        200,
      );
      final s = await service.updateItem(
        saleId: 7,
        itemId: 3,
        quantity: 5,
        expectedVersion: 4,
      );
      expect(s.version, 5);
      expect(s.items.single.quantity, 5);
      expect(s.totals.grandTotal, 56);
    });

    test('a 409 version conflict keeps error_code-less data: current_version and current_status', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status_code': 409,
          'status': false,
          'message': 'Sale has been modified since you last read it',
          'data': {'current_version': 9, 'current_status': 'draft'},
        }),
        409,
      );
      try {
        await service.updateItem(
          saleId: 7,
          itemId: 3,
          quantity: 5,
          expectedVersion: 2,
        );
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.conflict);
        expect(e.currentVersion, 9);
        expect(e.isVersionConflict, isTrue);
        expect(e.dataMap!['current_status'], 'draft');
        expect(e.isRetryable, isFalse);
      }
    });

    test('404 Line item not found is a non-retryable notFound', () async {
      respond = (r) => http.Response(
        jsonEncode({'status': false, 'message': 'Line item not found'}),
        404,
      );
      try {
        await service.removeItem(saleId: 7, itemId: 3, expectedVersion: 2);
        fail('should throw');
      } on ApiException catch (e) {
        expect(e.kind, ApiErrorKind.notFound);
        expect(e.isRetryable, isFalse);
      }
    });

    test('POS_WEIGHT_UNIT_NOT_SUPPORTED on an update keeps its code', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': false,
          'message': 'x',
          'error_code': 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        }),
        422,
      );
      await expectLater(
        service.updateItem(
          saleId: 7,
          itemId: 3,
          quantity: 2,
          expectedVersion: 1,
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.errorCode,
            'errorCode',
            'POS_WEIGHT_UNIT_NOT_SUPPORTED',
          ),
        ),
      );
    });
  });

  group('hold and resume', () {
    test('holdSale: POST /sales/:id/hold with only expected_version and the staff token', () async {
      await service.holdSale(saleId: 7, expectedVersion: 3);
      final r = seen.single;
      expect(r.method, 'POST');
      expect(r.url.path, '/api/v1/pos/sales/7/hold');
      expect(jsonDecode(r.body), {'expected_version': 3});
      expect(r.headers['Authorization'], 'Bearer staff-tok');
      expect(r.headers['Content-Type'], contains('application/json'));
      expect(
        r.url.queryParameters,
        isEmpty,
        reason: 'no company/store/shift scope is ever sent',
      );
    });

    test(
      'resumeSale: POST /sales/:id/resume with only expected_version',
      () async {
        await service.resumeSale(saleId: 9, expectedVersion: 4);
        final r = seen.single;
        expect(r.method, 'POST');
        expect(r.url.path, '/api/v1/pos/sales/9/resume');
        expect(jsonDecode(r.body), {'expected_version': 4});
        expect(r.headers['Authorization'], 'Bearer staff-tok');
      },
    );

    test('the returned held sale view is parsed with its status', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': true,
          'data': saleJson(
            id: 7,
            version: 4,
            status: 'held',
            items: [lineJson(id: 1)],
          ),
        }),
        200,
      );
      final s = await service.holdSale(saleId: 7, expectedVersion: 3);
      expect((s.id, s.version, s.status, s.isDraft), (7, 4, 'held', false));
    });

    test('409 version conflict on hold/resume keeps current_version and current_status', () async {
      respond = (r) => http.Response(
        jsonEncode({
          'status': false,
          'message': 'Sale has been modified since you last read it',
          'data': {'current_version': 8, 'current_status': 'held'},
        }),
        409,
      );
      for (final call in [
        () => service.holdSale(saleId: 7, expectedVersion: 3),
        () => service.resumeSale(saleId: 7, expectedVersion: 3),
      ]) {
        try {
          await call();
          fail('should throw');
        } on ApiException catch (e) {
          expect(e.isVersionConflict, isTrue);
          expect(e.currentVersion, 8);
          expect(e.dataMap!['current_status'], 'held');
          expect(e.isRetryable, isFalse);
        }
      }
    });

    test('403 different store/shift and 404 are non-retryable', () async {
      for (final status in [403, 404]) {
        respond = (r) => http.Response(
          jsonEncode({'status': false, 'message': 'nope'}),
          status,
        );
        await expectLater(
          service.resumeSale(saleId: 7, expectedVersion: 1),
          throwsA(
            isA<ApiException>().having(
              (e) => e.isRetryable,
              'retryable',
              false,
            ),
          ),
        );
      }
    });
  });
}
