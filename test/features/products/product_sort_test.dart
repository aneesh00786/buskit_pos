import 'dart:async';

import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/product_card.dart';
import 'package:buskit_pos/features/products/ui/product_filter_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';
import '../../support/pump_page.dart';

ProductPage pageOf(
  List<String> names, {
  int page = 1,
  int totalPages = 1,
  int? total,
  int startId = 1,
}) => page_(
  names,
  page: page,
  totalPages: totalPages,
  total: total,
  startId: startId,
);

ProductPage page_(
  List<String> names, {
  int page = 1,
  int totalPages = 1,
  int? total,
  int startId = 1,
}) => ProductPage.fromJson({
  'items': [
    for (var i = 0; i < names.length; i++)
      productJson(id: startId + i, name: names[i]),
  ],
  'pagination': {
    'page': page,
    'limit': 20,
    'total': total ?? names.length,
    'total_pages': totalPages,
  },
});

List<String> names(ProductListController c) =>
    c.groups.map((g) => g.name).toList();

void main() {
  late FakeProductService service;
  late ProductListController c;

  setUp(() {
    service = FakeProductService();
    c = ProductListController(
      service,
      debounce: const Duration(milliseconds: 10),
      pageSize: 20,
    );
  });
  tearDown(() => c.dispose());

  group('local sort (controller)', () {
    setUp(
      () =>
          service.onSearch = (_) async =>
              pageOf(['Banana', 'apple', 'Cherry', 'Date']),
    );

    test('Default preserves the exact server order', () async {
      await c.loadInitial();
      expect(c.sort, ProductSort.serverOrder);
      expect(names(c), ['Banana', 'apple', 'Cherry', 'Date']);
    });

    test('A–Z sorts ascending, ignoring case', () async {
      await c.loadInitial();
      c.setSort(ProductSort.nameAsc);
      expect(names(c), ['apple', 'Banana', 'Cherry', 'Date']);
    });

    test('Z–A sorts descending, ignoring case', () async {
      await c.loadInitial();
      c.setSort(ProductSort.nameDesc);
      expect(names(c), ['Date', 'Cherry', 'Banana', 'apple']);
    });

    test('switching back to Default restores the server order', () async {
      await c.loadInitial();
      c.setSort(ProductSort.nameDesc);
      c.setSort(ProductSort.serverOrder);
      expect(names(c), ['Banana', 'apple', 'Cherry', 'Date']);
    });

    test(
      'equal names are ordered deterministically by id in both directions',
      () async {
        service.onSearch = (_) async =>
            pageOf(['Tea', 'Tea', 'Coffee'], startId: 10);
        await c.loadInitial();
        c.setSort(ProductSort.nameAsc);
        expect(c.groups.map((g) => g.first.id), [12, 10, 11]);
        c.setSort(ProductSort.nameDesc);
        expect(c.groups.map((g) => g.first.id), [10, 11, 12]);
      },
    );

    test(
      'variations of one product stay together and keep their server order',
      () async {
        service.onSearch = (_) async => ProductPage.fromJson({
          'items': [
            productJson(
              id: 1,
              productId: 'Z',
              name: 'Zucchini',
              variation: '1kg',
            ),
            productJson(
              id: 2,
              productId: 'A',
              name: 'Apple',
              variation: 'Small',
            ),
            productJson(
              id: 3,
              productId: 'Z',
              name: 'Zucchini',
              variation: '5kg',
            ),
            productJson(
              id: 4,
              productId: 'A',
              name: 'Apple',
              variation: 'Large',
            ),
          ],
          'pagination': {'page': 1, 'limit': 20, 'total': 4, 'total_pages': 1},
        });
        await c.loadInitial();
        c.setSort(ProductSort.nameAsc);
        expect(names(c), ['Apple', 'Zucchini']);
        expect(c.groups.first.variations.map((v) => v.variationName), [
          'Small',
          'Large',
        ]);
        expect(c.groups.last.variations.map((v) => v.variationName), [
          '1kg',
          '5kg',
        ]);
      },
    );

    test(
      'changing the sort makes NO request and does not reset pagination',
      () async {
        service.onSearch = (call) async => pageOf(
          ['B$call', 'A$call'],
          page: call.page,
          totalPages: 3,
          total: 6,
        );
        await c.loadInitial();
        await c.loadNextPage();
        final calls = service.calls.length;
        final loaded = c.loadedCount;
        c.setSort(ProductSort.nameAsc);
        c.setSort(ProductSort.nameDesc);
        expect(service.calls.length, calls);
        expect(c.loadedCount, loaded);
        expect(c.hasMore, isTrue, reason: 'still on page 2 of 3');
        await c.loadNextPage();
        expect(
          service.calls.last.page,
          3,
          reason: 'the page counter was not disturbed',
        );
      },
    );

    test('an unchanged sort does not notify listeners', () async {
      await c.loadInitial();
      var n = 0;
      c.addListener(() => n++);
      c.setSort(ProductSort.serverOrder);
      expect(n, 0);
    });
  });

  group('sort combined with search and category', () {
    test(
      'the chosen sort survives a new search and orders the new results',
      () async {
        service.onSearch = (call) async => call.query == 'a'
            ? pageOf(['Pear', 'Apricot', 'Banana'])
            : pageOf(['Zebra', 'Yak']);
        await c.loadInitial();
        c.setSort(ProductSort.nameAsc);
        await c.submitQuery('a');
        expect(service.calls.last.query, 'a');
        expect(c.sort, ProductSort.nameAsc);
        expect(names(c), ['Apricot', 'Banana', 'Pear']);
      },
    );

    test('the chosen sort survives a category change; the request carries only the supported params', () async {
      service.onSearch = (call) async => call.categoryId == 5
          ? pageOf(['Milk', 'Butter', 'Cheese'])
          : pageOf(['Bread']);
      await c.loadInitial();
      c.setSort(ProductSort.nameDesc);
      await c.selectCategory(5);
      expect((service.calls.last.categoryId, service.calls.last.page), (5, 1));
      expect(names(c), ['Milk', 'Cheese', 'Butter']);
    });

    test('search + category + sort together', () async {
      service.onSearch = (call) async =>
          (call.query == 'ch' && call.categoryId == 5)
          ? pageOf(['Cheddar', 'Chives', 'Cheese'])
          : pageOf(['x']);
      await c.loadInitial();
      c.setSort(ProductSort.nameAsc);
      await c.selectCategory(5);
      await c.submitQuery('ch');
      expect(names(c), ['Cheddar', 'Cheese', 'Chives']);
      expect(
        (service.calls.last.query, service.calls.last.categoryId),
        ('ch', 5),
      );
    });

    test(
      'no-result search still shows the empty state with a sort applied',
      () async {
        service.onSearch = (_) async => pageOf([]);
        c.setSort(ProductSort.nameDesc);
        await c.submitQuery('zzz');
        expect(c.status, ListStatus.empty);
        expect(c.sort, ProductSort.nameDesc);
      },
    );
  });

  group('sort and pagination', () {
    test('pages appended under a sort are merged into the sorted order, without duplicates', () async {
      service.onSearch = (call) async => call.page == 1
          ? pageOf(['Banana', 'Date'], page: 1, totalPages: 2, total: 4)
          : pageOf(
              ['Apple', 'Cherry', 'Date'],
              page: 2,
              totalPages: 2,
              total: 4,
              startId: 3,
            );
      await c.loadInitial();
      c.setSort(ProductSort.nameAsc);
      expect(names(c), ['Banana', 'Date']);
      await c.loadNextPage();
      expect(names(c), ['Apple', 'Banana', 'Cherry', 'Date', 'Date']);
      expect(c.hasMore, isFalse);
    });

    test(
      'sortIsPartial is true only while a local sort covers a partial result',
      () async {
        service.onSearch = (call) async =>
            pageOf(['B', 'A'], page: call.page, totalPages: 2, total: 4);
        await c.loadInitial();
        expect(c.sortIsPartial, isFalse, reason: 'Default is the server order');
        c.setSort(ProductSort.nameAsc);
        expect(c.sortIsPartial, isTrue);
        expect((c.loadedCount, c.total), (2, 4));
        await c.loadNextPage();
        expect(c.sortIsPartial, isFalse, reason: 'everything is loaded now');
      },
    );

    test('a slow response for an OLD query never overwrites a newer one, and the sort is untouched', () async {
      final slow = Completer<ProductPage>();
      service.onSearch = (call) => call.query == 'old'
          ? slow.future
          : Future.value(pageOf(['Yak', 'Zebra']));
      final first = c.submitQuery('old');
      c.setSort(ProductSort.nameDesc);
      await c.submitQuery('new');
      slow.complete(pageOf(['Old1', 'Old2']));
      await first;
      expect(names(c), ['Zebra', 'Yak']);
      expect(c.sort, ProductSort.nameDesc);
    });

    test('a next-page response that arrives after the query changed is discarded, sort applied to the new results', () async {
      service.onSearch = (call) async =>
          pageOf(['B', 'A'], page: call.page, totalPages: 3, total: 6);
      await c.loadInitial();
      c.setSort(ProductSort.nameAsc);
      final late = Completer<ProductPage>();
      service.onSearch = (call) => (call.page == 2 && call.query == null)
          ? late.future
          : Future.value(pageOf(['Fresh2', 'Fresh1']));
      final next = c.loadNextPage();
      await c.submitQuery('fresh');
      late.complete(pageOf(['Late'], page: 2, totalPages: 3, total: 6));
      await next;
      expect(names(c), ['Fresh1', 'Fresh2']);
    });
  });

  group('loadRemaining (make the sort cover everything)', () {
    setUp(() {
      service.onSearch = (call) async => pageOf(
        ['P${call.page}b', 'P${call.page}a'],
        page: call.page,
        totalPages: 3,
        total: 6,
        startId: call.page * 10,
      );
    });

    test(
      'loads each remaining page exactly once, then the sort is complete',
      () async {
        await c.loadInitial();
        c.setSort(ProductSort.nameDesc);
        await c.loadRemaining();
        expect(service.calls.map((x) => x.page), [1, 2, 3]);
        expect(c.hasMore, isFalse);
        expect(c.sortIsPartial, isFalse);
        expect(names(c), ['P3b', 'P3a', 'P2b', 'P2a', 'P1b', 'P1a']);
        expect(c.isLoadingAll, isFalse);
      },
    );

    test('stops at the first error and does not retry', () async {
      await c.loadInitial();
      final ok = service.onSearch;
      service.onSearch = (call) =>
          call.page == 2 ? Future.error(apiError(500)) : ok(call);
      await c.loadRemaining();
      expect(service.calls.map((x) => x.page), [1, 2]);
      expect(c.loadMoreError, isNotNull);
      expect(c.isLoadingAll, isFalse);
    });

    test('concurrent calls run one loop; a scroll-triggered page load is never duplicated', () async {
      await c.loadInitial();
      final a = c.loadRemaining();
      final b = c.loadRemaining();
      final scroll = c.loadNextPage();
      await Future.wait([a, b, scroll]);
      final pages = service.calls.map((x) => x.page).toList()..sort();
      expect(pages, [1, 2, 3], reason: 'every page requested exactly once');
    });

    test('does nothing before the first page has loaded', () async {
      await c.loadRemaining();
      expect(service.calls, isEmpty);
    });

    test(
      'a query change mid-way ends the loop (no stale pages appended)',
      () async {
        await c.loadInitial();
        final gate = Completer<ProductPage>();
        final ok = service.onSearch;
        service.onSearch = (call) =>
            (call.page == 2 && call.query == null) ? gate.future : ok(call);
        final all = c.loadRemaining();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await c.submitQuery('other');
        gate.complete(pageOf(['Stale'], page: 2, totalPages: 3, total: 6));
        await all;
        expect(names(c).any((n) => n == 'Stale'), isFalse);
      },
    );
  });

  group('sort on the page', () {
    Future<void> setSortOnPage(WidgetTester tester, String label) async {
      await tester.tap(find.byType(DropdownButton<ProductSort>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    double y(WidgetTester t, String name) => t.getTopLeft(find.text(name)).dy;

    Future<PageHarness> harness(
      WidgetTester tester, {
      double width = 1400,
      double height = 900,
      List<String>? items,
      int totalPages = 1,
      int total = 3,
      ThemeData? theme,
      double textScale = 1,
    }) async {
      final h = PageHarness();
      h.products.onSearch = (call) async => pageOf(
        items ?? ['Banana', 'apple', 'Cherry'],
        page: call.page,
        totalPages: totalPages,
        total: total,
      );
      await pumpProductsPage(
        tester,
        h,
        width: width,
        height: height,
        theme: theme,
        textScale: textScale,
      );
      await tester.tap(find.byTooltip('List view'));
      await tester.pumpAndSettle();
      return h;
    }

    testWidgets(
      'the dropdown offers Default, A–Z and Z–A and starts on Default',
      (tester) async {
        await harness(tester);
        expect(find.text('Default'), findsOneWidget);
        await tester.tap(find.byType(DropdownButton<ProductSort>));
        await tester.pumpAndSettle();
        expect(find.text('A–Z'), findsOneWidget);
        expect(find.text('Z–A'), findsOneWidget);
      },
    );

    testWidgets(
      'A–Z then Z–A reorder the visible products; Default restores the server order',
      (tester) async {
        await harness(tester);
        expect(
          y(tester, 'Banana') < y(tester, 'apple'),
          isTrue,
          reason: 'server order',
        );

        await setSortOnPage(tester, 'A–Z');
        expect(y(tester, 'apple') < y(tester, 'Banana'), isTrue);
        expect(y(tester, 'Banana') < y(tester, 'Cherry'), isTrue);

        await setSortOnPage(tester, 'Z–A');
        expect(y(tester, 'Cherry') < y(tester, 'Banana'), isTrue);
        expect(y(tester, 'Banana') < y(tester, 'apple'), isTrue);

        await setSortOnPage(tester, 'Default');
        expect(y(tester, 'Banana') < y(tester, 'apple'), isTrue);
      },
    );

    testWidgets('sorting sends no request', (tester) async {
      final h = await harness(tester);
      final calls = h.products.calls.length;
      await setSortOnPage(tester, 'A–Z');
      expect(h.products.calls.length, calls);
    });

    testWidgets(
      'sort + search: the sort stays while the search results replace the list',
      (tester) async {
        final h = PageHarness();
        h.products.onSearch = (c) async => c.query == 'a'
            ? pageOf(['Pear', 'Apricot', 'Banana'])
            : pageOf(['Zed', 'Alpha']);
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        await tester.tap(find.byTooltip('List view'));
        await tester.pumpAndSettle();
        await setSortOnPage(tester, 'A–Z');
        await tester.enterText(find.byType(TextField), 'a');
        await tester.pump(const Duration(milliseconds: 50));
        await tester.pumpAndSettle();
        expect(h.products.calls.last.query, 'a');
        expect(y(tester, 'Apricot') < y(tester, 'Banana'), isTrue);
        expect(y(tester, 'Banana') < y(tester, 'Pear'), isTrue);
        expect(find.text('A–Z'), findsOneWidget, reason: 'still selected');
      },
    );

    testWidgets('sort + category chip', (tester) async {
      final h = PageHarness();
      h.products.onCategories = () async => [
        const ProductCategory(id: 5, name: 'Dairy'),
      ];
      h.products.onSearch = (c) async =>
          c.categoryId == 5 ? pageOf(['Milk', 'Butter']) : pageOf(['Bread']);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await tester.tap(find.byTooltip('List view'));
      await tester.pumpAndSettle();
      await setSortOnPage(tester, 'Z–A');
      await tester.tap(find.text('Dairy'));
      await tester.pumpAndSettle();
      expect(y(tester, 'Milk') < y(tester, 'Butter'), isTrue);
    });

    testWidgets(
      'a partial result under a local sort says so honestly and offers Load all',
      (tester) async {
        final h = await harness(
          tester,
          items: ['Banana', 'apple'],
          totalPages: 3,
          total: 6,
        );
        expect(
          find.textContaining('Sorted within'),
          findsNothing,
          reason: 'Default is the server order across the whole catalog',
        );
        await setSortOnPage(tester, 'Z–A');
        expect(
          find.text('Sorted within the 2 of 6 items loaded so far.'),
          findsOneWidget,
        );
        h.products.calls.clear();
        await tester.tap(find.text('Load all'));
        await tester.pumpAndSettle();
        expect(h.products.calls.map((c) => c.page), [2, 3]);
        expect(
          find.textContaining('Sorted within'),
          findsNothing,
          reason: 'the sort now covers everything',
        );
      },
    );

    testWidgets('no note when everything fits on one page', (tester) async {
      await harness(tester);
      await setSortOnPage(tester, 'A–Z');
      expect(find.textContaining('Sorted within'), findsNothing);
      expect(find.text('Load all'), findsNothing);
    });

    testWidgets('scroll pagination still appends under a sort', (tester) async {
      final h = PageHarness();
      h.products.onSearch = (c) async => pageOf(
        [
          for (var i = 0; i < 20; i++)
            'Item ${c.page}-${i.toString().padLeft(2, '0')}',
        ],
        page: c.page,
        totalPages: 2,
        total: 40,
        startId: c.page * 100,
      );
      await pumpProductsPage(tester, h, width: 420, height: 800);
      await setSortOnPage(tester, 'A–Z');
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -9000));
      await tester.pumpAndSettle();
      expect(h.products.calls.map((c) => c.page), [1, 2]);
    });

    testWidgets(
      'loading state: the control is present, and choosing a sort while loading is safe',
      (tester) async {
        final h = PageHarness();
        final gate = Completer<ProductPage>();
        h.products.onSearch = (_) => gate.future;
        await pumpProductsPageRaw(tester, h);
        expect(find.byType(DropdownButton<ProductSort>), findsOneWidget);
        h.list.setSort(ProductSort.nameAsc);
        gate.complete(pageOf(['B', 'A']));
        await tester.pumpAndSettle();
        expect(h.list.sort, ProductSort.nameAsc);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('empty state with a sort selected', (tester) async {
      final h = PageHarness();
      h.products.onSearch = (_) async => pageOf([]);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await setSortOnPage(tester, 'A–Z');
      expect(find.text('No products found'), findsOneWidget);
      expect(find.byType(DropdownButton<ProductSort>), findsOneWidget);
    });

    testWidgets(
      'sorted products with missing images still render placeholders',
      (tester) async {
        await harness(tester);
        await setSortOnPage(tester, 'A–Z');
        expect(
          find.byIcon(Icons.image_not_supported_outlined),
          findsNWidgets(3),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('renders in dark mode', (tester) async {
      await harness(tester, theme: AppTheme.dark());
      await setSortOnPage(tester, 'Z–A');
      expect(tester.takeException(), isNull);
      expect(find.text('Z–A'), findsOneWidget);
    });

    testWidgets('grid mode sorts too', (tester) async {
      final h = PageHarness();
      h.products.onSearch = (_) async => pageOf(['Banana', 'apple', 'Cherry']);
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      await setSortOnPage(tester, 'A–Z');
      final cards = tester
          .widgetList<ProductCard>(find.byType(ProductCard))
          .map((c) => c.group.name)
          .toList();
      expect(cards, ['apple', 'Banana', 'Cherry']);
    });
  });

  group('dropdown layout', () {
    for (final size in const [
      Size(320, 568),
      Size(400, 800),
      Size(800, 1280),
      Size(1000, 800),
      Size(1400, 900),
      Size(1920, 1080),
    ]) {
      testWidgets(
        '${size.width.toInt()}x${size.height.toInt()}: fully on screen, ≥48dp tall, never overlaps the category chips, no overflow',
        (tester) async {
          final h = PageHarness();
          h.products.onCategories = () async => [
            for (var i = 1; i <= 12; i++)
              ProductCategory(id: i, name: 'Category number $i'),
          ];
          h.products.onSearch = (_) async => pageOf(['A', 'B']);
          await pumpProductsPage(
            tester,
            h,
            width: size.width,
            height: size.height,
          );
          expect(tester.takeException(), isNull);

          final dropdown = tester.getRect(find.byType(SortDropdown));
          final chips = tester.getRect(
            find.descendant(
              of: find.byType(ProductFilterBar),
              matching: find.byType(ListView),
            ),
          );
          expect(dropdown.left, greaterThanOrEqualTo(0));
          expect(dropdown.right, lessThanOrEqualTo(size.width));
          expect(dropdown.height, greaterThanOrEqualTo(48));
          if (size.width < 480) {
            expect(
              dropdown.bottom,
              lessThanOrEqualTo(chips.top),
              reason: 'narrow phones put the dropdown above the chips, beside the grid/list toggle',
            );
          } else {
            expect(
              chips.right,
              lessThanOrEqualTo(dropdown.left),
              reason: 'the chips scroll in their own area',
            );
          }
        },
      );
    }

    testWidgets('phone at 150% text scale', (tester) async {
      final h = PageHarness();
      h.products.onCategories = () async => [
        const ProductCategory(id: 1, name: 'Bakery'),
        const ProductCategory(id: 2, name: 'Beverages'),
      ];
      await pumpProductsPage(
        tester,
        h,
        width: 360,
        height: 700,
        textScale: 1.5,
      );
      expect(tester.takeException(), isNull);
      final dropdown = tester.getRect(find.byType(SortDropdown));
      expect(dropdown.right, lessThanOrEqualTo(360));
    });

    testWidgets(
      'is announced to screen readers as "Sort products" with its current value',
      (tester) async {
        final h = PageHarness();
        await pumpProductsPage(tester, h, width: 1400, height: 900);
        expect(find.byTooltip('Sort products'), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp('Sort products')), findsOneWidget);
      },
    );

    testWidgets('the menu opens over other content without moving the chips', (
      tester,
    ) async {
      final h = PageHarness();
      h.products.onCategories = () async => [
        const ProductCategory(id: 1, name: 'Bakery'),
      ];
      await pumpProductsPage(tester, h, width: 1400, height: 900);
      final before = tester.getRect(find.text('Bakery'));
      await tester.tap(find.byType(DropdownButton<ProductSort>));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.text('Bakery')), before);
    });
  });
}
