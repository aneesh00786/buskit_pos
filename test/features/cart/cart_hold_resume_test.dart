import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fakes.dart';

CartSale draftSale({
  int id = 7,
  int version = 2,
  List<Map<String, dynamic>>? items,
  String status = 'draft',
}) => CartSale.fromJson(
  saleJson(
    id: id,
    version: version,
    status: status,
    items:
        items ??
        [
          lineJson(id: 1, quantity: 2, name: 'Tea'),
          lineJson(id: 2, variationId: 43, name: 'Salt'),
        ],
  ),
)!;

void main() {
  late FakeCartService service;
  late CartController cart;
  var unauthorized = 0;
  var listChanged = 0;

  /// An open, non-empty draft: sale 7 at version 2.
  Future<void> seedDraft({List<Map<String, dynamic>>? items}) async {
    service.onAdd = (_) async => draftSale(items: items);
    service.onGet = (id) async => draftSale(id: id, items: items);
    expect(await cart.addItem(42, 2), isTrue);
    service.addCalls.clear();
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

  group('hold', () {
    test('sends the sale id and current version, clears the active cart, remembers the held id, refreshes the list', () async {
      await seedDraft();
      expect(await cart.holdCurrent(), isTrue);
      final c = service.holdCalls.single;
      expect((c.saleId, c.expectedVersion), (7, 2));
      expect(
        cart.sale,
        isNull,
        reason: 'the server says it is held: no active draft any more',
      );
      expect(cart.lastHeldSaleId, 7);
      expect(cart.error, isNull);
      expect(cart.isMutating, isFalse);
      expect(listChanged, 1);
    });

    test('the next add after a hold opens a NEW draft', () async {
      await seedDraft();
      await cart.holdCurrent();
      service.onCreate = () async => CartSale.fromJson(saleJson(id: 8))!;
      service.onAdd = (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: 2, items: [lineJson(id: 5)]),
      )!;
      await cart.addItem(1, 1);
      expect(service.createCalls, 2);
      expect(service.addCalls.single.saleId, 8);
    });

    test('an empty cart cannot be held (no request)', () async {
      service.onAdd = (_) async => draftSale(items: []);
      await cart.addItem(1, 1);
      expect(await cart.holdCurrent(), isFalse);
      expect(service.holdCalls, isEmpty);
      expect(cart.error!.message, CartController.emptyHoldMessage);
      expect(cart.errorOperation, CartOperation.hold);
      expect(listChanged, 0);
    });

    test('with no cart at all nothing is sent', () async {
      expect(await cart.holdCurrent(), isFalse);
      expect(service.holdCalls, isEmpty);
      expect(cart.error, isNotNull);
    });

    test('a sale that is not a draft cannot be held (no request)', () async {
      service.onAdd = (_) async => draftSale(status: 'completed');
      await cart.addItem(1, 1);
      expect(await cart.holdCurrent(), isFalse);
      expect(service.holdCalls, isEmpty);
    });

    test('double-tapping Hold sends ONE request', () async {
      await seedDraft();
      final gate = Completer<CartSale>();
      service.onHold = (_) => gate.future;
      final a = cart.holdCurrent();
      final b = cart.holdCurrent();
      final c = cart.holdCurrent();
      expect(cart.isMutating, isTrue);
      expect(cart.operation, CartOperation.hold);
      gate.complete(draftSale(version: 3, status: 'held'));
      expect(await Future.wait([a, b, c]), [true, false, false]);
      expect(service.holdCalls, hasLength(1));
    });

    test('every other cart action is ignored while a hold runs', () async {
      await seedDraft();
      final gate = Completer<CartSale>();
      service.onHold = (_) => gate.future;
      final a = cart.holdCurrent();
      expect(await cart.addItem(9, 1), isFalse);
      expect(await cart.updateQuantity(1, 5), isFalse);
      expect(await cart.removeItem(1), isFalse);
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 2), isFalse);
      gate.complete(draftSale(version: 3, status: 'held'));
      await a;
      expect(service.addCalls, isEmpty);
      expect(service.updateCalls, isEmpty);
      expect(service.removeCalls, isEmpty);
      expect(service.resumeCalls, isEmpty);
    });

    test('409 version conflict: cart refreshed, code+data kept, cashier told to review, NOT retried, list untouched', () async {
      await seedDraft();
      service.onHold = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 6, 'current_status': 'draft'},
      );
      service.onGet = (id) async =>
          draftSale(id: id, version: 6, items: [lineJson(id: 1, quantity: 9)]);
      expect(await cart.holdCurrent(), isFalse);
      expect(service.holdCalls, hasLength(1), reason: 'never silently retried');
      expect(service.getCalls, 1);
      expect(cart.sale!.version, 6);
      expect(cart.sale!.items.first.quantity, 9);
      expect(cart.error!.currentVersion, 6);
      expect(cart.error!.dataMap!['current_status'], 'draft');
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.errorOperation, CartOperation.hold);
      expect(listChanged, 0);
    });

    test(
      '409 "not a draft": refreshed and the cart becomes read-only',
      () async {
        await seedDraft();
        service.onHold = (_) async => throw apiError(
          409,
          message: 'Sale is not a draft (current status: held)',
        );
        service.onGet = (id) async =>
            draftSale(id: id, version: 5, status: 'held');
        await cart.holdCurrent();
        expect(cart.error!.message, CartController.holdNotDraftMessage);
        expect(cart.sale!.isDraft, isFalse);
        expect(await cart.updateQuantity(1, 4), isFalse);
      },
    );

    test('403 (draft belongs to another shift): message kept, no refresh, not retryable', () async {
      await seedDraft();
      service.onHold = (_) async => throw apiError(
        403,
        message: 'This sale belongs to a different shift',
      );
      await cart.holdCurrent();
      expect(cart.error!.kind, ApiErrorKind.forbidden);
      expect(cart.error!.message, contains('different shift'));
      expect(cart.error!.isRetryable, isFalse);
      expect(service.getCalls, 0);
      expect(cart.sale, isNotNull, reason: 'nothing changed on the server');
      expect(listChanged, 0);
    });

    test('404 keeps the server message and does not clear the cart', () async {
      await seedDraft();
      service.onHold = (_) async =>
          throw apiError(404, message: 'Sale not found');
      await cart.holdCurrent();
      expect(cart.error!.kind, ApiErrorKind.notFound);
      expect(cart.sale, isNotNull);
    });

    test('network error and timeout: cart kept, retryable by the user, no automatic retry', () async {
      await seedDraft();
      for (final k in [ApiErrorKind.network, ApiErrorKind.timeout]) {
        service.onHold = (_) async => throw ApiException(kind: k, message: 'x');
        expect(await cart.holdCurrent(), isFalse);
        expect(cart.error!.kind, k);
        expect(cart.error!.isRetryable, isTrue);
        expect(cart.sale, isNotNull);
      }
      expect(service.holdCalls, hasLength(2), reason: 'one per explicit tap');
      expect(listChanged, 0);
    });

    test('500 never shows server text; 401 signs the session out', () async {
      await seedDraft();
      service.onHold = (_) async =>
          throw apiError(500, message: 'ER_LOCK_DEADLOCK');
      await cart.holdCurrent();
      expect(cart.error!.message, isNot(contains('ER_LOCK')));
      service.onHold = (_) async => throw apiError(401);
      await cart.holdCurrent();
      expect(unauthorized, 1);
    });

    test('an unexpected non-held response is shown as the server sent it, not treated as held', () async {
      await seedDraft();
      service.onHold = (_) async => draftSale(version: 3, status: 'draft');
      await cart.holdCurrent();
      expect(cart.sale, isNotNull);
      expect(cart.sale!.version, 3);
    });

    test('controls are usable again after a failed hold', () async {
      await seedDraft();
      service.onHold = (_) async => throw apiError(500);
      await cart.holdCurrent();
      expect(cart.isMutating, isFalse);
      service.onHold = (c) async =>
          draftSale(version: c.expectedVersion + 1, status: 'held');
      expect(await cart.holdCurrent(), isTrue);
    });
  });

  group('resume', () {
    test('sends the sale id and the given version, applies the returned draft, refreshes the list', () async {
      service.onResume = (c) async =>
          draftSale(id: c.saleId, version: c.expectedVersion + 1);
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 4), isTrue);
      final c = service.resumeCalls.single;
      expect((c.saleId, c.expectedVersion), (9, 4));
      expect(
        (cart.sale!.id, cart.sale!.version, cart.sale!.isDraft),
        (9, 5, true),
      );
      expect(cart.error, isNull);
      expect(listChanged, 1);
      expect(service.holdCalls, isEmpty);
    });

    test(
      'the resumed sale can be edited: later mutations use ITS id and version',
      () async {
        service.onResume = (c) async => draftSale(id: c.saleId, version: 5);
        await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
        service.onUpdate = (c) async => draftSale(id: c.saleId, version: 6);
        await cart.updateQuantity(1, 5);
        expect(
          (
            service.updateCalls.single.saleId,
            service.updateCalls.single.expectedVersion,
          ),
          (9, 5),
        );
      },
    );

    test('an open draft with items is NEVER discarded: resume is refused unless holdCurrentFirst', () async {
      await seedDraft();
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 4), isFalse);
      expect(service.resumeCalls, isEmpty);
      expect(service.holdCalls, isEmpty);
      expect(cart.sale!.id, 7, reason: 'the active cart is untouched');
      expect(cart.error!.message, CartController.openDraftMessage);
      expect(cart.errorOperation, CartOperation.resume);
      expect(listChanged, 0);
    });

    test('holdCurrentFirst: the open draft is held FIRST, then the other sale is resumed (in that order)', () async {
      await seedDraft();
      service.onResume = (c) async => draftSale(
        id: c.saleId,
        version: 5,
        items: [lineJson(id: 7, name: 'Other')],
      );
      expect(
        await cart.resumeHeldSale(
          saleId: 9,
          expectedVersion: 4,
          holdCurrentFirst: true,
        ),
        isTrue,
      );
      expect(service.callLog, ['hold:7', 'resume:9']);
      expect(
        (
          service.holdCalls.single.saleId,
          service.holdCalls.single.expectedVersion,
        ),
        (7, 2),
      );
      expect(service.resumeCalls.single.saleId, 9);
      expect(cart.sale!.id, 9);
      expect(cart.lastHeldSaleId, 7);
      expect(listChanged, 1);
    });

    test(
      'if holding the open draft fails, nothing is resumed and the draft stays',
      () async {
        await seedDraft();
        service.onHold = (_) async => throw apiError(
          409,
          data: {'current_version': 5},
          message: 'Sale has been modified since you last read it',
        );
        service.onGet = (id) async => draftSale(id: id, version: 5);
        expect(
          await cart.resumeHeldSale(
            saleId: 9,
            expectedVersion: 4,
            holdCurrentFirst: true,
          ),
          isFalse,
        );
        expect(
          service.resumeCalls,
          isEmpty,
          reason: 'never resume over an unsaved draft',
        );
        expect(cart.sale!.id, 7);
        expect(cart.sale!.version, 5, reason: 'refreshed');
        expect(cart.error!.message, CartController.conflictMessage);
        expect(listChanged, 0);
      },
    );

    test('if resuming fails AFTER the draft was held, the draft is safe on the server and the list is refreshed', () async {
      await seedDraft();
      service.onResume = (_) async => throw apiError(
        409,
        message: 'Sale is not held (current status: draft)',
      );
      expect(
        await cart.resumeHeldSale(
          saleId: 9,
          expectedVersion: 4,
          holdCurrentFirst: true,
        ),
        isFalse,
      );
      expect(service.callLog, ['hold:7', 'resume:9']);
      expect(cart.sale, isNull, reason: 'the previous draft is held, not lost');
      expect(cart.lastHeldSaleId, 7);
      expect(cart.error!.message, CartController.resumeUnavailableMessage);
      expect(
        listChanged,
        1,
        reason: 'a new held sale exists and the target changed',
      );
    });

    test('an EMPTY open draft may be replaced without holding it', () async {
      service.onAdd = (_) async => draftSale(items: []);
      await cart.addItem(1, 1);
      service.holdCalls.clear();
      service.onResume = (c) async => draftSale(id: c.saleId, version: 5);
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 4), isTrue);
      expect(service.holdCalls, isEmpty);
      expect(cart.sale!.id, 9);
    });

    test('409 version conflict: message + current_version kept, list refreshed, NOT retried, active cart untouched', () async {
      service.onResume = (_) async => throw apiError(
        409,
        message: 'Sale has been modified since you last read it',
        data: {'current_version': 8, 'current_status': 'held'},
      );
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 4), isFalse);
      expect(service.resumeCalls, hasLength(1));
      expect(cart.error!.currentVersion, 8);
      expect(cart.error!.dataMap!['current_status'], 'held');
      expect(cart.error!.message, CartController.conflictMessage);
      expect(cart.errorOperation, CartOperation.resume);
      expect(cart.sale, isNull);
      expect(listChanged, 1, reason: 'the list is out of date');
    });

    test('already resumed / canceled / completed elsewhere (409 not held): clear message and the list refreshes', () async {
      for (final status in ['draft', 'canceled', 'completed']) {
        listChanged = 0;
        service.onResume = (_) async => throw apiError(
          409,
          message: 'Sale is not held (current status: $status)',
        );
        expect(
          await cart.resumeHeldSale(saleId: 9, expectedVersion: 4),
          isFalse,
        );
        expect(
          cart.error!.message,
          CartController.resumeUnavailableMessage,
          reason: status,
        );
        expect(listChanged, 1, reason: status);
      }
    });

    test(
      '404 (sale no longer exists): friendly message and list refresh',
      () async {
        service.onResume = (_) async =>
            throw apiError(404, message: 'Sale not found');
        await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
        expect(cart.error!.message, CartController.resumeGoneMessage);
        expect(cart.error!.kind, ApiErrorKind.notFound);
        expect(listChanged, 1);
      },
    );

    test('403 (a different store): server message kept, not retryable, no list refresh', () async {
      service.onResume = (_) async => throw apiError(
        403,
        message: 'This sale belongs to a different store',
      );
      await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      expect(cart.error!.kind, ApiErrorKind.forbidden);
      expect(cart.error!.message, contains('different store'));
      expect(cart.error!.isRetryable, isFalse);
      expect(listChanged, 0);
    });

    test('double-tapping Resume sends ONE request', () async {
      final gate = Completer<CartSale>();
      service.onResume = (_) => gate.future;
      final a = cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      final b = cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      expect(cart.operation, CartOperation.resume);
      gate.complete(draftSale(id: 9, version: 5));
      expect(await Future.wait([a, b]), [true, false]);
      expect(service.resumeCalls, hasLength(1));
    });

    test('network error, timeout, 500 and 401 are reported; nothing is retried automatically', () async {
      for (final k in [ApiErrorKind.network, ApiErrorKind.timeout]) {
        service.onResume = (_) async =>
            throw ApiException(kind: k, message: 'x');
        expect(
          await cart.resumeHeldSale(saleId: 9, expectedVersion: 4),
          isFalse,
        );
        expect(cart.error!.isRetryable, isTrue);
      }
      service.onResume = (_) async => throw apiError(500, message: 'internal');
      await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      expect(cart.error!.message, isNot(contains('internal')));
      service.onResume = (_) async => throw apiError(401);
      await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      expect(unauthorized, 1);
      expect(service.resumeCalls, hasLength(4));
      expect(listChanged, 0);
    });

    test('a reload that started BEFORE the resume cannot overwrite the resumed sale', () async {
      service.onAdd = (_) async => draftSale(items: []);
      await cart.addItem(1, 1); // an empty active draft (sale 7)
      final gate = Completer<CartSale>();
      service.onGet = (_) => gate.future;
      final refresh = cart.refresh();
      service.onResume = (c) async => draftSale(id: c.saleId, version: 5);
      expect(await cart.resumeHeldSale(saleId: 9, expectedVersion: 4), isTrue);
      gate.complete(
        draftSale(id: 7, version: 9),
      ); // the late answer about the OLD sale
      await refresh;
      expect(cart.sale!.id, 9);
      expect(cart.isRefreshing, isFalse);
    });

    test('a resumed sale is shown with whatever lifecycle status the server reports', () async {
      service.onResume = (c) async =>
          draftSale(id: c.saleId, version: 5, status: 'held');
      await cart.resumeHeldSale(saleId: 9, expectedVersion: 4);
      expect(cart.sale!.isDraft, isFalse);
      expect(
        await cart.updateQuantity(1, 3),
        isFalse,
        reason: 'read-only: no edit request',
      );
      expect(service.updateCalls, isEmpty);
    });
  });

  test('hasActiveDraftWithItems reflects the open cart', () async {
    expect(cart.hasActiveDraftWithItems, isFalse);
    await seedDraft();
    expect(cart.hasActiveDraftWithItems, isTrue);
    await cart.holdCurrent();
    expect(cart.hasActiveDraftWithItems, isFalse);
  });

  test('clearError and reset also clear hold/resume state', () async {
    await seedDraft();
    service.onHold = (_) async => throw apiError(500);
    await cart.holdCurrent();
    cart.clearError();
    expect((cart.error, cart.errorOperation), (null, null));
    cart.reset();
    expect(cart.sale, isNull);
  });
}
