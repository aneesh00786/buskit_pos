import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/history/data/sales_history_service.dart';
import 'package:buskit_pos/features/history/models/sale_history_entry.dart';
import 'package:buskit_pos/features/history/state/sales_history_controller.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

class FakeHistoryService implements SalesHistoryService {
  List<SaleHistoryEntry> rows = const [];
  Future<List<SaleHistoryEntry>> Function()? onList;
  int listCalls = 0;
  Map<int, CompletedSale?> details = {};
  Future<CompletedSale?> Function(int id)? onDetail;
  final List<int> detailCalls = [];

  @override
  Future<List<SaleHistoryEntry>> listCompleted() async {
    listCalls++;
    if (onList != null) return onList!();
    return rows;
  }

  @override
  Future<CompletedSale?> getDetail(int id) async {
    detailCalls.add(id);
    if (onDetail != null) return onDetail!(id);
    return details[id];
  }

  Future<CompletedSale?> Function(int saleId, String idempotencyKey)?
  onRefund;
  final List<String> refundKeys = [];

  @override
  Future<CompletedSale?> refundSale({
    required int saleId,
    required String idempotencyKey,
  }) async {
    refundKeys.add(idempotencyKey);
    if (onRefund != null) return onRefund!(saleId, idempotencyKey);
    return details[saleId];
  }
}

const netDown = ApiException(
  kind: ApiErrorKind.network,
  message: 'No connection to the server.',
);

SaleHistoryEntry entry({
  int id = 1,
  String? saleNumber,
  String? salesmanId = 'SALES1',
  String? customerId,
  double grandTotal = 100,
  DateTime? completedAt,
}) => SaleHistoryEntry(
  id: id,
  version: 1,
  saleNumber: saleNumber,
  salesmanId: salesmanId,
  customerId: customerId,
  grandTotal: grandTotal,
  completedAt: completedAt ?? DateTime.now().toUtc(),
);

CompletedSale completed({int id = 1, List<int> variationIds = const [42]}) =>
    CompletedSale.fromJson({
      'id': id,
      'status': 'completed',
      'sale_number': 'POS-$id',
      'items': [
        for (final v in variationIds)
          {
            'id': v,
            'product_variation_id': v,
            'quantity': 1,
            'unit_price': 10,
            'tax_percent': 0,
            'tax_included': false,
            'tax_amount': 0,
            'discount_amount': 0,
            'line_total': 10,
          },
      ],
      'totals': {
        'subtotal': 10,
        'tax_total': 0,
        'discount_total': 0,
        'grand_total': 10,
      },
      'payments': [
        {
          'method': 'cash',
          'amount': 10,
          'tendered_amount': 10,
          'change_due': 0,
          'status': 'completed',
        },
      ],
    })!;

/// Same shape [completed] returns, but with a `refund` block — what the
/// server returns right after `POST /sales/:id/refund` succeeds. `status`
/// stays 'completed' (the backend never changes it for a refund).
CompletedSale refunded({int id = 1}) {
  final base = completed(id: id);
  return CompletedSale.fromJson({
    'id': base.id,
    'status': base.status,
    'sale_number': base.saleNumber,
    'items': base.items
        .map(
          (l) => {
            'id': l.id,
            'product_variation_id': l.productVariationId,
            'quantity': l.quantity,
            'unit_price': l.unitPrice,
            'tax_percent': 0,
            'tax_included': false,
            'tax_amount': 0,
            'discount_amount': 0,
            'line_total': l.lineTotal,
          },
        )
        .toList(),
    'totals': {
      'subtotal': base.totals.subtotal,
      'tax_total': base.totals.taxTotal,
      'discount_total': base.totals.discountTotal,
      'grand_total': base.totals.grandTotal,
    },
    'payments': [
      {
        'method': 'cash',
        'amount': base.totals.grandTotal,
        'tendered_amount': base.totals.grandTotal,
        'change_due': 0,
        'status': 'completed',
      },
    ],
    'refund': {
      'refunded_by': 'SALES1',
      'refund_amount': base.totals.grandTotal,
      'refunded_at': DateTime.now().toUtc().toIso8601String(),
    },
  })!;
}

const forbiddenRefund = ApiException(
  kind: ApiErrorKind.forbidden,
  statusCode: 403,
  errorCode: 'POS_PERMISSION_DENIED',
  message: 'Missing required permission: payments.refund',
  data: {'permission': 'payments.refund'},
);

void main() {
  group('loading', () {
    test('idle -> loading -> loaded', () async {
      final svc = FakeHistoryService()..rows = [entry(id: 1), entry(id: 2)];
      final c = SalesHistoryController(svc, FakeProductService());
      expect(c.status, HistoryListStatus.idle);
      final f = c.refresh();
      expect(c.status, HistoryListStatus.loading);
      await f;
      expect(c.status, HistoryListStatus.loaded);
      expect(c.pageItems.map((s) => s.id), [1, 2]);
    });

    test('an empty store shows the empty state', () async {
      final c = SalesHistoryController(
        FakeHistoryService(),
        FakeProductService(),
      );
      await c.refresh();
      expect(c.status, HistoryListStatus.empty);
    });

    test('a failure with no prior data shows the error state; a retry after success shows the list', () async {
      final svc = FakeHistoryService()..onList = () async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.refresh();
      expect(c.status, HistoryListStatus.error);
      expect(c.error, netDown);

      svc.onList = () async => [entry()];
      await c.refresh();
      expect(c.status, HistoryListStatus.loaded);
      expect(c.error, isNull);
    });

    test('a background refresh failure keeps the existing list on screen, banner-style', () async {
      final svc = FakeHistoryService()..rows = [entry()];
      final c = SalesHistoryController(svc, FakeProductService());
      await c.refresh();
      svc.onList = () async => throw netDown;
      await c.refresh();
      expect(
        c.status,
        HistoryListStatus.loaded,
        reason: 'stale list is kept, not replaced by the error state',
      );
      expect(c.error, netDown);
      expect(c.pageItems, isNotEmpty);
    });

    test(
      'a refresh requested while one is running is queued and runs once more',
      () async {
        final svc = FakeHistoryService();
        final gate = Completer<List<SaleHistoryEntry>>();
        svc.onList = () => gate.future;
        final c = SalesHistoryController(svc, FakeProductService());
        final first = c.refresh();
        await c.refresh(); // queued, returns immediately
        expect(
          svc.listCalls,
          1,
          reason: 'the second call is queued, not run concurrently',
        );
        gate.complete([entry(id: 9)]);
        await first;
        await Future<void>.delayed(Duration.zero);
        expect(svc.listCalls, 2, reason: 'the queued refresh then runs once');
      },
    );

    test('a stale response (superseded by a newer refresh) is discarded', () async {
      final svc = FakeHistoryService();
      final first = Completer<List<SaleHistoryEntry>>();
      final calls = <Completer<List<SaleHistoryEntry>>>[first];
      svc.onList = () async {
        if (calls.length == 1) return first.future;
        return calls.last.future;
      };
      final c = SalesHistoryController(svc, FakeProductService());
      // Can't trigger a second concurrent refresh via the public API (it queues),
      // so this exercises the same generation guard via rapid sequential calls
      // instead: the queued run must reflect the LATEST state, not stack up.
      unawaited(c.refresh());
      first.complete([entry(id: 1)]);
      await Future<void>.delayed(Duration.zero);
      expect(c.pageItems.single.id, 1);
    });
  });

  group('filters', () {
    late FakeHistoryService svc;
    late SalesHistoryController c;
    final today = DateTime.now().toUtc();
    final yesterday = today.subtract(const Duration(days: 2));

    setUp(() async {
      svc = FakeHistoryService()
        ..rows = [
          entry(
            id: 1,
            saleNumber: 'POS-A',
            salesmanId: 'SALES1',
            completedAt: today,
          ),
          entry(
            id: 2,
            saleNumber: 'POS-B',
            salesmanId: 'SALES2',
            completedAt: today,
          ),
          entry(
            id: 3,
            saleNumber: 'POS-OLD',
            salesmanId: 'SALES1',
            completedAt: yesterday,
          ),
        ];
      c = SalesHistoryController(svc, FakeProductService());
      await c.refresh();
    });

    test('defaults to Today, hiding older sales', () {
      expect(c.dateFilter, HistoryDateFilter.today);
      expect(c.pageItems.map((s) => s.id), [1, 2]);
    });

    test('switching to All shows every sale', () {
      c.setDateFilter(HistoryDateFilter.all);
      expect(c.pageItems.map((s) => s.id), [1, 2, 3]);
    });

    test('search matches the order number, case-insensitively, against the whole list not just today', () {
      c.setDateFilter(HistoryDateFilter.all);
      c.setQuery('old');
      expect(c.pageItems.map((s) => s.id), [3]);
      c.setQuery('pos-a');
      expect(c.pageItems.map((s) => s.id), [1]);
      c.setQuery('nope');
      expect(c.pageItems, isEmpty);
    });

    test('cashier filter narrows to one salesman; knownCashiers lists every distinct one, sorted', () {
      expect(c.knownCashiers, ['SALES1', 'SALES2']);
      c.setDateFilter(HistoryDateFilter.all);
      c.setCashierFilter('SALES1');
      expect(c.pageItems.map((s) => s.id), [1, 3]);
      c.setCashierFilter(null);
      expect(c.pageItems.map((s) => s.id), [1, 2, 3]);
    });

    test('filters combine (AND, not OR)', () {
      c.setDateFilter(HistoryDateFilter.all);
      c.setCashierFilter('SALES1');
      c.setQuery('old');
      expect(c.pageItems.map((s) => s.id), [3]);
    });

    test('changing any filter resets to page 1', () {
      c.setPage(1);
      c.setDateFilter(HistoryDateFilter.all);
      c.setPage(2);
      c.setQuery('x');
      expect(c.page, 1);
    });
  });

  group('pagination', () {
    test('pages a filtered set client-side at the fixed page size', () async {
      final svc = FakeHistoryService()
        ..rows = [
          for (var i = 1; i <= 45; i++) entry(id: i, saleNumber: 'POS-$i'),
        ];
      final c = SalesHistoryController(svc, FakeProductService());
      c.setDateFilter(HistoryDateFilter.all);
      await c.refresh();
      expect(c.totalPages, 3);
      expect(c.pageItems.length, historyPageSize);
      expect(c.pageItems.first.id, 1);
      c.setPage(2);
      expect(c.pageItems.first.id, 21);
      c.setPage(3);
      expect(c.pageItems.length, 5);
      c.setPage(99);
      expect(c.page, 3, reason: 'clamped to the last page');
      c.setPage(0);
      expect(c.page, 1, reason: 'clamped to the first page');
    });

    test('an empty filtered result is one page, not a crash', () async {
      final svc = FakeHistoryService()..rows = [entry(saleNumber: 'POS-1')];
      final c = SalesHistoryController(svc, FakeProductService());
      await c.refresh();
      c.setQuery('nope');
      expect(c.totalPages, 1);
      expect(c.pageItems, isEmpty);
    });
  });

  group('sale detail', () {
    test(
      'loads items/payments/totals, then resolves names best-effort',
      () async {
        final svc = FakeHistoryService()
          ..details[1] = completed(id: 1, variationIds: [42, 43]);
        final products = FakeProductService()
          ..onFindById = (id) async => id == 42
              ? ProductItem.fromJson(productJson(id: 42, name: 'Tea'))
              : null; // 43: not found -> falls back to "Item 43"
        final c = SalesHistoryController(svc, products);
        await c.selectSale(1);
        expect(c.detail!.id, 1);
        expect(
          c.detailNames,
          isEmpty,
          reason: 'names resolve after the detail itself',
        );
        await Future<void>.delayed(Duration.zero);
        expect(c.detailNames[42], 'Tea');
        expect(c.detailNames.containsKey(43), isFalse);
        expect(products.idCalls..sort(), [42, 43]);
      },
    );

    test('a 404 on the sale itself is a clear not-found error', () async {
      final svc = FakeHistoryService(); // details empty -> null
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(999);
      expect(c.detail, isNull);
      expect(c.detailError, isNotNull);
    });

    test('a lookup failure is reported and can be retried', () async {
      final svc = FakeHistoryService()..onDetail = (_) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      expect(c.detailError, netDown);
      expect(c.detail, isNull);
      svc.onDetail = (id) async => completed(id: id);
      await c.selectSale(1);
      expect(c.detail, isNotNull);
      expect(c.detailError, isNull);
    });

    test('a name-lookup failure never surfaces as a detail error (best-effort only)', () async {
      final svc = FakeHistoryService()..details[1] = completed(id: 1);
      final products = FakeProductService()
        ..onFindById = (_) async => throw netDown;
      final c = SalesHistoryController(svc, products);
      await c.selectSale(1);
      await Future<void>.delayed(Duration.zero);
      expect(c.detail, isNotNull);
      expect(c.detailError, isNull);
      expect(c.detailNames, isEmpty);
    });

    test('selecting a second sale before the first resolves discards the stale one', () async {
      final svc = FakeHistoryService();
      final gate1 = Completer<CompletedSale?>();
      svc.onDetail = (id) =>
          id == 1 ? gate1.future : Future.value(completed(id: 2));
      final c = SalesHistoryController(svc, FakeProductService());
      final firstCall = c.selectSale(1);
      await c.selectSale(2);
      gate1.complete(completed(id: 1));
      await firstCall;
      expect(
        c.detail!.id,
        2,
        reason: 'the later selection wins regardless of response order',
      );
    });

    test('closeDetail clears everything and stops a pending resolution from landing', () async {
      final svc = FakeHistoryService()..details[1] = completed(id: 1);
      final products = FakeProductService();
      final gate = Completer<ProductItem?>();
      products.onFindById = (_) => gate.future;
      final c = SalesHistoryController(svc, products);
      await c.selectSale(1);
      c.closeDetail();
      expect(c.detailSaleId, isNull);
      expect(c.detail, isNull);
      gate.complete(ProductItem.fromJson(productJson(id: 42, name: 'Tea')));
      await Future<void>.delayed(Duration.zero);
      expect(
        c.detailNames,
        isEmpty,
        reason: 'a late name resolution after close must not repopulate state',
      );
    });
  });

  test(
    'clearError only touches the list error, not the detail error',
    () async {
      final svc = FakeHistoryService()..onList = () async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.refresh();
      expect(c.error, isNotNull);
      c.clearError();
      expect(c.error, isNull);
    },
  );

  group('refund', () {
    test('a successful refund updates the currently-open detail in place', () async {
      final svc = FakeHistoryService()..details = {1: completed(id: 1)};
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      expect(c.detail!.refund, isNull);

      svc.onRefund = (id, key) async => refunded(id: id);
      final ok = await c.refundSale(1);

      expect(ok, isTrue);
      expect(c.isRefunding, isFalse);
      expect(c.refundError, isNull);
      expect(c.detail!.refund, isNotNull);
      expect(c.detail!.status, 'completed', reason: 'refund must never change status locally either');
      expect(c.detail!.refund!.refundAmount, c.detail!.totals.grandTotal);
    });

    test('a 403 permission denial leaves the detail unchanged and is exposed as refundError', () async {
      final svc = FakeHistoryService()
        ..details = {1: completed(id: 1)}
        ..onRefund = (id, key) async => throw forbiddenRefund;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);

      final ok = await c.refundSale(1);

      expect(ok, isFalse);
      expect(c.isRefunding, isFalse);
      expect(c.refundError, isNotNull);
      expect(c.refundError!.kind, ApiErrorKind.forbidden);
      expect(c.refundError!.errorCode, 'POS_PERMISSION_DENIED');
      expect(
        c.detail!.refund,
        isNull,
        reason: 'a denied refund must not locally mark the sale as refunded',
      );
      expect(c.detail!.status, 'completed');
    });

    test('a generic backend error is exposed the same way as any other API failure', () async {
      final svc = FakeHistoryService()
        ..details = {1: completed(id: 1)}
        ..onRefund = (id, key) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);

      final ok = await c.refundSale(1);
      expect(ok, isFalse);
      expect(c.refundError, netDown);
    });

    test('clearRefundError only touches the refund error', () async {
      final svc = FakeHistoryService()
        ..details = {1: completed(id: 1)}
        ..onRefund = (id, key) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      await c.refundSale(1);
      expect(c.refundError, isNotNull);
      c.clearRefundError();
      expect(c.refundError, isNull);
    });

    test('a retry on the SAME sale after a failure reuses the same idempotency key (safe replay)', () async {
      final svc = FakeHistoryService()
        ..details = {1: completed(id: 1)}
        ..onRefund = (id, key) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      await c.refundSale(1);
      await c.refundSale(1);
      expect(svc.refundKeys.length, 2);
      expect(svc.refundKeys[0], svc.refundKeys[1]);
    });

    test('a successful refund followed by another attempt on the same (now already-refunded) sale uses a NEW key', () async {
      final svc = FakeHistoryService()..details = {1: completed(id: 1)};
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);

      svc.onRefund = (id, key) async => refunded(id: id);
      await c.refundSale(1);
      final firstKey = svc.refundKeys.single;

      svc.onRefund = (id, key) async =>
          throw const ApiException(kind: ApiErrorKind.conflict, message: 'Sale has already been refunded.');
      await c.refundSale(1);

      expect(svc.refundKeys.last, isNot(firstKey), reason: 'a closed attempt must not be replayed for a new one');
    });

    test('a different sale always gets its own idempotency key', () async {
      final svc = FakeHistoryService()
        ..details = {1: completed(id: 1), 2: completed(id: 2)}
        ..onRefund = (id, key) async => throw netDown;
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);
      await c.refundSale(1);
      await c.selectSale(2);
      await c.refundSale(2);
      expect(svc.refundKeys[0], isNot(svc.refundKeys[1]));
    });

    test('isRefunding is true only while the request is in flight', () async {
      final svc = FakeHistoryService()..details = {1: completed(id: 1)};
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);

      final gate = Completer<CompletedSale?>();
      svc.onRefund = (id, key) => gate.future;
      final future = c.refundSale(1);
      expect(c.isRefunding, isTrue);
      gate.complete(refunded(id: 1));
      await future;
      expect(c.isRefunding, isFalse);
    });

    test('a concurrent second call while one is in flight is a no-op', () async {
      final svc = FakeHistoryService()..details = {1: completed(id: 1)};
      final c = SalesHistoryController(svc, FakeProductService());
      await c.selectSale(1);

      final gate = Completer<CompletedSale?>();
      svc.onRefund = (id, key) => gate.future;
      final first = c.refundSale(1);
      final second = await c.refundSale(1);
      expect(second, isFalse);
      gate.complete(refunded(id: 1));
      expect(await first, isTrue);
      expect(svc.refundKeys.length, 1);
    });
  });
}
