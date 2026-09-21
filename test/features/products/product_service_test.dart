import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import '../../support/fakes.dart';

void main() {
  late List<http.Request> seen;
  late ApiProductService service;

  setUp(() {
    seen = [];
    service = ApiProductService(
      PosApiClient(
        baseUrl: 'http://h',
        tokenProvider: () => 'tok',
        httpClient: MockClient((r) async {
          seen.add(r);
          final body = r.url.path.endsWith('/categories')
              ? {
                  'status': true,
                  'data': [
                    {'cid': 1, 'category': 'Dairy'},
                    {'cid': 2, 'category': 'Bakery'},
                    {'bad': 1},
                  ],
                }
              : {
                  'status': true,
                  'data': pageJson([productJson(id: 1)]),
                };
          return http.Response(jsonEncode(body), 200);
        }),
      ),
    );
  });

  test(
    'search sends only the supported params, page and limit always',
    () async {
      await service.search(page: 3, limit: 50);
      expect(seen.single.url.path, '/api/v1/pos/products');
      expect(seen.single.url.queryParameters, {'page': '3', 'limit': '50'});
    },
  );

  test('search sends q (trimmed), category_id and brand when set', () async {
    await service.search(
      query: '  milk  ',
      categoryId: 4,
      brand: 'Acme',
      page: 1,
      limit: 20,
    );
    expect(seen.single.url.queryParameters, {
      'page': '1',
      'limit': '20',
      'q': 'milk',
      'category_id': '4',
      'brand': 'Acme',
    });
  });

  test('blank q and null category are omitted', () async {
    await service.search(query: '   ');
    expect(seen.single.url.queryParameters.containsKey('q'), isFalse);
    expect(seen.single.url.queryParameters.containsKey('category_id'), isFalse);
  });

  test(
    'q longer than the backend limit (100) is truncated rather than rejected',
    () async {
      await service.search(query: 'x' * 150);
      expect(seen.single.url.queryParameters['q'], hasLength(100));
    },
  );

  test('categories parses the list and skips malformed rows', () async {
    final cats = await service.categories();
    expect(seen.single.url.path, '/api/v1/pos/categories');
    expect(cats.map((c) => c.name), ['Dairy', 'Bakery']);
  });

  test('sends the bearer token', () async {
    await service.search();
    expect(seen.single.headers['Authorization'], 'Bearer tok');
  });
}
