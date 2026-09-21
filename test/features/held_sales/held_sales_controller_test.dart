import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:buskit_pos/features/held_sales/state/held_sales_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

HeldSaleSummary row(int id, {int version = 2}) =>
    HeldSaleSummary.fromJson(heldRowJson(id: id, version: version))!;

void main() {
  late FakeHeldSalesService list;
  late FakeCartService detailService;
  late HeldSalesController c;

  setUp(() {
    list = FakeHeldSalesService();
    detailService = FakeCartService();
    c = HeldSalesController(list, detailService);
  });
  tearDown(() => c.dispose());

  group('list states', () {
    test(
      'idle -> loading -> loaded with the server order and a count',
      () async {
        final gate = Completer<List<HeldSaleSummary>>();
        list.onList = () => gate.future;
        expect(c.heldCount, isNull);
        final f = c.refresh();
        expect(c.status, HeldListStatus.loading);
        expect(c.isLoading, isTrue);
        gate.complete([row(12), row(9)]);
        await f;
        expect(c.status, HeldListStatus.loaded);
        expect(c.sales.map((s) => s.id), [12, 9]);
        expect(c.heldCount, 2);
        expect(c.isLoading, isFalse);
      },
    );

    test('empty list', () async {
      await c.refresh();
      expect(c.status, HeldListStatus.empty);
      expect(c.heldCount, 0);
    });

    test('retryable error, then Retry recovers', () async {
      list.onList = () async =>
          throw apiError(500, message: 'SELECT * FROM pos_sales');
      await c.refresh();
      expect(c.status, HeldListStatus.error);
      expect(c.error!.isRetryable, isTrue);
      expect(c.error!.message, isNot(contains('SELECT')));
      expect(c.heldCount, isNull);
      list.onList = () async => [row(1)];
      await c.refresh();
      expect(c.status, HeldListStatus.loaded);
      expect(c.error, isNull);
    });

    test('network and timeout are retryable; 403 and 422 are not', () async {
      for (final e in [
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
        const ApiException(kind: ApiErrorKind.timeout, message: 'slow'),
      ]) {
        list.onList = () async => throw e;
        await c.refresh();
        expect(c.error!.isRetryable, isTrue, reason: '${e.kind}');
      }
      for (final s in [403, 422]) {
        list.onList = () async => throw apiError(s, message: 'nope');
        await c.refresh();
        expect(c.error!.isRetryable, isFalse, reason: '$s');
      }
    });

    test('401 is reported as unauthorized (the API client signs the session out once)', () async {
      list.onList = () async => throw apiError(401);
      await c.refresh();
      expect(c.error!.isUnauthorized, isTrue);
    });

    test(
      'a failed refresh keeps the list already on screen and records the error',
      () async {
        list.onList = () async => [row(1), row(2)];
        await c.refresh();
        list.onList = () async => throw apiError(500);
        await c.refresh();
        expect(c.status, HeldListStatus.loaded);
        expect(c.sales, hasLength(2));
        expect(c.error, isNotNull);
      },
    );

    test('a failure is not retried automatically', () async {
      list.onList = () async => throw apiError(500);
      await c.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(list.calls, 1);
    });
  });

  group('duplicate and queued loading', () {
    test('concurrent refreshes issue one request while it runs', () async {
      final gate = Completer<List<HeldSaleSummary>>();
      list.onList = () => gate.future;
      final a = c.refresh();
      final b = c.refresh();
      gate.complete([row(1)]);
      await Future.wait([a, b]);
      expect(
        list.calls,
        2,
        reason: 'the queued follow-up reload runs once, never in parallel',
      );
    });

    test('never two list requests in flight at once', () async {
      var inFlight = 0;
      var maxInFlight = 0;
      list.onList = () async {
        inFlight++;
        maxInFlight = inFlight > maxInFlight ? inFlight : maxInFlight;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        inFlight--;
        return [row(1)];
      };
      await Future.wait([c.refresh(), c.refresh(), c.refresh(), c.refresh()]);
      expect(maxInFlight, 1);
      expect(
        list.calls,
        lessThanOrEqualTo(2),
        reason: 'queued refreshes collapse into a single follow-up',
      );
    });

    test(
      'a refresh requested during a load reflects the LATEST server state',
      () async {
        final gate = Completer<List<HeldSaleSummary>>();
        var first = true;
        list.onList = () {
          if (first) {
            first = false;
            return gate.future; // stale snapshot (before the hold)
          }
          return Future.value([row(1), row(2)]); // after the hold
        };
        final a = c.refresh();
        final b = c.refresh(); // e.g. triggered by a successful hold
        gate.complete([row(1)]);
        await Future.wait([a, b]);
        expect(c.sales.map((s) => s.id), [1, 2]);
      },
    );

    test('reset drops an in-flight response', () async {
      final gate = Completer<List<HeldSaleSummary>>();
      list.onList = () => gate.future;
      final f = c.refresh();
      c.reset();
      gate.complete([row(1)]);
      await f;
      expect(c.sales, isEmpty);
      expect(c.status, HeldListStatus.idle);
      expect(c.isLoading, isFalse);
    });
  });

  test(
    'removeLocally drops one sale and flips to empty when it was the last',
    () async {
      list.onList = () async => [row(1), row(2)];
      await c.refresh();
      c.removeLocally(1);
      expect(c.sales.map((s) => s.id), [2]);
      c.removeLocally(2);
      expect(c.status, HeldListStatus.empty);
      c.removeLocally(99); // unknown: no-op
    },
  );

  group('detail preview', () {
    CartSale view(int id, {String status = 'held', int version = 5}) =>
        CartSale.fromJson(
          saleJson(
            id: id,
            version: version,
            status: status,
            items: [lineJson(id: 1, name: 'Tea')],
          ),
        )!;

    test('loads the live sale (items, totals, current version)', () async {
      detailService.onGet = (id) async => view(id);
      await c.openDetail(12);
      expect(c.detailSaleId, 12);
      expect(c.detail!.version, 5);
      expect(c.detail!.items.single.productName, 'Tea');
      expect(c.detailLoading, isFalse);
    });

    test('errors are kept with their kind; retry via openDetail', () async {
      detailService.onGet = (_) async => throw apiError(500);
      await c.openDetail(12);
      expect(c.detailError!.isRetryable, isTrue);
      expect(c.detail, isNull);
      detailService.onGet = (id) async => view(id);
      await c.openDetail(12);
      expect(c.detailError, isNull);
      expect(c.detail, isNotNull);
    });

    test('a slow response for a previously selected sale cannot replace the current one', () async {
      final slow = Completer<CartSale>();
      detailService.onGet = (id) =>
          id == 1 ? slow.future : Future.value(view(2));
      final first = c.openDetail(1);
      await c.openDetail(2);
      slow.complete(view(1));
      await first;
      expect(c.detailSaleId, 2);
      expect(c.detail!.id, 2);
      expect(c.detailLoading, isFalse);
    });

    test('closing the detail discards a response that arrives later', () async {
      final slow = Completer<CartSale>();
      detailService.onGet = (_) => slow.future;
      final f = c.openDetail(1);
      c.closeDetail();
      slow.complete(view(1));
      await f;
      expect(c.detailSaleId, isNull);
      expect(c.detail, isNull);
    });
  });

  test('disposing while a request is in flight does not throw', () async {
    final gate = Completer<List<HeldSaleSummary>>();
    list.onList = () => gate.future;
    final local = HeldSalesController(list, detailService);
    final f = local.refresh();
    local.dispose();
    gate.complete([row(1)]);
    await f;
  });
}
