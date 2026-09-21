import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

final uuidV4 = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
);

const cash112 = PaymentLine(
  method: TenderMethod.cash,
  amountMilli: 112000,
  tenderedMilli: 120000,
);
const cashExact = PaymentLine(
  method: TenderMethod.cash,
  amountMilli: 112000,
  tenderedMilli: 112000,
);
const card112 = PaymentLine(
  method: TenderMethod.card,
  amountMilli: 112000,
  reference: 'AUTH',
);

CartSale draft({
  int version = 2,
  List<Map<String, dynamic>>? items,
  String status = 'draft',
  String? customer,
}) {
  final j = saleJson(
    id: 7,
    version: version,
    status: status,
    items:
        items ??
        [
          lineJson(id: 1, quantity: 2, name: 'Tea'),
          lineJson(id: 2, variationId: 43, name: 'Salt'),
        ],
    subtotal: 100,
    tax: 12,
    total: 112,
  );
  j['customer_id'] = customer;
  return CartSale.fromJson(j)!;
}

void main() {
  late FakeCartService service;
  late CartController cart;
  var unauthorized = 0;
  var listChanged = 0;

  Future<void> seed({List<Map<String, dynamic>>? items}) async {
    service.onAdd = (_) async => draft(items: items);
    service.onGet = (id) async => draft(items: items);
    expect(await cart.addItem(42, 2), isTrue);
    service.callLog.clear();
  }

  setUp(() {
    service = FakeCartService();
    unauthorized = 0;
    listChanged = 0;
    cart = CartController(
      service,
      onUnauthorized: () => unauthorized++,
      onHeldSalesChanged: () => listChanged++,
    );
  });
  tearDown(() => cart.dispose());

  group('completing a sale', () {
    test('sends sale id, current version, a UUID v4 key and the payments; the cart clears; the result is kept', () async {
      await seed();
      service.onComplete = (c) async => CompletedSale.fromJson(
        completedJson(id: c.saleId, payments: c.payments),
      )!;
      expect(await cart.completeSale(const [cash112]), isTrue);

      final c = service.completeCalls.single;
      expect((c.saleId, c.expectedVersion), (7, 2));
      expect(c.key, matches(uuidV4));
      expect(c.payments.single.tenderedMilli, 120000);

      expect(
        cart.sale,
        isNull,
        reason: 'the sale is done: an empty cart is ready for the next sale',
      );
      expect(cart.completedSale!.displayNumber, 'POS-00000007');
      expect(cart.completedSale!.changeDue, 8);
      expect(cart.error, isNull);
      expect(cart.isMutating, isFalse);
      expect(
        cart.hasPendingCompletion,
        isFalse,
        reason: 'the key is retired after success',
      );
    });

    test('product names from the cart are kept for the receipt (the completed view has none)', () async {
      await seed();
      await cart.completeSale(const [cashExact]);
      expect(cart.completedNames, {1: 'Tea', 2: 'Salt'});
    });

    test('acknowledgeCompletion forgets the finished sale', () async {
      await seed();
      await cart.completeSale(const [cashExact]);
      cart.acknowledgeCompletion();
      expect(cart.completedSale, isNull);
      expect(cart.completedNames, isEmpty);
    });

    test(
      'the next sale after completing starts a NEW draft with a NEW key',
      () async {
        await seed();
        await cart.completeSale(const [cashExact]);
        final first = service.completeCalls.single.key;
        service.onCreate = () async => CartSale.fromJson(saleJson(id: 8))!;
        service.onAdd = (c) async => CartSale.fromJson(
          saleJson(
            id: c.saleId,
            version: 2,
            items: [lineJson(id: 5)],
            total: 112,
          ),
        )!;
        await cart.addItem(1, 1);
        await cart.completeSale(const [cashExact]);
        expect(service.createCalls, 2);
        expect(service.completeCalls.last.saleId, 8);
        expect(service.completeCalls.last.key, isNot(first));
      },
    );

    test('nothing to pay: no request (no cart, empty draft, non-draft, no payments)', () async {
      expect(await cart.completeSale(const [cashExact]), isFalse);
      expect(cart.error!.message, CartController.emptyCompleteMessage);
      service.onAdd = (_) async => draft(items: []);
      await cart.addItem(1, 1);
      expect(await cart.completeSale(const [cashExact]), isFalse);
      cart.reset();
      service.onAdd = (_) async => draft(status: 'held');
      await cart.addItem(1, 1);
      expect(await cart.completeSale(const [cashExact]), isFalse);
      cart.reset();
      await seed();
      expect(await cart.completeSale(const []), isFalse);
      expect(service.completeCalls, isEmpty);
    });
  });

  group('idempotency key', () {
    test('a network failure keeps the key: the retry sends the SAME key, and succeeds once', () async {
      await seed();
      service.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'Cannot reach the server.',
      );
      expect(await cart.completeSale(const [cash112]), isFalse);
      final key = service.completeCalls.single.key;
      expect(cart.hasPendingCompletion, isTrue);
      expect(cart.currentIdempotencyKey, key);
      expect(cart.error!.isRetryable, isTrue);
      expect(
        cart.sale,
        isNotNull,
        reason: 'the sale stays open: the outcome is unknown',
      );

      service.onComplete = (c) async =>
          CompletedSale.fromJson(completedJson(payments: c.payments))!;
      expect(await cart.completeSale(const [cash112]), isTrue);
      expect(service.completeCalls, hasLength(2));
      expect(
        service.completeCalls.last.key,
        key,
        reason: 'never a new UUID for the same request',
      );
      expect(
        service.completeCalls.last.expectedVersion,
        service.completeCalls.first.expectedVersion,
      );
    });

    test('timeouts and 5xx keep the key across repeated retries', () async {
      await seed();
      final failures = [
        const ApiException(kind: ApiErrorKind.timeout, message: 'slow'),
        apiError(500, message: 'internal'),
        const ApiException(kind: ApiErrorKind.network, message: 'offline'),
      ];
      var i = 0;
      service.onComplete = (_) async => throw failures[i++];
      for (var n = 0; n < 3; n++) {
        expect(await cart.completeSale(const [cash112]), isFalse);
      }
      final keys = service.completeCalls.map((c) => c.key).toSet();
      expect(keys, hasLength(1), reason: 'one attempt, one key');
      expect(service.completeCalls, hasLength(3));
    });

    test('a definitive rejection (e.g. 422) also keeps the key for the same request — nothing was recorded, so reuse is safe', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        422,
        message: 'Payment total (100) must equal the sale total (112)',
      );
      await cart.completeSale(const [cash112]);
      final key = service.completeCalls.single.key;
      await cart.completeSale(const [cash112]);
      expect(service.completeCalls.last.key, key);
    });

    test('a DIFFERENT payment set gets a NEW key (the server rejects a reused key with a different request)', () async {
      await seed();
      service.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await cart.completeSale(const [cash112]);
      await cart.completeSale(const [card112]);
      expect(service.completeCalls.map((c) => c.key).toSet(), hasLength(2));
    });

    test('changing only the tendered amount is a different request', () async {
      await seed();
      service.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await cart.completeSale(const [cash112]);
      await cart.completeSale(const [cashExact]);
      expect(service.completeCalls.map((c) => c.key).toSet(), hasLength(2));
    });

    test(
      'the same payments in a different order are the same request (same key)',
      () async {
        await seed();
        const a = PaymentLine(
          method: TenderMethod.cash,
          amountMilli: 50000,
          tenderedMilli: 50000,
        );
        const b = PaymentLine(method: TenderMethod.card, amountMilli: 62000);
        service.onComplete = (_) async => throw const ApiException(
          kind: ApiErrorKind.network,
          message: 'offline',
        );
        await cart.completeSale(const [a, b]);
        await cart.completeSale(const [b, a]);
        expect(service.completeCalls.map((c) => c.key).toSet(), hasLength(1));
      },
    );

    test('after the sale changed (version moved), the retry is a new request with a new key', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 6},
      );
      service.onGet = (id) async => draft(version: 6);
      await cart.completeSale(const [cash112]);
      final first = service.completeCalls.single;
      service.onComplete = (c) async =>
          CompletedSale.fromJson(completedJson(payments: c.payments))!;
      await cart.completeSale(const [cash112]);
      final second = service.completeCalls.last;
      expect(second.expectedVersion, 6);
      expect(second.key, isNot(first.key));
    });

    test('no automatic retry: one call per explicit attempt', () async {
      await seed();
      service.onComplete = (_) async =>
          throw const ApiException(kind: ApiErrorKind.timeout, message: 'slow');
      await cart.completeSale(const [cash112]);
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(service.completeCalls, hasLength(1));
    });

    test('reset / void clear the pending key', () async {
      await seed();
      service.onComplete = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await cart.completeSale(const [cash112]);
      expect(cart.hasPendingCompletion, isTrue);
      cart.reset();
      expect(cart.hasPendingCompletion, isFalse);
    });
  });

  group('completion failures', () {
    test(
      'double-tapping Complete sends ONE request and completes once',
      () async {
        await seed();
        final gate = Completer<CompletedSale>();
        service.onComplete = (_) => gate.future;
        final a = cart.completeSale(const [cash112]);
        final b = cart.completeSale(const [cash112]);
        final c = cart.completeSale(const [cash112]);
        expect(cart.operation, CartOperation.complete);
        gate.complete(CompletedSale.fromJson(completedJson())!);
        expect(await Future.wait([a, b, c]), [true, false, false]);
        expect(service.completeCalls, hasLength(1));
      },
    );

    test('every other cart action is ignored while paying', () async {
      await seed();
      final gate = Completer<CompletedSale>();
      service.onComplete = (_) => gate.future;
      final a = cart.completeSale(const [cash112]);
      expect(await cart.addItem(9, 1), isFalse);
      expect(await cart.updateQuantity(1, 5), isFalse);
      expect(await cart.removeItem(1), isFalse);
      expect(await cart.holdCurrent(), isFalse);
      expect(await cart.cancelCurrent(), isFalse);
      expect(await cart.clearAll(), isFalse);
      gate.complete(CompletedSale.fromJson(completedJson())!);
      await a;
      expect(service.updateCalls, isEmpty);
      expect(service.holdCalls, isEmpty);
      expect(service.cancelCalls, isEmpty);
    });

    test('version conflict: cart reloaded, current_version kept, review message, NOT retried', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 9, 'current_status': 'draft'},
      );
      service.onGet = (id) async =>
          draft(version: 9, items: [lineJson(id: 1, quantity: 5, name: 'Tea')]);
      expect(await cart.completeSale(const [cash112]), isFalse);
      expect(service.completeCalls, hasLength(1));
      expect(cart.error!.currentVersion, 9);
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.errorOperation, CartOperation.complete);
      expect(cart.sale!.version, 9);
      expect(cart.sale!.items.single.quantity, 5);
    });

    test('POS_INSUFFICIENT_STOCK keeps its code and shortages; the cart is unchanged; not retryable', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        409,
        message: 'Insufficient stock for one or more items',
        code: 'POS_INSUFFICIENT_STOCK',
        data: {
          'shortages': [
            {
              'item_id': 1,
              'product_variation_id': 42,
              'requested': 2,
              'available': 1,
            },
          ],
        },
      );
      expect(await cart.completeSale(const [cash112]), isFalse);
      expect(cart.error!.errorCode, 'POS_INSUFFICIENT_STOCK');
      expect(cart.error!.dataMap!['shortages'], hasLength(1));
      expect(cart.error!.isRetryable, isFalse);
      expect(cart.sale, isNotNull);
    });

    test('POS_WEIGHT_UNIT_NOT_SUPPORTED keeps its code and item ids', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        422,
        message: 'Weight-based products',
        code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        data: {
          'weight_unit_item_ids': [2],
        },
      );
      await cart.completeSale(const [cash112]);
      expect(cart.error!.errorCode, 'POS_WEIGHT_UNIT_NOT_SUPPORTED');
      expect(cart.error!.dataMap!['weight_unit_item_ids'], [2]);
    });

    test('a payment-total mismatch (422) keeps the server wording', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        422,
        message: 'Payment total (100) must equal the sale total (112)',
      );
      await cart.completeSale(const [cash112]);
      expect(cart.error!.message, contains('must equal the sale total'));
      expect(cart.error!.kind, ApiErrorKind.validation);
    });

    test('"Sale already completed" (409) is reported and the cart is reloaded read-only', () async {
      await seed();
      service.onComplete = (_) async =>
          throw apiError(409, message: 'Sale already completed');
      service.onGet = (id) async => draft(version: 8, status: 'completed');
      await cart.completeSale(const [cash112]);
      expect(cart.error!.message, 'Sale already completed');
      expect(cart.sale!.isDraft, isFalse);
    });

    test(
      '403 different shift is reported, not retryable, cart untouched',
      () async {
        await seed();
        service.onComplete = (_) async => throw apiError(
          403,
          message: 'This sale belongs to a different shift',
        );
        await cart.completeSale(const [cash112]);
        expect(cart.error!.kind, ApiErrorKind.forbidden);
        expect(cart.error!.isRetryable, isFalse);
        expect(service.getCalls, 0);
      },
    );

    test('401 signs the session out once', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(401);
      await cart.completeSale(const [cash112]);
      expect(unauthorized, 1);
    });

    test('a 5xx never leaks server text', () async {
      await seed();
      service.onComplete = (_) async => throw apiError(
        500,
        message: 'ER_LOCK_DEADLOCK at posSaleService.js:250',
      );
      await cart.completeSale(const [cash112]);
      expect(cart.error!.message, isNot(contains('ER_LOCK')));
    });
  });

  group('customer (guest / ID before the sale starts)', () {
    test(
      'the default is guest checkout: the sale is created without a customer',
      () async {
        await seed();
        expect(service.createCustomerIds, [null]);
        expect(cart.customerId, isNull);
      },
    );

    test('a customer chosen before the first item is sent when the sale is created', () async {
      expect(cart.canChooseCustomer, isTrue);
      expect(cart.setPendingCustomer('  C-42 '), isTrue);
      expect(cart.pendingCustomerId, 'C-42');
      expect(cart.customerId, 'C-42');
      service.onAdd = (_) async => draft(customer: 'C-42');
      await cart.addItem(1, 1);
      expect(service.createCustomerIds, ['C-42']);
      expect(cart.customerId, 'C-42', reason: 'now read from the server sale');
    });

    test('once a sale exists the customer can no longer be changed', () async {
      await seed();
      expect(cart.canChooseCustomer, isFalse);
      expect(cart.setPendingCustomer('C-9'), isFalse);
      expect(cart.pendingCustomerId, isNull);
    });

    test('blank input means guest', () async {
      cart.setPendingCustomer('C-1');
      cart.setPendingCustomer('   ');
      expect(cart.pendingCustomerId, isNull);
    });

    test('an unknown customer (404 on create) is reported and the choice stays editable', () async {
      cart.setPendingCustomer('NOPE');
      service.onCreate = () async =>
          throw apiError(404, message: 'Customer not found');
      expect(await cart.addItem(1, 1), isFalse);
      expect(cart.error!.message, 'Customer not found');
      expect(cart.sale, isNull);
      expect(cart.canChooseCustomer, isTrue);
      expect(cart.setPendingCustomer(null), isTrue);
    });

    test('the customer is forgotten after completing, voiding or holding (the next sale is guest again)', () async {
      cart.setPendingCustomer('C-1');
      service.onAdd = (_) async => draft(customer: 'C-1');
      await cart.addItem(1, 1);
      await cart.completeSale(const [cashExact]);
      expect(cart.pendingCustomerId, isNull);

      cart.setPendingCustomer('C-2');
      service.onAdd = (_) async => draft(customer: 'C-2');
      await cart.addItem(1, 1);
      await cart.cancelCurrent();
      expect(cart.pendingCustomerId, isNull);

      cart.setPendingCustomer('C-3');
      await cart.addItem(1, 1);
      await cart.holdCurrent();
      expect(cart.pendingCustomerId, isNull);
    });

    test(
      'the customer cannot be changed while a request is in flight',
      () async {
        final gate = Completer<CartSale>();
        service.onAdd = (_) => gate.future;
        final f = cart.addItem(1, 1);
        expect(cart.setPendingCustomer('C-1'), isFalse);
        gate.complete(draft());
        await f;
      },
    );
  });

  group('voiding (cancel) the open sale', () {
    test('sends the id and version; success clears the cart and remembers the voided id', () async {
      await seed();
      expect(await cart.cancelCurrent(), isTrue);
      final c = service.cancelCalls.single;
      expect((c.saleId, c.expectedVersion), (7, 2));
      expect(cart.sale, isNull);
      expect(cart.lastCancelledSaleId, 7);
      expect(cart.error, isNull);
    });

    test('no sale, or a non-draft sale: no request', () async {
      expect(await cart.cancelCurrent(), isFalse);
      service.onAdd = (_) async => draft(status: 'completed');
      await cart.addItem(1, 1);
      expect(await cart.cancelCurrent(), isFalse);
      expect(service.cancelCalls, isEmpty);
    });

    test('double-tap sends one request', () async {
      await seed();
      final gate = Completer<CartSale>();
      service.onCancel = (_) => gate.future;
      final a = cart.cancelCurrent();
      final b = cart.cancelCurrent();
      gate.complete(draft(version: 3, status: 'canceled'));
      expect(await Future.wait([a, b]), [true, false]);
      expect(service.cancelCalls, hasLength(1));
    });

    test('version conflict: reloaded, message + current_version kept, cart kept, no retry', () async {
      await seed();
      service.onCancel = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 5},
      );
      service.onGet = (id) async => draft(version: 5);
      expect(await cart.cancelCurrent(), isFalse);
      expect(service.cancelCalls, hasLength(1));
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.error!.currentVersion, 5);
      expect(cart.sale!.version, 5);
    });

    test('already completed/canceled (409 without data): clear message and refreshed read-only cart', () async {
      await seed();
      service.onCancel = (_) async => throw apiError(
        409,
        message: 'Sale cannot be canceled from its current status: completed',
      );
      service.onGet = (id) async => draft(version: 9, status: 'completed');
      await cart.cancelCurrent();
      expect(cart.error!.message, CartController.cancelNotAllowedMessage);
      expect(cart.sale!.isDraft, isFalse);
    });

    test('404, 403, network, 401', () async {
      await seed();
      service.onCancel = (_) async =>
          throw apiError(404, message: 'Sale not found');
      await cart.cancelCurrent();
      expect(cart.error!.message, CartController.cancelGoneMessage);
      service.onCancel = (_) async => throw apiError(
        403,
        message: 'This sale belongs to a different shift',
      );
      await cart.cancelCurrent();
      expect(cart.error!.kind, ApiErrorKind.forbidden);
      service.onCancel = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await cart.cancelCurrent();
      expect(cart.error!.isRetryable, isTrue);
      service.onCancel = (_) async => throw apiError(401);
      await cart.cancelCurrent();
      expect(unauthorized, 1);
      expect(
        cart.sale,
        isNotNull,
        reason: 'nothing was voided by any of those failures',
      );
    });
  });

  group('voiding a HELD sale', () {
    test('sends the given id and version; the open cart is untouched; the list refreshes', () async {
      await seed();
      expect(await cart.cancelHeldSale(saleId: 12, expectedVersion: 4), isTrue);
      final c = service.cancelCalls.single;
      expect((c.saleId, c.expectedVersion), (12, 4));
      expect(
        cart.sale!.id,
        7,
        reason: 'the active cart is not the sale that was voided',
      );
      expect(cart.lastCancelledSaleId, 12);
      expect(listChanged, 1);
    });

    test('a conflict or a vanished sale marks the list stale (refresh) and keeps the cart', () async {
      await seed();
      service.onCancel = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 6},
      );
      await cart.cancelHeldSale(saleId: 12, expectedVersion: 4);
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.errorOperation, CartOperation.cancelHeld);
      expect(listChanged, 1);
      service.onCancel = (_) async =>
          throw apiError(404, message: 'Sale not found');
      await cart.cancelHeldSale(saleId: 12, expectedVersion: 4);
      expect(cart.error!.message, CartController.cancelGoneMessage);
      expect(listChanged, 2);
      expect(cart.sale!.id, 7);
    });

    test(
      '403 (a different store) is reported and does not refresh the list',
      () async {
        service.onCancel = (_) async => throw apiError(
          403,
          message: 'This sale belongs to a different store',
        );
        await cart.cancelHeldSale(saleId: 12, expectedVersion: 4);
        expect(cart.error!.kind, ApiErrorKind.forbidden);
        expect(listChanged, 0);
      },
    );
  });
}
