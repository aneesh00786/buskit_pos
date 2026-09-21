import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

CartSale sale({
  int version = 2,
  int id = 7,
  String status = 'draft',
  List<Map<String, dynamic>>? items,
}) => CartSale.fromJson(
  saleJson(
    id: id,
    version: version,
    status: status,
    items:
        items ??
        [
          lineJson(id: 1, variationId: 42, quantity: 2, name: 'Tea'),
          lineJson(id: 2, variationId: 43, quantity: 1, name: 'Salt'),
        ],
  ),
)!;

void main() {
  late FakeCartService service;
  late CartController cart;
  var unauthorized = 0;

  /// A cart that already contains lines 1 (qty 2) and 2 (qty 1) at version 2.
  Future<void> seed() async {
    service.onAdd = (_) async => sale(version: 2);
    service.onGet = (id) async => sale(version: 2, id: id);
    expect(await cart.addItem(42, 2), isTrue);
    service.addCalls.clear();
  }

  setUp(() {
    service = FakeCartService();
    unauthorized = 0;
    cart = CartController(service, onUnauthorized: () => unauthorized++);
  });
  tearDown(() => cart.dispose());

  group('update quantity', () {
    test('sends the LINE id, the new quantity and the current version, then applies the refreshed sale', () async {
      await seed();
      service.onUpdate = (c) async => sale(
        version: 3,
        items: [
          lineJson(id: 1, quantity: c.quantity),
          lineJson(id: 2),
        ],
      );
      expect(await cart.updateQuantity(1, 5), isTrue);
      final c = service.updateCalls.single;
      expect((c.saleId, c.itemId, c.quantity, c.expectedVersion), (7, 1, 5, 2));
      expect(cart.sale!.version, 3);
      expect(cart.sale!.items.first.quantity, 5);
      expect(cart.error, isNull);
      expect(cart.isMutating, isFalse);
    });

    test('versions chain across consecutive updates', () async {
      await seed();
      var v = 2;
      service.onUpdate = (c) async => sale(
        version: ++v,
        items: [
          lineJson(id: 1, quantity: c.quantity),
          lineJson(id: 2),
        ],
      );
      await cart.updateQuantity(1, 3);
      await cart.updateQuantity(1, 4);
      await cart.updateQuantity(1, 5);
      expect(service.updateCalls.map((c) => c.expectedVersion), [2, 3, 4]);
    });

    test('an unchanged quantity succeeds without a request', () async {
      await seed();
      expect(await cart.updateQuantity(1, 2), isTrue);
      expect(service.updateCalls, isEmpty);
    });

    test('quantities 0, negative and above 9999 are rejected locally; boundaries 1 and 9999 are sent', () async {
      await seed();
      for (final q in [0, -3, 10000]) {
        expect(await cart.updateQuantity(1, q), isFalse, reason: '$q');
        expect(cart.error!.kind, ApiErrorKind.validation);
        expect(cart.errorOperation, CartOperation.update);
      }
      expect(service.updateCalls, isEmpty);
      var v = 2;
      service.onUpdate = (c) async => sale(
        version: ++v,
        items: [
          lineJson(id: 1, quantity: c.quantity),
          lineJson(id: 2),
        ],
      );
      expect(await cart.updateQuantity(1, 9999), isTrue);
      expect(await cart.updateQuantity(1, 1), isTrue);
      expect(service.updateCalls.map((c) => c.quantity), [9999, 1]);
    });

    test('an unknown line id does nothing', () async {
      await seed();
      expect(await cart.updateQuantity(999, 3), isFalse);
      expect(service.updateCalls, isEmpty);
      expect(cart.error, isNull);
    });

    test('no cart yet: nothing is sent', () async {
      expect(await cart.updateQuantity(1, 3), isFalse);
      expect(service.updateCalls, isEmpty);
    });

    test('a non-draft sale cannot be edited (no request)', () async {
      service.onAdd = (_) async => sale(status: 'held');
      await cart.addItem(42, 1);
      expect(await cart.updateQuantity(1, 3), isFalse);
      expect(await cart.removeItem(1), isFalse);
      expect(service.updateCalls, isEmpty);
      expect(service.removeCalls, isEmpty);
    });
  });

  group('remove', () {
    test(
      'sends the LINE id and current version, then applies the refreshed sale',
      () async {
        await seed();
        service.onRemove = (c) async =>
            sale(version: 3, items: [lineJson(id: 2)]);
        expect(await cart.removeItem(1), isTrue);
        final c = service.removeCalls.single;
        expect((c.saleId, c.itemId, c.expectedVersion), (7, 1, 2));
        expect(cart.sale!.items.map((l) => l.id), [2]);
        expect(cart.sale!.version, 3);
      },
    );

    test('removing the last line leaves an empty draft', () async {
      await seed();
      service.onRemove = (c) async => sale(version: 3, items: []);
      await cart.removeItem(1);
      expect(cart.sale!.items, isEmpty);
      expect(cart.sale!.isDraft, isTrue);
    });

    test('an unknown line id does nothing', () async {
      await seed();
      expect(await cart.removeItem(999), isFalse);
      expect(service.removeCalls, isEmpty);
    });
  });

  group('duplicate prevention', () {
    test('double-tapping + on the same line sends ONE update', () async {
      await seed();
      final gate = Completer<CartSale>();
      service.onUpdate = (_) => gate.future;
      final a = cart.updateQuantity(1, 3);
      final b = cart.updateQuantity(1, 3);
      final c = cart.updateQuantity(1, 3);
      expect(cart.isMutating, isTrue);
      expect(cart.mutatingItemId, 1);
      gate.complete(
        sale(
          version: 3,
          items: [lineJson(id: 1, quantity: 3), lineJson(id: 2)],
        ),
      );
      expect(await Future.wait([a, b, c]), [true, false, false]);
      expect(service.updateCalls, hasLength(1));
    });

    test('double-tapping remove sends ONE delete', () async {
      await seed();
      final gate = Completer<CartSale>();
      service.onRemove = (_) => gate.future;
      final a = cart.removeItem(1);
      final b = cart.removeItem(1);
      gate.complete(sale(version: 3, items: [lineJson(id: 2)]));
      expect(await Future.wait([a, b]), [true, false]);
      expect(service.removeCalls, hasLength(1));
    });

    test('a different line, an add, or a remove during an in-flight update is ignored (single version token)', () async {
      await seed();
      final gate = Completer<CartSale>();
      service.onUpdate = (_) => gate.future;
      final a = cart.updateQuantity(1, 3);
      expect(await cart.updateQuantity(2, 4), isFalse);
      expect(await cart.removeItem(2), isFalse);
      expect(await cart.addItem(50, 1), isFalse);
      gate.complete(
        sale(
          version: 3,
          items: [lineJson(id: 1, quantity: 3), lineJson(id: 2)],
        ),
      );
      await a;
      expect(service.updateCalls, hasLength(1));
      expect(service.removeCalls, isEmpty);
      expect(service.addCalls, isEmpty);
    });

    test('controls are usable again after success and after failure', () async {
      await seed();
      service.onUpdate = (_) async => throw apiError(500);
      expect(await cart.updateQuantity(1, 3), isFalse);
      expect(cart.isMutating, isFalse);
      service.onUpdate = (c) async => sale(
        version: 3,
        items: [
          lineJson(id: 1, quantity: c.quantity),
          lineJson(id: 2),
        ],
      );
      expect(await cart.updateQuantity(1, 3), isTrue);
    });
  });

  group('version conflicts', () {
    test('409 on update: refresh from the server, keep code+data, tell the cashier, DO NOT retry', () async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 5, 'current_status': 'draft'},
      );
      service.onGet = (id) async => sale(
        version: 5,
        id: id,
        items: [lineJson(id: 1, quantity: 9), lineJson(id: 2)],
      );
      expect(await cart.updateQuantity(1, 3), isFalse);

      expect(
        service.updateCalls,
        hasLength(1),
        reason: 'never silently retried',
      );
      expect(service.getCalls, 1);
      expect(cart.sale!.version, 5);
      expect(
        cart.sale!.items.first.quantity,
        9,
        reason: 'shows the server state the cashier must review',
      );
      expect(cart.error!.kind, ApiErrorKind.conflict);
      expect(cart.error!.currentVersion, 5);
      expect(cart.error!.dataMap!['current_status'], 'draft');
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.errorOperation, CartOperation.update);
    });

    test(
      'the next attempt after a conflict uses the refreshed version',
      () async {
        await seed();
        service.onUpdate = (_) async =>
            throw apiError(409, data: {'current_version': 5});
        service.onGet = (id) async => sale(version: 5, id: id);
        await cart.updateQuantity(1, 3);
        service.onUpdate = (c) async => sale(
          version: 6,
          items: [
            lineJson(id: 1, quantity: c.quantity),
            lineJson(id: 2),
          ],
        );
        await cart.updateQuantity(1, 3);
        expect(service.updateCalls.last.expectedVersion, 5);
      },
    );

    test(
      '409 on remove refreshes and keeps the line if it still exists',
      () async {
        await seed();
        service.onRemove = (_) async =>
            throw apiError(409, data: {'current_version': 4});
        service.onGet = (id) async => sale(version: 4, id: id);
        expect(await cart.removeItem(1), isFalse);
        expect(service.removeCalls, hasLength(1));
        expect(cart.sale!.items.map((l) => l.id), [1, 2]);
        expect(cart.error!.message, CartController.conflictMessage);
      },
    );

    test('409 "Sale is not a draft": refreshed, message kept, and the cart becomes read-only', () async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        409,
        message: 'Sale is not a draft (current status: completed)',
      );
      service.onGet = (id) async =>
          sale(version: 9, id: id, status: 'completed');
      await cart.updateQuantity(1, 3);
      expect(cart.error!.message, contains('not a draft'));
      expect(cart.sale!.isDraft, isFalse);
      expect(await cart.updateQuantity(1, 4), isFalse);
      expect(service.updateCalls, hasLength(1));
    });

    test('a failed refresh after a conflict keeps the conflict message and the old cart', () async {
      await seed();
      service.onUpdate = (_) async =>
          throw apiError(409, data: {'current_version': 5});
      service.onGet = (_) async => throw apiError(500);
      await cart.updateQuantity(1, 3);
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.sale!.version, 2);
    });

    test('remove of an already-removed line (404): refreshed, friendly message, no retry', () async {
      await seed();
      service.onRemove = (_) async =>
          throw apiError(404, message: 'Line item not found');
      service.onGet = (id) async =>
          sale(version: 3, id: id, items: [lineJson(id: 2)]);
      expect(await cart.removeItem(1), isFalse);
      expect(service.removeCalls, hasLength(1));
      expect(cart.sale!.items.map((l) => l.id), [2]);
      expect(cart.error!.kind, ApiErrorKind.notFound);
      expect(cart.error!.message, CartController.itemGoneMessage);
    });

    test('update of a vanished line (404) is handled the same way', () async {
      await seed();
      service.onUpdate = (_) async =>
          throw apiError(404, message: 'Line item not found');
      service.onGet = (id) async =>
          sale(version: 3, id: id, items: [lineJson(id: 2)]);
      await cart.updateQuantity(1, 4);
      expect(cart.error!.message, CartController.itemGoneMessage);
      expect(cart.sale!.items.map((l) => l.id), [2]);
    });
  });

  group('stale responses', () {
    test(
      'a refresh issued BEFORE a mutation cannot overwrite the mutation result',
      () async {
        await seed();
        final refreshGate = Completer<CartSale>();
        service.onGet = (_) => refreshGate.future;
        final refresh = cart.refresh();
        expect(cart.isRefreshing, isTrue);

        service.onUpdate = (c) async => sale(
          version: 3,
          items: [lineJson(id: 1, quantity: 8), lineJson(id: 2)],
        );
        await cart.updateQuantity(1, 8);
        refreshGate.complete(sale(version: 2)); // old snapshot arrives late
        await refresh;

        expect(cart.sale!.version, 3);
        expect(cart.sale!.items.first.quantity, 8);
        expect(cart.isRefreshing, isFalse);
      },
    );

    test(
      'a response with an OLDER version of the same sale is ignored',
      () async {
        await seed();
        service.onGet = (_) async => sale(
          version: 1,
          items: [lineJson(id: 1, quantity: 99), lineJson(id: 2)],
        );
        await cart.refresh();
        expect(cart.sale!.version, 2);
        expect(cart.sale!.items.first.quantity, 2);
      },
    );

    test('a NEWER server version replaces the local cart', () async {
      await seed();
      service.onGet = (_) async =>
          sale(version: 6, items: [lineJson(id: 1, quantity: 4)]);
      await cart.refresh();
      expect(cart.sale!.version, 6);
      expect(cart.sale!.items, hasLength(1));
    });
  });

  group('refresh', () {
    test('with no cart there is nothing to load', () async {
      await cart.refresh();
      expect(service.getCalls, 0);
    });

    test('concurrent refreshes issue one request', () async {
      await seed();
      final gate = Completer<CartSale>();
      service.onGet = (_) => gate.future;
      final a = cart.refresh();
      final b = cart.refresh();
      final c = cart.refresh();
      gate.complete(sale(version: 2));
      await Future.wait([a, b, c]);
      expect(service.getCalls, 1);
    });

    test(
      'a failed refresh sets loadError, keeps the cart, and Retry recovers',
      () async {
        await seed();
        service.onGet = (_) async => throw apiError(500);
        await cart.refresh();
        expect(cart.loadError!.isRetryable, isTrue);
        expect(cart.sale, isNotNull);
        service.onGet = (id) async => sale(version: 3, id: id);
        await cart.refresh();
        expect(cart.loadError, isNull);
        expect(cart.sale!.version, 3);
      },
    );

    test('a failed refresh is not retried automatically', () async {
      await seed();
      service.onGet = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'offline',
      );
      await cart.refresh();
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(service.getCalls, 1);
    });

    test('a 401 on refresh signs the session out', () async {
      await seed();
      service.onGet = (_) async => throw apiError(401);
      await cart.refresh();
      expect(unauthorized, 1);
    });
  });

  group('other failures', () {
    test('network error on update: cart unchanged, retryable by the user, never auto-retried', () async {
      await seed();
      service.onUpdate = (_) async => throw const ApiException(
        kind: ApiErrorKind.network,
        message: 'Cannot reach the server.',
      );
      expect(await cart.updateQuantity(1, 3), isFalse);
      expect(cart.error!.kind, ApiErrorKind.network);
      expect(cart.error!.isRetryable, isTrue);
      expect(cart.sale!.version, 2);
      expect(service.updateCalls, hasLength(1));
      expect(
        service.getCalls,
        0,
        reason: 'no refresh: nothing is known to have changed',
      );
    });

    test('timeout on remove is reported and not retried', () async {
      await seed();
      service.onRemove = (_) async => throw const ApiException(
        kind: ApiErrorKind.timeout,
        message: 'took too long',
      );
      expect(await cart.removeItem(1), isFalse);
      expect(cart.error!.kind, ApiErrorKind.timeout);
      expect(cart.error!.isRetryable, isTrue);
      expect(service.removeCalls, hasLength(1));
      expect(cart.sale!.items, hasLength(2));
    });

    test('500 on update: retryable, cart unchanged', () async {
      await seed();
      service.onUpdate = (_) async =>
          throw apiError(500, message: 'SELECT * FROM x');
      await cart.updateQuantity(1, 3);
      expect(cart.error!.kind, ApiErrorKind.server);
      expect(cart.error!.message, isNot(contains('SELECT')));
    });

    test(
      '401 on update and on remove signs the session out (once each)',
      () async {
        await seed();
        service.onUpdate = (_) async => throw apiError(401);
        await cart.updateQuantity(1, 3);
        expect(unauthorized, 1);
        service.onRemove = (_) async => throw apiError(401);
        await cart.removeItem(1);
        expect(unauthorized, 2);
        expect(cart.error!.isUnauthorized, isTrue);
      },
    );

    test(
      'a 403 (different shift) is reported, not retried, and not refreshed',
      () async {
        await seed();
        service.onUpdate = (_) async => throw apiError(
          403,
          message: 'This sale belongs to a different shift',
        );
        await cart.updateQuantity(1, 3);
        expect(cart.error!.kind, ApiErrorKind.forbidden);
        expect(cart.error!.isRetryable, isFalse);
        expect(service.getCalls, 0);
      },
    );

    test(
      '422 validation from the server is preserved and not retried',
      () async {
        await seed();
        service.onUpdate = (_) async => throw apiError(
          422,
          message: 'quantity must be an integer between 1 and 9999',
        );
        await cart.updateQuantity(1, 3);
        expect(cart.error!.kind, ApiErrorKind.validation);
        expect(service.updateCalls, hasLength(1));
      },
    );

    test('POS_WEIGHT_UNIT_NOT_SUPPORTED on an update keeps its code and data; the cart is unchanged', () async {
      await seed();
      service.onUpdate = (_) async => throw apiError(
        422,
        message: 'Weight-based products cannot be sold',
        code: 'POS_WEIGHT_UNIT_NOT_SUPPORTED',
        data: {
          'weight_unit_item_ids': [1],
        },
      );
      await cart.updateQuantity(1, 3);
      expect(cart.error!.errorCode, 'POS_WEIGHT_UNIT_NOT_SUPPORTED');
      expect(cart.error!.dataMap!['weight_unit_item_ids'], [1]);
      expect(cart.sale!.items.first.quantity, 2);
      expect(cart.isRetryable, isFalse);
    });

    test('clearError and reset', () async {
      await seed();
      service.onUpdate = (_) async => throw apiError(500);
      await cart.updateQuantity(1, 3);
      cart.clearError();
      expect(cart.error, isNull);
      expect(cart.errorOperation, isNull);
      cart.reset();
      expect(cart.sale, isNull);
    });
  });

  test(
    'variation labels are display-only hints remembered from add-time',
    () async {
      service.onAdd = (_) async => sale(version: 2);
      await cart.addItem(42, 1, label: '250g · pack');
      expect(cart.labelFor(42), '250g · pack');
      expect(cart.labelFor(43), isNull);
      cart.reset();
      expect(cart.labelFor(42), isNull);
    },
  );
}

extension on CartController {
  bool get isRetryable => error?.isRetryable ?? false;
}
