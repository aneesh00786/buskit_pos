import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

Future<void> settle([int ms = 40]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeProductService service;
  late ProductListController c;
  var unauthorized = 0;

  ProductListController make({int pageSize = 2}) => ProductListController(
    service,
    debounce: const Duration(milliseconds: 15),
    pageSize: pageSize,
    onUnauthorized: () => unauthorized++,
  );

  setUp(() {
    service = FakeProductService();
    unauthorized = 0;
    c = make();
  });
  tearDown(() => c.dispose());

  group('loading states', () {
    test('idle -> loading -> loaded', () async {
      final gate = Completer<ProductPage>();
      service.onSearch = (_) => gate.future;
      final states = <ListStatus>[];
      c.addListener(() => states.add(c.status));
      final f = c.loadInitial();
      expect(c.status, ListStatus.loading);
      gate.complete(page([productJson(id: 1), productJson(id: 2)], total: 2));
      await f;
      expect(c.status, ListStatus.loaded);
      expect(c.items, hasLength(2));
      expect(c.groups, hasLength(2));
      expect(states.first, ListStatus.loading);
    });

    test('empty result -> empty state', () async {
      service.onSearch = (_) async => page([]);
      await c.loadInitial();
      expect(c.status, ListStatus.empty);
    });

    test(
      'error -> error state keeping the backend code; retry recovers',
      () async {
        service.onSearch = (_) async => throw apiError(500);
        await c.loadInitial();
        expect(c.status, ListStatus.error);
        expect(c.error!.isRetryable, isTrue);

        service.onSearch = (_) async => page([productJson(id: 1)]);
        await c.retry();
        expect(c.status, ListStatus.loaded);
        expect(c.error, isNull);
      },
    );

    test(
      'a non-retryable validation error is not retried automatically',
      () async {
        service.onSearch = (_) async =>
            throw apiError(422, message: 'limit must be…');
        await c.loadInitial();
        await settle(80);
        expect(service.calls, hasLength(1));
        expect(c.error!.isRetryable, isFalse);
      },
    );

    test('401 tells the session to sign out', () async {
      service.onSearch = (_) async => throw apiError(401);
      await c.loadInitial();
      expect(unauthorized, 1);
      expect(c.status, ListStatus.error);
    });
  });

  group('duplicate requests', () {
    test('an identical first-page load in flight is not sent twice', () async {
      final gate = Completer<ProductPage>();
      service.onSearch = (_) => gate.future;
      final a = c.loadInitial();
      final b = c.loadInitial();
      final r = c.retry();
      gate.complete(page([productJson(id: 1)]));
      await Future.wait([a, b, r]);
      expect(service.calls, hasLength(1));
    });
  });

  group('search', () {
    test('typing is debounced: only the final text is searched', () async {
      await c.loadInitial();
      service.calls.clear();
      for (final t in ['m', 'mi', 'mil', 'milk']) {
        c.onQueryChanged(t);
      }
      expect(service.calls, isEmpty);
      await settle();
      expect(service.calls.map((x) => x.query), ['milk']);
      expect(service.calls.single.page, 1);
    });

    test(
      'submitQuery searches immediately and cancels the pending debounce',
      () async {
        await c.loadInitial();
        service.calls.clear();
        c.onQueryChanged('mil');
        await c.submitQuery('milk');
        await settle();
        expect(service.calls.map((x) => x.query), ['milk']);
      },
    );

    test(
      'changing the query resets pagination to page 1 and clears old rows',
      () async {
        service.onSearch = (call) async => page(
          [productJson(id: call.page * 10 + 1)],
          page: call.page,
          totalPages: 3,
          total: 3,
        );
        await c.loadInitial();
        await c.loadNextPage();
        expect(service.calls.last.page, 2);

        service.onSearch = (call) async =>
            page([productJson(id: 99, name: 'Milk')]);
        await c.submitQuery('milk');
        expect(service.calls.last.page, 1);
        expect(service.calls.last.query, 'milk');
        expect(c.items.map((i) => i.id), [99]);
        expect(c.hasMore, isFalse);
      },
    );

    test(
      'no-result search shows the empty state and keeps the query',
      () async {
        service.onSearch = (_) async => page([]);
        await c.submitQuery('zzz');
        expect(c.status, ListStatus.empty);
        expect(c.query, 'zzz');
      },
    );

    test('an unchanged query does not trigger a reload', () async {
      await c.submitQuery('milk');
      service.calls.clear();
      c.onQueryChanged('milk');
      await settle();
      expect(service.calls, isEmpty);
    });

    test('a slow earlier response never overwrites a newer search', () async {
      final slow = Completer<ProductPage>();
      service.onSearch = (call) {
        if (call.query == 'old') return slow.future;
        return Future.value(page([productJson(id: 2, name: 'New')]));
      };
      final first = c.submitQuery('old');
      await c.submitQuery('new');
      slow.complete(page([productJson(id: 1, name: 'Old')]));
      await first;
      expect(c.items.map((i) => i.id), [2]);
      expect(c.status, ListStatus.loaded);
    });
  });

  group('categories', () {
    test(
      'loads categories once; selecting resets to page 1 and sends category_id',
      () async {
        service.onCategories = () async => [
          const ProductCategory(id: 5, name: 'Dairy'),
        ];
        await c.loadCategories();
        expect(c.categories.single.name, 'Dairy');

        service.onSearch = (call) async =>
            page([productJson(id: 1)], page: call.page, totalPages: 2);
        await c.loadInitial();
        await c.loadNextPage();
        service.calls.clear();
        await c.selectCategory(5);
        expect(service.calls.single.categoryId, 5);
        expect(service.calls.single.page, 1);
        expect(c.categoryId, 5);
      },
    );

    test('"All categories" (null) drops the filter', () async {
      await c.selectCategory(5);
      service.calls.clear();
      await c.selectCategory(null);
      expect(service.calls.single.categoryId, isNull);
    });

    test('re-selecting the same category does nothing', () async {
      await c.selectCategory(5);
      service.calls.clear();
      await c.selectCategory(5);
      expect(service.calls, isEmpty);
    });

    test('category and search combine', () async {
      await c.selectCategory(3);
      service.calls.clear();
      await c.submitQuery('tea');
      expect(
        (service.calls.single.query, service.calls.single.categoryId),
        ('tea', 3),
      );
    });

    test(
      'a category load failure is reported but does not block products',
      () async {
        service.onCategories = () async => throw apiError(500);
        await c.loadCategories();
        expect(c.categoriesError, isNotNull);
        service.onSearch = (_) async => page([productJson(id: 1)]);
        await c.loadInitial();
        expect(c.status, ListStatus.loaded);
      },
    );

    test('concurrent loadCategories calls issue one request', () async {
      final gate = Completer<List<ProductCategory>>();
      service.onCategories = () => gate.future;
      final a = c.loadCategories();
      final b = c.loadCategories();
      gate.complete([]);
      await Future.wait([a, b]);
      expect(service.categoryCalls, 1);
    });
  });

  group('pagination', () {
    setUp(() {
      service.onSearch = (call) async => page(
        [
          productJson(id: call.page * 10 + 1),
          productJson(id: call.page * 10 + 2),
        ],
        page: call.page,
        total: 6,
        totalPages: 3,
      );
    });

    test('loads page 1 then appends page 2 and 3, then stops', () async {
      await c.loadInitial();
      expect(c.hasMore, isTrue);
      await c.loadNextPage();
      await c.loadNextPage();
      expect(c.items.map((i) => i.id), [11, 12, 21, 22, 31, 32]);
      expect(c.hasMore, isFalse);
      service.calls.clear();
      await c.loadNextPage();
      expect(service.calls, isEmpty, reason: 'no request past the last page');
      expect(service.calls.length, 0);
    });

    test('page size is sent as the limit', () async {
      await c.loadInitial();
      expect(service.calls.single.limit, 2);
    });

    test('concurrent loadNextPage calls fetch the next page once', () async {
      await c.loadInitial();
      service.calls.clear();
      final gate = Completer<ProductPage>();
      service.onSearch = (_) => gate.future;
      final a = c.loadNextPage();
      final b = c.loadNextPage();
      final d = c.loadNextPage();
      expect(c.loadingMore, isTrue);
      gate.complete(
        page([productJson(id: 21)], page: 2, total: 6, totalPages: 3),
      );
      await Future.wait([a, b, d]);
      expect(service.calls, hasLength(1));
      expect(service.calls.single.page, 2);
    });

    test('rows repeated across pages are not duplicated', () async {
      service.onSearch = (call) async => page(
        [productJson(id: 1), productJson(id: call.page + 1)],
        page: call.page,
        totalPages: 2,
      );
      await c.loadInitial();
      await c.loadNextPage();
      expect(c.items.map((i) => i.id), [1, 2, 3]);
    });

    test('a failed next page keeps the rows on screen and can be retried explicitly', () async {
      await c.loadInitial();
      service.onSearch = (_) async => throw apiError(500);
      await c.loadNextPage();
      expect(c.status, ListStatus.loaded);
      expect(c.items, hasLength(2));
      expect(c.loadMoreError, isNotNull);
      expect(c.loadingMore, isFalse);

      service.onSearch = (call) async =>
          page([productJson(id: 21)], page: call.page, totalPages: 3);
      await c.loadNextPage();
      expect(c.loadMoreError, isNull);
      expect(c.items.map((i) => i.id), [11, 12, 21]);
    });

    test(
      'a next-page response that arrives after the query changed is discarded',
      () async {
        await c.loadInitial();
        final late = Completer<ProductPage>();
        service.onSearch = (call) => call.page == 2 && call.query == null
            ? late.future
            : Future.value(page([productJson(id: 500, name: 'Fresh')]));
        final next = c.loadNextPage();
        await c.submitQuery('fresh');
        late.complete(page([productJson(id: 999)], page: 2, totalPages: 3));
        await next;
        expect(c.items.map((i) => i.id), [500]);
        expect(c.loadingMore, isFalse);
      },
    );

    test(
      'loadNextPage before the first page has loaded does nothing',
      () async {
        await c.loadNextPage();
        expect(service.calls, isEmpty);
      },
    );
  });

  test('disposing while a request is in flight does not throw', () async {
    final gate = Completer<ProductPage>();
    service.onSearch = (_) => gate.future;
    final local = make();
    final f = local.loadInitial();
    local.dispose();
    gate.complete(page([productJson(id: 1)]));
    await f;
  });

  test('the ApiException kind is preserved on the controller', () async {
    service.onSearch = (_) async => throw apiError(403, message: 'Forbidden');
    await c.loadInitial();
    expect(c.error!.kind, ApiErrorKind.forbidden);
  });
}
