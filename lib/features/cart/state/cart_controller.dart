import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/uuid.dart';
import '../../checkout/models/payment.dart';
import '../data/cart_service.dart';
import '../models/cart_sale.dart';

enum CartOperation {
  add,
  update,
  remove,
  hold,
  resume,
  cancel,
  cancelHeld,
  complete,
}

/// Holds the current draft sale and mutates it (add / update quantity /
/// remove / hold / resume). The client sends only ids, quantities and the
/// version token; the server decides prices, tax, totals, availability, stock,
/// ownership and lifecycle — the UI shows exactly what the server returns and
/// nothing is computed locally.
///
/// Concurrency rules:
///  * only ONE mutation runs at a time (a sale has a single version token, so
///    concurrent mutations would race it). Any further tap while one is in
///    flight is ignored — this also stops double-taps from repeating a change;
///  * every response is applied through [_apply], which refuses to replace the
///    cart with an older version of the same sale, and a refresh that was
///    issued before a newer mutation is discarded when it returns;
///  * a 409 version conflict (or a 404 for something that is already gone)
///    refreshes from the server and tells the cashier to review it — the
///    mutation is NEVER retried automatically.
///
/// Lifecycle (backend rules): hold = draft -> held (only the shift that owns
/// the draft); resume = held -> draft, re-assigned to the resumer's shift.
/// An open draft that has items is never discarded: resuming another sale over
/// it requires `holdCurrentFirst`, which holds it (safely, on the server) first.
class CartController extends ChangeNotifier {
  CartController(this._service, {this.onUnauthorized, this.onHeldSalesChanged});

  static const int minQuantity = 1;
  static const int maxQuantity = 9999; // backend MAX_QUANTITY

  static const String conflictMessage =
      'The cart was changed elsewhere and has been refreshed. Please review it and try again.';
  static const String itemGoneMessage =
      'That item is no longer in the cart, so nothing was changed. The cart has been refreshed.';
  static const String holdNotDraftMessage =
      'This sale can no longer be held because it is not an open draft any more. The cart has been refreshed.';
  static const String resumeUnavailableMessage =
      'That sale can no longer be resumed — it is no longer on hold. The held-sales list has been refreshed.';
  static const String resumeGoneMessage =
      'That held sale no longer exists. The held-sales list has been refreshed.';
  static const String cancelNotAllowedMessage =
      'This sale can no longer be voided — it has already been completed, canceled or changed.';
  static const String cancelGoneMessage = 'That sale no longer exists.';
  static const String emptyHoldMessage =
      'Add at least one item before holding a sale.';
  static const String openDraftMessage =
      'Hold the current sale before resuming another one, so nothing is lost.';

  final CartService _service;
  final VoidCallback? onUnauthorized;

  /// Called after a hold or resume succeeded, and when a resume failed because
  /// the held-sales list is out of date, so the list can reload.
  final VoidCallback? onHeldSalesChanged;

  CartSale? _sale;
  CartOperation? _op;

  /// Which server call is running inside the current operation (a resume that
  /// must hold the open draft first has two).
  CartOperation? _step;
  int? _busyItemId;
  bool _refreshing = false;
  int _refreshGen = 0;
  ApiException? _error;
  CartOperation? _errorOp;
  ApiException? _loadError;
  int? _lastHeldSaleId;
  int? _lastCancelledSaleId;
  String? _pendingCustomerId;
  String? _pendingCustomerLabel;
  CompletedSale? _completed;
  Map<int, String> _completedNames = const {};
  Map<int, String> _completedVariants = const {};
  _CompletionAttempt? _attempt;
  bool _heldDuringOp = false;
  bool _disposed = false;
  Future<CartSale>? _creating;

  /// Display-only variation labels remembered when an item is added (the live
  /// sale view carries no variation name). Never used for any decision.
  final Map<int, String> _labels = {};

  /// Display-only thumbnails remembered at add time, for the same reason.
  final Map<int, String> _images = {};

  CartSale? get sale => _sale;

  /// True while any add/update/remove/hold/resume request is in flight.
  bool get isMutating => _op != null;
  bool get isAdding => _op == CartOperation.add;
  int? get mutatingItemId => _busyItemId;
  CartOperation? get operation => _op;

  /// True while the cart is being reloaded from the server.
  bool get isRefreshing => _refreshing;

  /// The last mutation failure (cashier-facing wording; code/data preserved).
  ApiException? get error => _error;

  /// Which operation produced [error]. Add failures are reported where the
  /// item was added (snackbar / variation sheet), resume failures in the
  /// held-sales view; the cart panel shows update/remove/hold failures so one
  /// failure is never announced twice.
  CartOperation? get errorOperation => _errorOp;

  /// The last reload failure.
  ApiException? get loadError => _loadError;

  /// Id of the sale most recently put on hold by this controller (for the
  /// confirmation message).
  int? get lastHeldSaleId => _lastHeldSaleId;

  /// An open draft that holds items — the only state in which resuming
  /// another sale could lose work.
  bool get hasActiveDraftWithItems =>
      _sale != null && _sale!.isDraft && _sale!.items.isNotEmpty;

  int? get lastCancelledSaleId => _lastCancelledSaleId;

  /// The customer ID chosen for the NEXT sale (null = guest checkout). The
  /// server only accepts it when the sale is created.
  String? get pendingCustomerId => _pendingCustomerId;

  /// The chosen customer's display name, if the picker had one (search result
  /// or a customer just created) — null once a real sale exists, since the
  /// server's sale view carries only the id, not the name.
  String? get pendingCustomerLabel =>
      _sale == null ? _pendingCustomerLabel : null;

  /// The customer attached to what is on screen: the open sale's, else the
  /// pending choice for the sale about to start.
  String? get customerId =>
      _sale != null ? _sale!.customerId : _pendingCustomerId;

  /// The customer can only be chosen while no sale exists yet.
  bool get canChooseCustomer => _sale == null && _op == null;

  /// The sale completed most recently (for the success view).
  CompletedSale? get completedSale => _completed;

  /// Product names by line id, captured from the cart when the sale was paid
  /// (the completed sale view carries no names).
  Map<int, String> get completedNames => _completedNames;

  /// True while a completion attempt (and its idempotency key) is kept for a
  /// safe retry after a failure whose outcome may be unknown.
  bool get hasPendingCompletion => _attempt != null;

  /// The idempotency key of the current attempt (null when none).
  String? get currentIdempotencyKey => _attempt?.key;

  /// Variation/unit labels by line id, captured with [completedNames].
  Map<int, String> get completedVariants => _completedVariants;

  String? labelFor(int productVariationId) => _labels[productVariationId];
  String? imageFor(int productVariationId) => _images[productVariationId];

  void clearError() {
    if (_error == null && _loadError == null) return;
    _error = null;
    _errorOp = null;
    _loadError = null;
    _notify();
  }

  // ---- add ----

  /// Adds [quantity] of the variation with numeric id [productVariationId].
  /// Returns true only when the server accepted it; false when ignored (a
  /// mutation is already in flight) or rejected ([error] is set only for
  /// rejections).
  Future<bool> addItem(
    int productVariationId,
    int quantity, {
    String? label,
    String? imageUrl,
  }) async {
    if (_op != null) return false;
    final invalid = _validateQuantity(quantity);
    if (invalid != null) return _rejectLocally(invalid, CartOperation.add);

    return _run(CartOperation.add, null, () async {
      final sale = await _ensureSale();
      final updated = await _service.addItem(
        saleId: sale.id,
        productVariationId: productVariationId,
        quantity: quantity,
        expectedVersion: sale.version,
      );
      if (label != null && label.trim().isNotEmpty) {
        _labels[productVariationId] = label.trim();
      }
      if (imageUrl != null && imageUrl.isNotEmpty) {
        _images[productVariationId] = imageUrl;
      }
      return updated;
    });
  }

  // ---- update ----

  /// Sets line [itemId] (`items[].id`) to [quantity]. Unchanged quantities
  /// succeed without a request.
  Future<bool> updateQuantity(int itemId, int quantity) async {
    if (_op != null) return false;
    final sale = _sale;
    final line = sale?.items.where((l) => l.id == itemId).firstOrNull;
    if (sale == null || line == null || !sale.isDraft) return false;
    final invalid = _validateQuantity(quantity);
    if (invalid != null) return _rejectLocally(invalid, CartOperation.update);
    if (line.quantity == quantity) return true;

    return _run(CartOperation.update, itemId, () async {
      return _service.updateItem(
        saleId: sale.id,
        itemId: itemId,
        quantity: quantity,
        expectedVersion: sale.version,
      );
    });
  }

  // ---- remove ----

  Future<bool> removeItem(int itemId) async {
    if (_op != null) return false;
    final sale = _sale;
    final line = sale?.items.where((l) => l.id == itemId).firstOrNull;
    if (sale == null || line == null || !sale.isDraft) return false;

    return _run(CartOperation.remove, itemId, () async {
      return _service.removeItem(
        saleId: sale.id,
        itemId: itemId,
        expectedVersion: sale.version,
      );
    });
  }

  // ---- clear all ----

  /// Removes every line of the open draft using the existing item-removal
  /// endpoint, one line at a time with the version chained from each response
  /// (there is no bulk endpoint, and the sale itself is left open and empty —
  /// it is not canceled). Stops at the first failure; whatever was already
  /// removed stays removed and the cart shows the server's latest state. A
  /// version conflict refreshes the cart and is never retried.
  Future<bool> clearAll() async {
    if (_op != null) return false;
    final sale = _sale;
    if (sale == null || !sale.isDraft || sale.items.isEmpty) return false;

    return _run(CartOperation.remove, null, () async {
      var current = sale;
      for (final line in List.of(sale.items)) {
        current = await _service.removeItem(
          saleId: current.id,
          itemId: line.id,
          expectedVersion: current.version,
        );
        _apply(current); // show progress as the server confirms each removal
      }
      return current;
    });
  }

  // ---- hold ----

  /// Puts the current draft on hold (`POST /sales/:id/hold`). Only a non-empty
  /// draft can be held (the server would accept an empty one; the POS does
  /// not). On success the active cart is cleared — the sale is now `held` on
  /// the server and is resumed from the held-sales list.
  Future<bool> holdCurrent() async {
    if (_op != null) return false;
    final sale = _sale;
    if (sale == null || !sale.isDraft || sale.items.isEmpty) {
      return _rejectLocally(emptyHoldMessage, CartOperation.hold);
    }
    return _run(
      CartOperation.hold,
      null,
      () => _service.holdSale(saleId: sale.id, expectedVersion: sale.version),
      onSuccess: (result) {
        final held = result as CartSale;
        if (held.status == 'held') {
          _clearActiveAfterHold(held);
        } else {
          _apply(held); // unexpected lifecycle state: show what the server says
        }
      },
    );
  }

  // ---- resume ----

  /// Resumes held sale [saleId] (`POST /sales/:id/resume`) using the version
  /// the caller last saw. If a non-empty draft is open, [holdCurrentFirst]
  /// must be true (an explicit cashier decision): it is held first, inside the
  /// same locked operation, and only then is the other sale resumed — so no
  /// work is ever discarded. If the second step fails the first stays held
  /// (visible in the list) and the active cart is empty.
  Future<bool> resumeHeldSale({
    required int saleId,
    required int expectedVersion,
    bool holdCurrentFirst = false,
  }) async {
    if (_op != null) return false;
    final active = _sale;
    final mustHold = hasActiveDraftWithItems;
    if (mustHold && !holdCurrentFirst) {
      return _rejectLocally(openDraftMessage, CartOperation.resume);
    }

    return _run(
      CartOperation.resume,
      null,
      () async {
        if (mustHold && active != null) {
          _step = CartOperation.hold;
          final held = await _service.holdSale(
            saleId: active.id,
            expectedVersion: active.version,
          );
          if (held.status == 'held') {
            _clearActiveAfterHold(held);
            _heldDuringOp = true;
          }
        }
        _step = CartOperation.resume;
        return _service.resumeSale(
          saleId: saleId,
          expectedVersion: expectedVersion,
        );
      },
      onSuccess: (resumed) {
        // A different sale from the (already cleared) previous cart; whatever
        // status the server reports is shown as-is.
        _sale = resumed as CartSale;
      },
    );
  }

  // ---- customer ----

  /// Chooses the customer for the next sale ([id] null/blank = guest). [label]
  /// is display-only (the name shown before the sale exists); only possible
  /// before a sale exists, returns false otherwise.
  bool setPendingCustomer(String? id, {String? label}) {
    if (!canChooseCustomer) return false;
    final t = id?.trim();
    _pendingCustomerId = (t == null || t.isEmpty) ? null : t;
    _pendingCustomerLabel = _pendingCustomerId == null ? null : label;
    _notify();
    return true;
  }

  // ---- complete (pay) ----

  static const String emptyCompleteMessage =
      'Add at least one item before taking payment.';

  /// Completes the open draft with [payments] (`POST /sales/:id/complete`).
  ///
  /// The idempotency key is a UUID v4 created for THIS attempt (sale id +
  /// version + payments). If the request fails — including a network error or
  /// timeout where the outcome is unknown — the same key is sent again on
  /// retry, so the server can replay the result instead of charging twice.
  /// A different payment set or sale version gets a new key (the server
  /// rejects a reused key with a different request). Prices and totals are
  /// never sent; the server recomputes and requires the payments to sum to its
  /// total exactly. Nothing is retried automatically.
  Future<bool> completeSale(List<PaymentLine> payments) async {
    if (_op != null) return false;
    final sale = _sale;
    if (sale == null ||
        !sale.isDraft ||
        sale.items.isEmpty ||
        payments.isEmpty) {
      return _rejectLocally(emptyCompleteMessage, CartOperation.complete);
    }

    final fingerprint =
        '${sale.id}|${sale.version}|${(payments.map((p) => p.canonical).toList()..sort()).join(';')}';
    if (_attempt == null || _attempt!.fingerprint != fingerprint) {
      _attempt = _CompletionAttempt(generateUuidV4(), fingerprint);
    }
    final attempt = _attempt!;
    final names = {
      for (final l in sale.items)
        l.id: l.productName ?? 'Item ${l.productVariationId}',
    };
    final variants = {
      for (final l in sale.items)
        if (_labels[l.productVariationId] != null)
          l.id: _labels[l.productVariationId]!,
    };

    return _run(
      CartOperation.complete,
      null,
      () => _service.completeSale(
        saleId: sale.id,
        expectedVersion: sale.version,
        idempotencyKey: attempt.key,
        payments: payments,
      ),
      onSuccess: (result) {
        _completed = result as CompletedSale;
        _completedNames = names;
        _completedVariants = variants;
        _sale = null; // the sale is done: the cart is empty again
        _pendingCustomerId = null;
        _pendingCustomerLabel = null;
        _attempt = null;
        _labels.clear();
        _images.clear();
      },
    );
  }

  /// Forget the completed sale after the cashier dismisses the success view.
  void acknowledgeCompletion() {
    if (_completed == null) return;
    _completed = null;
    _completedNames = const {};
    _completedVariants = const {};
    _notify();
  }

  // ---- cancel (void) ----

  /// Voids the open draft (`POST /sales/:id/cancel`). On success the cart is
  /// cleared. Only the caller decides to do this — the UI asks for confirmation.
  Future<bool> cancelCurrent() async {
    if (_op != null) return false;
    final sale = _sale;
    if (sale == null || !sale.isDraft) return false;
    return _run(
      CartOperation.cancel,
      null,
      () => _service.cancelSale(saleId: sale.id, expectedVersion: sale.version),
      onSuccess: (result) {
        _lastCancelledSaleId = (result as CartSale).id;
        _sale = null;
        _pendingCustomerId = null;
        _pendingCustomerLabel = null;
        _attempt = null;
        _labels.clear();
        _images.clear();
      },
    );
  }

  /// Voids a HELD sale (from the held-sales list) using the version the
  /// caller last saw. The open cart is not touched.
  Future<bool> cancelHeldSale({
    required int saleId,
    required int expectedVersion,
  }) async {
    if (_op != null) return false;
    return _run(
      CartOperation.cancelHeld,
      null,
      () =>
          _service.cancelSale(saleId: saleId, expectedVersion: expectedVersion),
      onSuccess: (result) => _lastCancelledSaleId = (result as CartSale).id,
    );
  }

  // ---- refresh ----

  /// Reloads the current sale from the server (also the "Retry" action).
  /// Ignored when there is no sale yet or a reload is already running.
  Future<void> refresh() async {
    final current = _sale;
    if (current == null || _refreshing) return;
    _refreshing = true;
    _loadError = null;
    final gen = ++_refreshGen;
    _notify();
    try {
      final fresh = await _service.getSale(current.id);
      // A reload superseded by a newer mutation is dropped.
      if (gen == _refreshGen) {
        _apply(fresh);
      }
    } on ApiException catch (e) {
      if (gen == _refreshGen) {
        _loadError = e;
        if (e.isUnauthorized) onUnauthorized?.call();
      }
    } finally {
      _refreshing = false;
      _notify();
    }
  }

  /// Forget the local cart (new sale, sign-out, shift change). Does not touch
  /// the sale on the server.
  void reset() {
    _sale = null;
    _error = null;
    _errorOp = null;
    _loadError = null;
    _op = null;
    _step = null;
    _busyItemId = null;
    _creating = null;
    _refreshGen++;
    _refreshing = false;
    _labels.clear();
    _images.clear();
    _pendingCustomerId = null;
    _pendingCustomerLabel = null;
    _completed = null;
    _completedNames = const {};
    _completedVariants = const {};
    _attempt = null;
    _notify();
  }

  // ---- internals ----

  String? _validateQuantity(int q) => (q < minQuantity || q > maxQuantity)
      ? 'Quantity must be a whole number from $minQuantity to $maxQuantity.'
      : null;

  bool _rejectLocally(String message, CartOperation op) {
    _error = ApiException(kind: ApiErrorKind.validation, message: message);
    _errorOp = op;
    _notify();
    return false;
  }

  void _clearActiveAfterHold(CartSale held) {
    _lastHeldSaleId = held.id;
    _sale = null;
    _pendingCustomerId = null; // the next sale starts as a guest again
    _pendingCustomerLabel = null;
    _labels.clear();
    _images.clear();
  }

  Future<bool> _run(
    CartOperation op,
    int? itemId,
    Future<Object?> Function() request, {
    void Function(Object? result)? onSuccess,
  }) async {
    _op = op;
    _step = op;
    _busyItemId = itemId;
    _error = null;
    _errorOp = null;
    _heldDuringOp = false;
    _refreshGen++; // any reload issued before this mutation is now stale
    _notify();
    var succeeded = false;
    var listMayBeStale = false;
    try {
      final result = await request();
      if (onSuccess != null) {
        onSuccess(result);
      } else if (result is CartSale) {
        _apply(result);
      }
      _loadError = null;
      succeeded = true;
      return true;
    } on ApiException catch (e) {
      final step = _step ?? op;
      _error = _friendly(e, step);
      _errorOp = op;
      if (e.isUnauthorized) onUnauthorized?.call();

      final vanished =
          e.kind == ApiErrorKind.notFound &&
          (step == CartOperation.update || step == CartOperation.remove);
      if (_sale != null && (e.kind == ApiErrorKind.conflict || vanished)) {
        await _reload();
      }

      // A resume that failed because the sale changed under us means the
      // held-sales list is out of date.
      listMayBeStale =
          (step == CartOperation.resume || step == CartOperation.cancelHeld) &&
          (e.kind == ApiErrorKind.conflict || e.kind == ApiErrorKind.notFound);
      return false;
    } finally {
      final held = _heldDuringOp;
      _op = null;
      _step = null;
      _busyItemId = null;
      _heldDuringOp = false;
      _notify();
      final changedHoldState =
          (succeeded &&
              (op == CartOperation.hold ||
                  op == CartOperation.resume ||
                  op == CartOperation.cancelHeld)) ||
          held;
      if (changedHoldState || listMayBeStale) onHeldSalesChanged?.call();
    }
  }

  ApiException _friendly(ApiException e, CartOperation step) {
    if (e.isVersionConflict) return e.withMessage(conflictMessage);
    switch (step) {
      case CartOperation.hold:
        if (e.kind == ApiErrorKind.conflict) {
          return e.withMessage(holdNotDraftMessage);
        }
      case CartOperation.resume:
        if (e.kind == ApiErrorKind.conflict) {
          return e.withMessage(resumeUnavailableMessage);
        }
        if (e.kind == ApiErrorKind.notFound) {
          return e.withMessage(resumeGoneMessage);
        }
      case CartOperation.update:
      case CartOperation.remove:
        if (e.kind == ApiErrorKind.notFound) {
          return e.withMessage(itemGoneMessage);
        }
      case CartOperation.cancel:
      case CartOperation.cancelHeld:
        if (e.kind == ApiErrorKind.conflict) {
          return e.withMessage(cancelNotAllowedMessage);
        }
        if (e.kind == ApiErrorKind.notFound) {
          return e.withMessage(cancelGoneMessage);
        }
      case CartOperation.complete:
      case CartOperation.add:
        break;
    }
    return e;
  }

  /// Applies a server response unless it is an OLDER version of the same sale
  /// than the one already shown (server versions only ever increase).
  void _apply(CartSale incoming) {
    final current = _sale;
    if (current != null &&
        incoming.id == current.id &&
        incoming.version < current.version) {
      return;
    }
    _sale = incoming;
  }

  Future<void> _reload() async {
    final current = _sale;
    if (current == null) return;
    try {
      _apply(await _service.getSale(current.id));
    } on ApiException {
      // Keep the previous view; the original error is what the cashier sees.
    }
  }

  Future<CartSale> _ensureSale() async {
    final existing = _sale;
    if (existing != null && existing.isDraft) return existing;
    // Share one in-flight creation so two callers can never open two sales.
    final pending = _creating ??= _service.createSale(
      customerId: _pendingCustomerId,
    );
    try {
      final created = await pending;
      _sale = created;
      return created;
    } finally {
      _creating = null;
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// One completion attempt: the idempotency key and what it was generated for.
class _CompletionAttempt {
  _CompletionAttempt(this.key, this.fingerprint);
  final String key;
  final String fingerprint;
}
