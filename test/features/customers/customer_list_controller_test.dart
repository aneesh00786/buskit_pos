import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/customers/data/customer_service.dart';
import 'package:buskit_pos/features/customers/models/customer.dart';
import 'package:buskit_pos/features/customers/models/customer_purchase.dart';
import 'package:buskit_pos/features/customers/state/customer_list_controller.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_customer_service.dart';

CustomerPage page(
  List<Map<String, dynamic>> rows, {
  int page = 1,
  int total = -1,
  int limit = 20,
}) {
  final items = rows.map(Customer.fromJson).whereType<Customer>().toList();
  final effectiveTotal = total < 0 ? items.length : total;
  return CustomerPage(
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
  group('list', () {
    test('idle -> loading -> loaded', () async {
      final svc = FakeCustomerService();
      svc.onSearch = (_) async =>
          page([customerJson(id: 1), customerJson(id: 2)]);
      final c = CustomerListController(svc);
      expect(c.status, CustomerListStatus.idle);
      final f = c.loadInitial();
      expect(c.status, CustomerListStatus.loading);
      await f;
      expect(c.status, CustomerListStatus.loaded);
      expect(c.items.length, 2);
    });

    test('no results shows the empty state', () async {
      final c = CustomerListController(FakeCustomerService());
      await c.loadInitial();
      expect(c.status, CustomerListStatus.empty);
    });

    test(
      'a failure with nothing loaded shows the error state; retry can recover',
      () async {
        final svc = FakeCustomerService();
        svc.onSearch = (_) async => throw netDown;
        final c = CustomerListController(svc);
        await c.loadInitial();
        expect(c.status, CustomerListStatus.error);
        svc.onSearch = (_) async => page([customerJson()]);
        await c.retry();
        expect(c.status, CustomerListStatus.loaded);
      },
    );

    test('search is debounced and sent to the service, trimmed', () async {
      final svc = FakeCustomerService();
      final c = CustomerListController(
        svc,
        debounce: const Duration(milliseconds: 20),
      );
      c.onQueryChanged('  jane  ');
      expect(svc.searchCalls, isEmpty, reason: 'debounced, not yet sent');
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(svc.searchCalls.single.query, 'jane');
    });

    test(
      'submitQuery runs immediately, cancelling any pending debounce',
      () async {
        final svc = FakeCustomerService();
        final c = CustomerListController(
          svc,
          debounce: const Duration(milliseconds: 50),
        );
        c.onQueryChanged('x');
        await c.submitQuery('y');
        expect(svc.searchCalls.map((s) => s.query).toList(), ['y']);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        expect(
          svc.searchCalls.length,
          1,
          reason: 'the debounced "x" search must not fire afterwards',
        );
      },
    );

    test(
      'a stale first-page response (superseded by a newer query) is discarded',
      () async {
        final svc = FakeCustomerService();
        final first = Completer<CustomerPage>();
        final calls = <String?>[];
        svc.onSearch = (call) {
          calls.add(call.query);
          return calls.length == 1
              ? first.future
              : Future.value(page([customerJson(fullname: 'Second')]));
        };
        final c = CustomerListController(svc);
        final firstLoad = c.submitQuery('first');
        final secondLoad = c.submitQuery('second');
        first.complete(page([customerJson(fullname: 'First')]));
        await firstLoad;
        await secondLoad;
        expect(c.items.single.fullname, 'Second');
      },
    );

    test('loadNextPage appends new rows, de-duplicated, and stops at the last page', () async {
      final svc = FakeCustomerService();
      svc.onSearch = (call) async => page(
        [for (var i = 1; i <= 20; i++) customerJson(id: i)],
        page: call.page,
        total: 25,
        limit: 20,
      );
      final c = CustomerListController(svc);
      await c.loadInitial();
      expect(c.hasMore, isTrue);
      svc.onSearch = (call) async => page(
        [for (var i = 21; i <= 25; i++) customerJson(id: i)],
        page: call.page,
        total: 25,
        limit: 20,
      );
      await c.loadNextPage();
      expect(c.items.length, 25);
      expect(c.hasMore, isFalse);
      await c.loadNextPage(); // no-op past the last page
      expect(svc.searchCalls.length, 2);
    });

    test('a loadNextPage failure keeps the existing items and is reported separately', () async {
      final svc = FakeCustomerService();
      svc.onSearch = (call) async =>
          page([customerJson(id: 1)], page: 1, total: 2, limit: 1);
      final c = CustomerListController(svc);
      await c.loadInitial();
      svc.onSearch = (_) async => throw netDown;
      await c.loadNextPage();
      expect(c.items.length, 1, reason: 'stale list kept');
      expect(c.loadMoreError, netDown);
    });
  });

  group('detail + purchase history', () {
    test(
      'selectCustomer loads the customer, then its purchase history',
      () async {
        final svc = FakeCustomerService();
        svc.onFindByCustomerId = (_) async =>
            Customer.fromJson(customerJson(customerId: 'CUSTO1'));
        svc.onPurchaseHistory = (_, _) async => CustomerPurchasePage(
          summary: const CustomerPurchaseSummary(
            transactionCount: 3,
            totalPurchases: 100,
          ),
          items: const [],
          pagination: const Pagination(
            page: 1,
            limit: 20,
            total: 0,
            totalPages: 1,
          ),
        );
        final c = CustomerListController(svc);
        await c.selectCustomer('CUSTO1');
        await Future<void>.delayed(Duration.zero);
        expect(c.detail!.customerId, 'CUSTO1');
        expect(c.purchases!.summary.transactionCount, 3);
      },
    );

    test('an unknown customer id is a clear not-found error, and purchases are not fetched', () async {
      final svc = FakeCustomerService();
      svc.onFindByCustomerId = (_) async => null;
      final c = CustomerListController(svc);
      await c.selectCustomer('NOPE');
      expect(c.detail, isNull);
      expect(c.detailError, isNotNull);
      expect(svc.purchaseCalls, isEmpty);
    });

    test('a detail lookup failure is reported and can be retried', () async {
      final svc = FakeCustomerService();
      svc.onFindByCustomerId = (_) async => throw netDown;
      final c = CustomerListController(svc);
      await c.selectCustomer('CUSTO1');
      expect(c.detailError, netDown);
      svc.onFindByCustomerId = (id) async =>
          Customer.fromJson(customerJson(customerId: id));
      await c.selectCustomer('CUSTO1');
      expect(c.detail, isNotNull);
    });

    test(
      'a purchase-history failure does not block the detail from showing',
      () async {
        final svc = FakeCustomerService();
        svc.onFindByCustomerId = (_) async =>
            Customer.fromJson(customerJson(customerId: 'CUSTO1'));
        svc.onPurchaseHistory = (_, _) async => throw netDown;
        final c = CustomerListController(svc);
        await c.selectCustomer('CUSTO1');
        await Future<void>.delayed(Duration.zero);
        expect(c.detail, isNotNull);
        expect(c.purchasesError, netDown);
      },
    );

    test('selecting a second customer before the first resolves discards the stale one', () async {
      final svc = FakeCustomerService();
      final gate1 = Completer<Customer?>();
      svc.onFindByCustomerId = (id) {
        if (id == 'A') return gate1.future;
        return Future.value(Customer.fromJson(customerJson(customerId: 'B')));
      };
      final c = CustomerListController(svc);
      final firstCall = c.selectCustomer('A');
      await c.selectCustomer('B');
      gate1.complete(Customer.fromJson(customerJson(customerId: 'A')));
      await firstCall;
      expect(c.detail!.customerId, 'B');
    });

    test('closeDetail clears state and stops a pending purchase-history fetch from landing', () async {
      final svc = FakeCustomerService();
      svc.onFindByCustomerId = (_) async =>
          Customer.fromJson(customerJson(customerId: 'CUSTO1'));
      final gate = Completer<CustomerPurchasePage>();
      svc.onPurchaseHistory = (_, _) => gate.future;
      final c = CustomerListController(svc);
      await c.selectCustomer('CUSTO1');
      c.closeDetail();
      expect(c.detailCustomerId, isNull);
      gate.complete(
        CustomerPurchasePage(
          summary: const CustomerPurchaseSummary(
            transactionCount: 1,
            totalPurchases: 1,
          ),
          items: const [],
          pagination: const Pagination(
            page: 1,
            limit: 20,
            total: 0,
            totalPages: 1,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        c.purchases,
        isNull,
        reason: 'late response after close must not repopulate state',
      );
    });

    test(
      'loadMorePurchases fetches the next page and is a no-op once exhausted',
      () async {
        final svc = FakeCustomerService();
        svc.onFindByCustomerId = (_) async =>
            Customer.fromJson(customerJson(customerId: 'CUSTO1'));
        svc.onPurchaseHistory = (_, p) async => CustomerPurchasePage(
          summary: const CustomerPurchaseSummary(
            transactionCount: 2,
            totalPurchases: 2,
          ),
          items: [
            CustomerPurchase.fromJson({'id': p})!,
          ],
          pagination: Pagination(page: p, limit: 1, total: 2, totalPages: 2),
        );
        final c = CustomerListController(svc);
        await c.selectCustomer('CUSTO1');
        await Future<void>.delayed(Duration.zero);
        expect(c.purchases!.items.single.id, 1);
        await c.loadMorePurchases();
        expect(svc.purchaseCalls, ['CUSTO1', 'CUSTO1']);
        expect(c.purchases!.items.single.id, 2);
        await c.loadMorePurchases(); // exhausted
        expect(svc.purchaseCalls.length, 2);
      },
    );
  });

  group('create', () {
    test('a successful create prepends the new customer to the list', () async {
      final svc = FakeCustomerService();
      svc.onCreate = (call) async =>
          Customer.fromJson(customerJson(fullname: call.fullname))!;
      final c = CustomerListController(svc);
      final created = await c.createCustomer(
        fullname: 'New Guy',
        mobileno: '0400000000',
      );
      expect(created!.fullname, 'New Guy');
      expect(c.items.first.fullname, 'New Guy');
    });

    test('a duplicate mobile is reported without adding anything', () async {
      final svc = FakeCustomerService();
      svc.onCreate = (_) async => throw duplicateMobileError('CUSTO-EXISTING');
      final c = CustomerListController(svc);
      final result = await c.createCustomer(
        fullname: 'X',
        mobileno: '0400000000',
      );
      expect(result, isNull);
      expect(c.mutationError, isNotNull);
      expect(c.items, isEmpty);
    });

    test(
      'creating the first customer from an empty list flips status to loaded',
      () async {
        final svc = FakeCustomerService();
        svc.onCreate = (call) async =>
            Customer.fromJson(customerJson(fullname: call.fullname))!;
        final c = CustomerListController(svc);
        await c.loadInitial();
        expect(c.status, CustomerListStatus.empty);
        await c.createCustomer(fullname: 'New Guy', mobileno: '0400000000');
        expect(c.status, CustomerListStatus.loaded);
      },
    );

    test('no double-submit while a create is already in flight', () async {
      final svc = FakeCustomerService();
      final gate = Completer<Customer>();
      svc.onCreate = (_) => gate.future;
      final c = CustomerListController(svc);
      final first = c.createCustomer(fullname: 'X', mobileno: '1');
      final second = await c.createCustomer(fullname: 'Y', mobileno: '2');
      expect(
        second,
        isNull,
        reason: 'rejected while another create is in flight',
      );
      gate.complete(Customer.fromJson(customerJson())!);
      await first;
      expect(svc.createCalls.length, 1);
    });
  });

  group('update', () {
    test('omitting email leaves it untouched — the exact sentinel every layer must share', () async {
      final svc = FakeCustomerService();
      svc.onUpdate = (call) async => Customer.fromJson(
        customerJson(
          customerId: call.customerId,
          fullname: call.fullname ?? 'X',
        ),
      )!;
      final c = CustomerListController(svc);
      final ok = await c.updateCustomer('CUSTO1', fullname: 'Renamed');
      expect(ok, isTrue);
      final call = svc.updateCalls.single;
      expect(
        identical(call.email, unsetCustomerField),
        isTrue,
        reason: 'must be the shared sentinel, not a locally-declared lookalike',
      );
    });

    test('explicit email: null is passed through as null, distinct from "not provided"', () async {
      final svc = FakeCustomerService();
      final c = CustomerListController(svc);
      await c.updateCustomer('CUSTO1', email: null);
      expect(svc.updateCalls.single.email, isNull);
    });

    test(
      'updates the matching item in the list and the open detail, if any',
      () async {
        final svc = FakeCustomerService();
        svc.onFindByCustomerId = (id) async => Customer.fromJson(
          customerJson(customerId: id, fullname: 'Old Name'),
        );
        svc.onSearch = (_) async =>
            page([customerJson(customerId: 'CUSTO1', fullname: 'Old Name')]);
        svc.onUpdate = (call) async => Customer.fromJson(
          customerJson(customerId: call.customerId, fullname: call.fullname!),
        )!;
        final c = CustomerListController(svc);
        await c.loadInitial();
        await c.selectCustomer('CUSTO1');
        await c.updateCustomer('CUSTO1', fullname: 'New Name');
        expect(c.items.single.fullname, 'New Name');
        expect(c.detail!.fullname, 'New Name');
      },
    );

    test('a duplicate on update is reported via mutationError', () async {
      final svc = FakeCustomerService();
      svc.onUpdate = (_) async => throw duplicateMobileError('CUSTO-OTHER');
      final c = CustomerListController(svc);
      final ok = await c.updateCustomer('CUSTO1', mobileno: '0400000000');
      expect(ok, isFalse);
      expect(c.mutationError!.errorCode, 'POS_DUPLICATE_MOBILE');
    });

    test('clearMutationError resets it', () async {
      final svc = FakeCustomerService();
      svc.onCreate = (_) async => throw netDown;
      final c = CustomerListController(svc);
      await c.createCustomer(fullname: 'X', mobileno: '1');
      expect(c.mutationError, isNotNull);
      c.clearMutationError();
      expect(c.mutationError, isNull);
    });
  });
}
