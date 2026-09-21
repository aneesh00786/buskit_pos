import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/held_sales/data/held_sales_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';

void main() {
  late List<http.Request> seen;
  late Object body;
  late int status;
  late ApiHeldSalesService service;

  setUp(() {
    seen = [];
    status = 200;
    body = {
      'status': true,
      'data': [
        heldRowJson(id: 12),
        heldRowJson(id: 9, saleNumber: 'POS-00000009'),
        {'garbage': true},
        'x',
      ],
    };
    service = ApiHeldSalesService(
      PosApiClient(
        baseUrl: 'http://h',
        tokenProvider: () => 'staff-tok',
        httpClient: MockClient((r) async {
          seen.add(r);
          return http.Response(jsonEncode(body), status);
        }),
      ),
    );
  });

  test('GET /sales?status=held — the store scope comes from the token, nothing else is sent', () async {
    await service.listHeld();
    final r = seen.single;
    expect(r.method, 'GET');
    expect(r.url.path, '/api/v1/pos/sales');
    expect(r.url.queryParameters, {'status': 'held'});
    expect(r.headers['Authorization'], 'Bearer staff-tok');
    expect(r.url.queryParameters.keys, isNot(contains('company_id')));
    expect(r.url.queryParameters.keys, isNot(contains('store_id')));
  });

  test('parses rows in server order and skips malformed ones', () async {
    final list = await service.listHeld();
    expect(list.map((s) => s.id), [12, 9]);
    expect(list.last.title, 'POS-00000009');
  });

  test('an empty list', () async {
    body = {'status': true, 'data': []};
    expect(await service.listHeld(), isEmpty);
  });

  test('a non-list payload yields an empty list, not a crash', () async {
    body = {
      'status': true,
      'data': {'oops': 1},
    };
    expect(await service.listHeld(), isEmpty);
  });

  test('errors keep their kind', () async {
    status = 500;
    body = {'status': false, 'message': 'boom'};
    await expectLater(service.listHeld(), throwsA(isA<Object>()));
  });
}
