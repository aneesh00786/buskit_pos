import 'package:flutter/foundation.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/quantity.dart';
import '../../../core/utils/uuid.dart';
import '../../checkout/models/payment.dart';
import '../../offline/models/offline_sale.dart';
import '../../offline/offline_checkout_service.dart';
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
  promotion,
  loyalty,
  discountOverride,
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
///
/// OFFLINE (only when [offline] is wired and the API client reports the
/// server unreachable — `reachable == false`; unknown is NOT offline):
///  * a cart started while offline is a LOCAL cart ([CartSale.isLocal]): its
///    lines are priced from the offline catalogue with the ported server tax
///    rule, and it can only be completed as an offline sale (even if the
///    connection returns meanwhile — nothing is ever sent twice);
///  * a cart started online (a server draft) can still be PAID while offline:
///    its server-computed lines are re-checked and recorded as an offline
///    sale, unless an earlier online completion attempt may have reached the
///    server (then the cashier must retry online, so the sale is never
///    recorded twice);
///  * the online paths below are unchanged and are taken whenever the server
///    is reachable or reachability is unknown.
class CartController extends ChangeNotifier {
  CartController(
    this._service, {
    this.onUnauthorized,
    this.onHeldSalesChanged,
    this.offline,
    this.onServerSaleCompleted,
  });

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

  /// Offline checkout wiring; null = online-only (the previous behaviour).
  final OfflineCartSupport? offline;

  /// Called with the server sale id after it completed (Phase 6: clears the
  /// sale's payment-recovery reminder).
  final void Function(int saleId)? onServerSaleCompleted;

  static const String holdOfflineMessage =
      'Holding a sale needs an internet connection.';
  static const String localCartOpenMessage =
      'Complete or void the offline sale before resuming another one.';
  static const String completionMayHaveReachedServerMessage =
      'The last payment attempt may have reached the server. Reconnect and retry so the sale is not recorded twice.';

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

  // ---- local (offline) cart ----
  /// Lines of a cart built on this device while offline; null = no local
  /// cart. Each line is keyed (and shown with line id) by its variation id.
  List<OfflineCheckoutLine>? _local;
  int _localVersion = 0;
  OfflineSale? _completedOffline;
  _CompletionAttempt? _offlineAttempt;

  /// True when the last ONLINE completion failed in a way whose outcome is
  /// unknown (network, timeout, server error): the sale may already be
  /// completed on the server, so it must not be recorded offline as well.
  bool _onlineOutcomeUnknown = false;

  CartSale? get sale => _local != null ? _localView() : _sale;

  /// True while the cart is a local (offline) cart.
  bool get isLocalSale => _local != null;

  /// The sale most recently saved on this device (for the success view).
  OfflineSale? get completedOfflineSale => _completedOffline;

  /// True when paying now would record the sale on this device instead of
  /// completing it on the server.
  bool get willCompleteOffline =>
      _local != null || (_sale != null && _isOffline);

  bool get _isOffline => offline != null && offline!.isOffline();

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
      (_local != null && _local!.isNotEmpty) ||
      (_sale != null && _sale!.isDraft && _sale!.items.isNotEmpty);

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
  bool get canChooseCustomer => _sale == null && _local == null && _op == null;

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
    num quantity, {
    String? label,
    String? imageUrl,
    String sellingMode = 'PIECE',
  }) async {
    if (_op != null) return false;
    final invalid = _validateQuantity(quantity, sellingMode);
    if (invalid != null) return _rejectLocally(invalid, CartOperation.add);
    final milli = quantityMilliOf(quantity)!;
    if (_local != null || (_sale == null && _isOffline)) {
      // Phase 12B: weight sales are online only.
      if (sellingMode == 'WEIGHT' || milli % quantityUnit != 0) {
        return _rejectLocally(_weightNeedsServer, CartOperation.add);
      }
      return _addLocal(
        productVariationId,
        milli ~/ quantityUnit,
        label,
        imageUrl,
      );
    }

    return _run(CartOperation.add, null, () async {
      final sale = await _ensureSale();
      final updated = await _service.addItem(
        saleId: sale.id,
        productVariationId: productVariationId,
        // Exact: whole quantities stay ints (unchanged), decimals keep 3 places.
        quantity: quantityFromMilli(milli),
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
  Future<bool> updateQuantity(int itemId, num quantity) async {
    if (_op != null) return false;
    if (_local != null) {
      final m = quantityMilliOf(quantity);
      if (m == null || m % quantityUnit != 0) {
        final invalid = _validateQuantity(quantity);
        return _rejectLocally(invalid ?? _weightNeedsServer, CartOperation.update);
      }
      return _updateLocal(itemId, m ~/ quantityUnit);
    }
    final sale = _sale;
    final line = sale?.items.where((l) => l.id == itemId).firstOrNull;
    if (sale == null || line == null || !sale.isDraft) return false;
    // The LINE decides the rule: whole units, or a weight (Phase 12B).
    final invalid = _validateQuantity(quantity, line.sellingMode);
    if (invalid != null) return _rejectLocally(invalid, CartOperation.update);
    final milli = quantityMilliOf(quantity)!;
    if (line.quantityMilli == milli) return true;

    return _run(CartOperation.update, itemId, () async {
      return _service.updateItem(
        saleId: sale.id,
        itemId: itemId,
        quantity: quantityFromMilli(milli),
        expectedVersion: sale.version,
      );
    });
  }

  // ---- remove ----

  Future<bool> removeItem(int itemId) async {
    if (_op != null) return false;
    if (_local != null) return _updateLocal(itemId, 0);
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
    if (_local != null) {
      if (_local!.isEmpty) return false;
      _local = [];
      _localVersion++;
      _offlineAttempt = null;
      _notify();
      return true;
    }
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
    if (_local != null) {
      return _rejectLocally(holdOfflineMessage, CartOperation.hold);
    }
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
    if (_local != null && _local!.isNotEmpty) {
      return _rejectLocally(localCartOpenMessage, CartOperation.resume);
    }
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

  // ---- promotion ----

  /// True while an eligible promotion could meaningfully be applied — a
  /// draft sale must already exist (a promotion is evaluated against actual
  /// lines, and only a draft can be mutated).
  bool get canChoosePromotion => _sale != null && _sale!.isDraft && _op == null;

  /// Applies (or replaces) the sale's one promotion. The server recalculates
  /// the discount and totals; nothing discount-related is ever sent here.
  Future<bool> applyPromotion(int promotionId) async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.promotion, null, () async {
      return _service.applyPromotion(
        saleId: sale.id,
        promotionId: promotionId,
        expectedVersion: sale.version,
      );
    });
  }

  /// Removes the sale's promotion, if any.
  Future<bool> removePromotion() async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.promotion, null, () async {
      return _service.removePromotion(
        saleId: sale.id,
        expectedVersion: sale.version,
      );
    });
  }

  // ---- discount override ----
  //
  // EVERY manual discount is an override (discounts.override permission) —
  // there is no "normal discount" tier anywhere in this system. Whether the
  // action is shown at all is a UI-layer decision (SessionController.isDenied),
  // not this controller's — the backend remains the sole authority regardless.

  /// Same precondition as [canChoosePromotion] — a draft sale must already
  /// exist and no other mutation is in flight.
  bool get canChooseDiscount => _sale != null && _sale!.isDraft && _op == null;

  /// Applies (or replaces) the sale's manual discount override. The server
  /// recalculates the discount amount and totals; nothing beyond the
  /// cashier's typed type/value/reason is ever sent here.
  Future<bool> applyDiscountOverride({
    required String discountType,
    required String discountValue,
    String? reason,
  }) async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.discountOverride, null, () async {
      return _service.applyDiscountOverride(
        saleId: sale.id,
        discountType: discountType,
        discountValue: discountValue,
        reason: reason,
        expectedVersion: sale.version,
      );
    });
  }

  /// Removes the sale's discount override, if any.
  Future<bool> removeDiscountOverride() async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.discountOverride, null, () async {
      return _service.removeDiscountOverride(
        saleId: sale.id,
        expectedVersion: sale.version,
      );
    });
  }

  // ---- loyalty ----

  /// True while points/wallet redemption could meaningfully be requested —
  /// same precondition as [canChoosePromotion] (a draft sale must already
  /// exist) plus a customer must be on the sale (loyalty has no meaning for
  /// a guest checkout).
  bool get canChooseLoyalty =>
      _sale != null &&
      _sale!.isDraft &&
      _sale!.customerId != null &&
      _op == null;

  /// Redeems (or replaces) the sale's pending points redemption. `points: 0`
  /// clears it. The server recalculates the discount; nothing is sent here
  /// beyond the requested point count.
  Future<bool> redeemLoyaltyPoints(int points) async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.loyalty, null, () async {
      return _service.redeemLoyaltyPoints(
        saleId: sale.id,
        points: points,
        expectedVersion: sale.version,
      );
    });
  }

  /// Redeems (or replaces) the sale's pending wallet redemption. `amount: 0`
  /// clears it. Wallet does not change the sale total — it reduces what
  /// cash/card/other must cover at pay time (see [CartSale.loyalty]).
  Future<bool> redeemLoyaltyWallet(double amount) async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.loyalty, null, () async {
      return _service.redeemLoyaltyWallet(
        saleId: sale.id,
        amount: amount,
        expectedVersion: sale.version,
      );
    });
  }

  /// Clears any pending points/wallet redemption (the automatic tier
  /// discount, if any, is unaffected — it isn't something a cashier opts
  /// out of).
  Future<bool> removeLoyaltyRedemption() async {
    final sale = _sale;
    if (sale == null || _op != null) return false;
    return _run(CartOperation.loyalty, null, () async {
      return _service.removeLoyaltyRedemption(
        saleId: sale.id,
        expectedVersion: sale.version,
      );
    });
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
    if (_local != null) return _completeOffline(payments, null);
    if (_sale != null && _isOffline) {
      if (_onlineOutcomeUnknown) {
        return _rejectLocally(
          completionMayHaveReachedServerMessage,
          CartOperation.complete,
        );
      }
      return _completeOffline(payments, _sale);
    }
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
        onServerSaleCompleted?.call(sale.id);
        _sale = null; // the sale is done: the cart is empty again
        _pendingCustomerId = null;
        _pendingCustomerLabel = null;
        _attempt = null;
        _onlineOutcomeUnknown = false;
        _labels.clear();
        _images.clear();
      },
    );
  }

  // ---- offline completion ----

  static const String _offlineUnavailable =
      'Offline sales are not available on this device.';

  /// Records the sale on this device: the local cart, or the server draft
  /// [draft] when the connection dropped before it was paid. The cart is
  /// cleared ONLY once the sale and its queue entry are safely stored; a
  /// storage failure keeps the cart and the same local sale id, so a retry
  /// finishes the same save instead of creating a second sale.
  Future<bool> _completeOffline(
    List<PaymentLine> payments,
    CartSale? draft,
  ) async {
    final support = offline;
    if (support == null) {
      return _rejectLocally(_offlineUnavailable, CartOperation.complete);
    }
    final lines = draft == null ? List.of(_local!) : _linesFromDraft(draft);
    if (lines == null) {
      return _rejectLocally(
        OfflineCheckoutService.totalsMessage,
        CartOperation.complete,
      );
    }
    if (lines.isEmpty || payments.isEmpty) {
      return _rejectLocally(emptyCompleteMessage, CartOperation.complete);
    }

    final fingerprint = [
      draft?.id ?? 'local',
      for (final l in lines)
        '${l.productVariationId}x${l.quantity}@${l.unitPriceMilli}',
      ...(payments.map((p) => p.canonical).toList()..sort()),
    ].join('|');
    if (_offlineAttempt == null ||
        _offlineAttempt!.fingerprint != fingerprint) {
      _offlineAttempt = _CompletionAttempt(generateUuidV4(), fingerprint);
    }
    final attempt = _offlineAttempt!;
    final customerId = draft != null ? draft.customerId : _pendingCustomerId;
    final request = OfflineCheckoutRequest(
      localSaleId: attempt.key,
      scope: support.scope(),
      staffName: support.staffName?.call(),
      lines: lines,
      payments: payments,
      customerId: customerId,
      customerName: customerId == null ? null : _pendingCustomerLabel,
      sourceDraftSaleId: draft?.id,
      serverDiscountsApplied: draft != null && _hasServerDiscounts(draft),
    );

    _op = CartOperation.complete;
    _step = CartOperation.complete;
    _error = null;
    _errorOp = null;
    _notify();
    try {
      final saved = await support.checkout.complete(request);
      _completedOffline = saved;
      _completed = null;
      _local = null;
      _sale = null; // a server draft stays a draft; it is never completed
      _pendingCustomerId = null;
      _pendingCustomerLabel = null;
      _offlineAttempt = null;
      _attempt = null;
      _labels.clear();
      _images.clear();
      support.onOfflineSaleRecorded?.call(saved);
      return true;
    } on OfflineCheckoutRejected catch (e) {
      _offlineAttempt = null; // nothing was written
      _error = ApiException(kind: ApiErrorKind.validation, message: e.message);
      _errorOp = CartOperation.complete;
      return false;
    } on OfflineCheckoutStorageFailure {
      _error = const ApiException(
        kind: ApiErrorKind.unknown,
        message: OfflineCheckoutService.storageFailureMessage,
      );
      _errorOp = CartOperation.complete;
      return false;
    } finally {
      _op = null;
      _step = null;
      _notify();
    }
  }

  /// The server draft's lines as offline lines, or null when a line has no
  /// usable price (unavailable item) — such a cart cannot be paid offline.
  List<OfflineCheckoutLine>? _linesFromDraft(CartSale draft) {
    if (draft.hasUnavailableItems) return null;
    final out = <OfflineCheckoutLine>[];
    for (final l in draft.items) {
      final price = l.unitPrice;
      final tax = l.taxAmount;
      final total = l.lineTotal;
      if (price == null || tax == null || total == null || l.isUnavailable) {
        return null;
      }
      // Phase 12B: weight sales are online only — a sale with a weighed (or
      // any non-whole) line cannot continue offline.
      if (l.isWeight || l.quantityMilli % quantityUnit != 0) return null;
      out.add(
        OfflineCheckoutLine(
          productVariationId: l.productVariationId,
          productName: l.productName ?? 'Item ${l.productVariationId}',
          variationName: _labels[l.productVariationId],
          quantity: l.quantityMilli ~/ quantityUnit,
          unitPriceMilli: milliFromDouble(price),
          taxPercent: l.taxPercent ?? 0,
          taxMode: l.taxIncluded == true ? 'inclusive' : 'exclusive',
          taxAmountMilli: milliFromDouble(tax),
          discountAmountMilli: milliFromDouble(l.discountAmount ?? 0),
          lineTotalMilli: milliFromDouble(total),
        ),
      );
    }
    return out;
  }

  /// Promotion, loyalty (tier discount / points / wallet) or a manual
  /// discount override: all evaluated by the server only.
  static bool _hasServerDiscounts(CartSale draft) {
    final loyalty = draft.loyalty;
    return draft.promotion != null ||
        draft.discountOverride != null ||
        (draft.totals.discountTotal ?? 0) != 0 ||
        (loyalty != null &&
            (loyalty.tierDiscountAmount != 0 ||
                loyalty.pointsRedeemed != 0 ||
                loyalty.walletRedeemed != 0));
  }

  /// Forget the offline sale after the cashier dismisses the success view.
  void acknowledgeOfflineCompletion() {
    if (_completedOffline == null) return;
    _completedOffline = null;
    _notify();
  }

  // ---- local cart editing ----

  Future<bool> _addLocal(
    int productVariationId,
    int quantity,
    String? label,
    String? imageUrl,
  ) async {
    final support = offline;
    if (support == null) {
      return _rejectLocally(_offlineUnavailable, CartOperation.add);
    }
    _op = CartOperation.add;
    _error = null;
    _errorOp = null;
    _notify();
    try {
      final product = await support.checkout.storage.getProduct(
        productVariationId,
      );
      if (product == null) {
        return _rejectLocally(
          OfflineCheckoutService.notInCatalogueMessage(label ?? 'This product'),
          CartOperation.add,
        );
      }
      if (!product.isPosSellable) {
        return _rejectLocally(
          OfflineCheckoutService.notSellableMessage(product.productName),
          CartOperation.add,
        );
      }
      final lines = _local ?? <OfflineCheckoutLine>[];
      final i = lines.indexWhere(
        (l) => l.productVariationId == productVariationId,
      );
      final next = (i < 0 ? 0 : lines[i].quantity) + quantity;
      final invalid = _validateQuantity(next);
      if (invalid != null) return _rejectLocally(invalid, CartOperation.add);
      final stockProblem = await _localStockProblem(
        productVariationId,
        product.productName,
        next,
      );
      if (stockProblem != null) {
        return _rejectLocally(stockProblem, CartOperation.add);
      }
      // The price the cashier sees is fixed when the item is first added.
      final line = i < 0
          ? OfflineCheckoutLine.fromProduct(product, next)
          : lines[i].withQuantity(next);
      if (i < 0) {
        lines.add(line);
      } else {
        lines[i] = line;
      }
      _local = lines;
      _localVersion++;
      _offlineAttempt = null;
      if (label != null && label.trim().isNotEmpty) {
        _labels[productVariationId] = label.trim();
      }
      if (imageUrl != null && imageUrl.isNotEmpty) {
        _images[productVariationId] = imageUrl;
      }
      return true;
    } catch (_) {
      return _rejectLocally(
        'Offline data on this device could not be read.',
        CartOperation.add,
      );
    } finally {
      _op = null;
      _notify();
    }
  }

  Future<bool> _updateLocal(int productVariationId, int quantity) async {
    final lines = _local!;
    final i = lines.indexWhere(
      (l) => l.productVariationId == productVariationId,
    );
    if (i < 0) return false;
    if (quantity == 0) {
      lines.removeAt(i);
    } else {
      final invalid = _validateQuantity(quantity);
      if (invalid != null) {
        return _rejectLocally(invalid, CartOperation.update);
      }
      if (quantity == lines[i].quantity) return true;
      if (quantity > lines[i].quantity) {
        final problem = await _localStockProblem(
          productVariationId,
          lines[i].productName,
          quantity,
        );
        if (problem != null) {
          return _rejectLocally(problem, CartOperation.update);
        }
      }
      lines[i] = lines[i].withQuantity(quantity);
    }
    _localVersion++;
    _offlineAttempt = null;
    _error = null;
    _errorOp = null;
    _notify();
    return true;
  }

  /// Early feedback while building a local cart (the authoritative check runs
  /// again when the sale is completed).
  Future<String?> _localStockProblem(int id, String name, int wanted) async {
    final levels = await offline!.checkout.storage.getStockLevels();
    final level = levels[id];
    if (level == null) return OfflineCheckoutService.noStockInfoMessage(name);
    if (wanted > level.availableQuantity) {
      return OfflineCheckoutService.insufficientStockMessage(
        name,
        level.serverQuantity,
        level.availableQuantity < 0 ? 0 : level.availableQuantity,
      );
    }
    return null;
  }

  CartSale _localView() {
    final lines = _local!;
    double m(int milli) => milli / 1000;
    final subtotal = lines.fold<int>(0, (s, l) => s + l.listedAmountMilli);
    final tax = lines.fold<int>(0, (s, l) => s + l.taxAmountMilli);
    final grand = lines.fold<int>(0, (s, l) => s + l.lineTotalMilli);
    return CartSale(
      id: 0,
      version: _localVersion,
      status: 'draft',
      isLocal: true,
      customerId: _pendingCustomerId,
      items: [
        for (final l in lines)
          CartLine(
            id: l.productVariationId,
            productVariationId: l.productVariationId,
            quantity: l.quantity,
            productName: l.productName,
            availabilityStatus: 'available',
            unitPrice: m(l.unitPriceMilli),
            taxPercent: l.taxPercent,
            taxAmount: m(l.taxAmountMilli),
            taxIncluded: l.taxMode == 'inclusive',
            discountAmount: 0,
            lineTotal: m(l.lineTotalMilli),
          ),
      ],
      totals: CartTotals(
        subtotal: m(subtotal),
        taxTotal: m(tax),
        discountTotal: 0,
        grandTotal: m(grand),
      ),
    );
  }

  // ---- payment recovery (Phase 6) ----

  /// Puts a server draft found by payment recovery back into the cart. Only
  /// into an EMPTY cart (or the same sale): two drafts are never mixed, and
  /// a cart being edited is never replaced. Nothing is sent to the server —
  /// the draft is exactly as the server holds it.
  bool restoreRecoveredSale(CartSale sale) {
    if (_op != null || _local != null || sale.isLocal || !sale.isDraft) {
      return false;
    }
    final current = _sale;
    if (current != null && current.id != sale.id && current.items.isNotEmpty) {
      return false;
    }
    _sale = sale;
    _error = null;
    _errorOp = null;
    _attempt = null;
    _onlineOutcomeUnknown = false;
    _completed = null;
    _notify();
    return true;
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
    if (_local != null) {
      // Nothing was saved for a local cart until it is paid: voiding it just
      // discards the lines on this device.
      _local = null;
      _localVersion++;
      _offlineAttempt = null;
      _pendingCustomerId = null;
      _pendingCustomerLabel = null;
      _labels.clear();
      _images.clear();
      _notify();
      return true;
    }
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
    _local = null;
    _localVersion++;
    _offlineAttempt = null;
    _completedOffline = null;
    _onlineOutcomeUnknown = false;
    _notify();
  }

  // ---- internals ----

  /// Phase 12B: PIECE = whole units (message unchanged); WEIGHT = a positive
  /// decimal with at most 3 places. Invalid input is refused, never rounded.
  String? _validateQuantity(num q, [String sellingMode = 'PIECE']) =>
      quantityError(sellingMode, q);

  static const _weightNeedsServer =
      'Sales by weight need a connection to the server.';

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
      if (op == CartOperation.complete) _onlineOutcomeUnknown = e.isRetryable;
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
      case CartOperation.promotion:
      case CartOperation.loyalty:
      case CartOperation.discountOverride:
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
    offline?.onServerSale?.call(incoming);
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
