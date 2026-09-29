import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/promotions/data/promotion_service.dart';
import 'package:buskit_pos/features/promotions/models/promotion.dart';
import 'package:buskit_pos/features/promotions/state/promotion_list_controller.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_promotion_service.dart';

PromotionPage page(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int total = -1,
  int limit = 20,
}) {
  final items = rows.map(Promotion.fromJson).whereType<Promotion>().toList();
  final effectiveTotal = total < 0 ? items.length : total;
  return PromotionPage(
    items: items,
    pagination: Pagination(
      page: page,
      limit: limit,
      total: effectiveTotal,
      totalPages: total < 0
          ? 1
          : (effectiveTotal / limit).ceil().clamp(1, 1 << 30),
    ),
  );
}

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

void main() {
  test('idle -> loading -> loaded', () async {
    final svc = FakePromotionService();
    svc.onList = (_) async =>
        page([promotionJson(id: 1), promotionJson(id: 2)]);
    final c = PromotionListController(svc);
    expect(c.status, PromotionListStatus.idle);
    final f = c.loadInitial();
    expect(c.status, PromotionListStatus.loading);
    await f;
    expect(c.status, PromotionListStatus.loaded);
    expect(c.items.length, 2);
  });

  test('no results shows the empty state', () async {
    final c = PromotionListController(FakePromotionService());
    await c.loadInitial();
    expect(c.status, PromotionListStatus.empty);
  });

  test(
    'a failure with nothing loaded shows the error state; retry can recover',
    () async {
      final svc = FakePromotionService();
      svc.onList = (_) async => throw netDown;
      final c = PromotionListController(svc);
      await c.loadInitial();
      expect(c.status, PromotionListStatus.error);
      svc.onList = (_) async => page([promotionJson()]);
      await c.retry();
      expect(c.status, PromotionListStatus.loaded);
    },
  );

  test(
    'loadNextPage appends new rows, de-duplicated, and stops at the last page',
    () async {
      final svc = FakePromotionService();
      svc.onList = (call) async => page(
        [for (var i = 1; i <= 20; i++) promotionJson(id: i)],
        page: call.page,
        total: 25,
        limit: 20,
      );
      final c = PromotionListController(svc);
      await c.loadInitial();
      expect(c.hasMore, isTrue);
      svc.onList = (call) async => page(
        [for (var i = 21; i <= 25; i++) promotionJson(id: i)],
        page: call.page,
        total: 25,
        limit: 20,
      );
      await c.loadNextPage();
      expect(c.items.length, 25);
      expect(c.hasMore, isFalse);
      await c.loadNextPage(); // no-op past the last page
      expect(svc.listCalls.length, 2);
    },
  );

  test('a loadNextPage failure keeps the existing items and is reported separately', () async {
    final svc = FakePromotionService();
    svc.onList = (call) async =>
        page([promotionJson(id: 1)], page: 1, total: 2, limit: 1);
    final c = PromotionListController(svc);
    await c.loadInitial();
    svc.onList = (_) async => throw netDown;
    await c.loadNextPage();
    expect(c.items.length, 1, reason: 'stale list kept');
    expect(c.loadMoreError, netDown);
  });

  group('detail (select/close)', () {
    test(
      'select shows the already-fetched promotion; close clears it',
      () async {
        final svc = FakePromotionService();
        final promo = promotionJson(id: 1, title: 'Test 10% Off');
        svc.onList = (_) async => page([promo]);
        final c = PromotionListController(svc);
        await c.loadInitial();
        expect(c.selected, isNull);
        c.select(c.items.single);
        expect(c.selected!.title, 'Test 10% Off');
        c.closeDetail();
        expect(c.selected, isNull);
      },
    );
  });

  test(
    'a stale first-page response (superseded by a newer load) is discarded',
    () async {
      final svc = FakePromotionService();
      final gate = Completer<PromotionPage>();
      var calls = 0;
      svc.onList = (_) {
        calls++;
        return calls == 1
            ? gate.future
            : Future.value(page([promotionJson(title: 'Second load')]));
      };
      final c = PromotionListController(svc);
      final first = c.loadInitial();
      final second = c.loadInitial();
      gate.complete(page([promotionJson(title: 'First load')]));
      await first;
      await second;
      expect(c.items.single.title, 'Second load');
    },
  );
}
