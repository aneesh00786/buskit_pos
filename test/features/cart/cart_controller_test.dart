import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

void main() {
  late FakeCartService service;
  late CartController cart;
  var unauthorized = 0;

  setUp(() {
    service = FakeCartService();
    unauthorized = 0;
    cart = CartController(service, onUnauthorized: () => unauthorized++);
  });
  tearDown(() => cart.dispose());

  test(
    'first add creates one draft sale then adds with the sale version',
    () async {
      expect(await cart.addItem(42, 2), isTrue);
      expect(service.createCalls, 1);
      expect(service.addCalls.single.variationId, 42);
      expect(service.addCalls.single.quantity, 2);
      expect(service.addCalls.single.saleId, 7);
      expect(service.addCalls.single.expectedVersion, 1);
      expect(cart.sale!.version, 2);
    },
  );

  test('later adds reuse the sale and chain the returned version', () async {
    await cart.addItem(1, 1);
    await cart.addItem(2, 1);
    await cart.addItem(3, 5);
    expect(service.createCalls, 1);
    expect(service.addCalls.map((c) => c.expectedVersion), [1, 2, 3]);
    expect(service.addCalls.map((c) => c.variationId), [1, 2, 3]);
  });

  group('duplicate prevention', () {
    test('a double-tap while an add is in flight sends one request', () async {
      final gate = Completer<CartSale>();
      service.onAdd = (_) => gate.future;
      final a = cart.addItem(42, 1);
      final b = cart.addItem(42, 1);
      final c = cart.addItem(42, 1);
      expect(cart.isAdding, isTrue);
      gate.complete(CartSale.fromJson(saleJson(version: 2))!);
      expect(await Future.wait([a, b, c]), [true, false, false]);
      expect(service.addCalls, hasLength(1));
    });

    test('a different item tapped during an in-flight add is ignored, not raced on the version', () async {
      final gate = Completer<CartSale>();
      service.onAdd = (_) => gate.future;
      final a = cart.addItem(1, 1);
      final b = cart.addItem(2, 1);
      gate.complete(CartSale.fromJson(saleJson(version: 2))!);
      expect(await b, isFalse);
      await a;
      expect(service.addCalls.map((c) => c.variationId), [1]);
    });

    test('two adds racing on an empty cart open exactly one sale', () async {
      final gate = Completer<CartSale>();
      service.onCreate = () => gate.future;
      final a = cart.addItem(1, 1);
      final b = cart.addItem(2, 1);
      gate.complete(CartSale.fromJson(saleJson())!);
      await Future.wait([a, b]);
      expect(service.createCalls, 1);
    });

    test('adding is possible again after the request finishes (also after a failure)', () async {
      service.onAdd = (_) async => throw apiError(500);
      expect(await cart.addItem(1, 1), isFalse);
      expect(cart.isAdding, isFalse);
      service.onAdd = (c) async =>
          CartSale.fromJson(saleJson(version: c.expectedVersion + 1))!;
      expect(await cart.addItem(1, 1), isTrue);
    });
  });

  group('errors', () {
    test('POS_WEIGHT_UNIT_NOT_SUPPORTED: kept on the controller, cart unchanged, not retried', () async {
      await cart.addItem(1, 1); // one good item first
      final before = cart.sale!;
      service.onAdd = (_) async => throw apiError(
        422,
        message: 'Weight-based products cannot be sold',
        code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
      );
      final ok = await cart.addItem(6, 1);
      expect(ok, isFalse);
      expect(cart.error!.errorCode, 'POS_WEIGHT_UNIT_NOT_SUPPORTED');
      expect(cart.sale, same(before), reason: 'nothing was added');
      expect(
        service.addCalls,
        hasLength(2),
        reason: 'one good + one rejected, no automatic retry',
      );
      expect(service.getCalls, 0);
    });

    test('a version conflict (409) refreshes the cart and does NOT auto-retry the add', () async {
      await cart.addItem(1, 1);
      service.onAdd = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 5},
      );
      service.onGet = (id) async =>
          CartSale.fromJson(saleJson(id: id, version: 5))!;
      expect(await cart.addItem(2, 1), isFalse);
      expect(cart.error!.kind, ApiErrorKind.conflict);
      expect(service.getCalls, 1);
      expect(cart.sale!.version, 5, reason: 'refreshed to the server version');
      expect(service.addCalls, hasLength(2));
    });

    test(
      'a failed refresh after a conflict keeps the original error',
      () async {
        await cart.addItem(1, 1);
        service.onAdd = (_) async => throw apiError(409, message: 'stale');
        service.onGet = (_) async => throw apiError(500);
        await cart.addItem(2, 1);
        expect(cart.error!.kind, ApiErrorKind.conflict);
      },
    );

    test('401 tells the session to sign out', () async {
      service.onCreate = () async => throw apiError(401);
      await cart.addItem(1, 1);
      expect(unauthorized, 1);
      expect(cart.error!.isUnauthorized, isTrue);
    });

    test(
      'network errors are retryable by the user, not automatically',
      () async {
        service.onCreate = () async => throw const ApiException(
          kind: ApiErrorKind.network,
          message: 'offline',
        );
        expect(await cart.addItem(1, 1), isFalse);
        expect(cart.error!.isRetryable, isTrue);
        expect(service.createCalls, 1);
      },
    );

    test('a shift-required conflict on creation is surfaced', () async {
      service.onCreate = () async => throw apiError(
        409,
        message: 'An open shift is required to start a sale',
      );
      await cart.addItem(1, 1);
      expect(cart.error!.message, contains('open shift'));
      expect(cart.sale, isNull);
    });

    test('clearError removes the error', () async {
      service.onAdd = (_) async => throw apiError(422, message: 'x');
      await cart.addItem(1, 1);
      cart.clearError();
      expect(cart.error, isNull);
    });
  });

  group('client-side guards mirror the backend limits', () {
    test(
      'quantity 0, negative and above 9999 are rejected without a request',
      () async {
        for (final q in [0, -1, 10000]) {
          expect(await cart.addItem(1, q), isFalse, reason: '$q');
          expect(cart.error!.kind, ApiErrorKind.validation);
        }
        expect(service.createCalls, 0);
        expect(service.addCalls, isEmpty);
      },
    );

    test('boundary quantities 1 and 9999 are accepted', () async {
      expect(await cart.addItem(1, 1), isTrue);
      expect(await cart.addItem(1, 9999), isTrue);
    });
  });

  test('a non-draft sale is replaced by a new draft on the next add', () async {
    service.onAdd = (c) async => CartSale.fromJson(
      saleJson(id: c.saleId, version: 9, status: 'completed'),
    )!;
    await cart.addItem(1, 1);
    service.onCreate = () async => CartSale.fromJson(saleJson(id: 8))!;
    service.onAdd = (c) async =>
        CartSale.fromJson(saleJson(id: c.saleId, version: 2))!;
    await cart.addItem(1, 1);
    expect(service.createCalls, 2);
    expect(service.addCalls.last.saleId, 8);
  });

  test('reset forgets the local cart', () async {
    await cart.addItem(1, 1);
    cart.reset();
    expect(cart.sale, isNull);
  });
}
