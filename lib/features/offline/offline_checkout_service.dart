import '../auth/models/pos_token_scope.dart';
import '../cart/models/cart_sale.dart';
import '../checkout/models/payment.dart';
import 'models/offline_catalogue.dart';
import 'models/offline_context.dart';
import 'models/offline_sale.dart';
import 'offline_payment_policy.dart';
import 'offline_storage_service.dart';
import 'pos_tax.dart';

/// One line of a sale about to be completed offline, carrying the figures the
/// cashier saw (price, tax, discount, line total). They are re-checked
/// against the ported server tax rule before anything is saved.
class OfflineCheckoutLine {
  const OfflineCheckoutLine({
    required this.productVariationId,
    required this.productName,
    required this.quantity,
    required this.unitPriceMilli,
    required this.taxPercent,
    required this.taxMode,
    required this.taxAmountMilli,
    required this.lineTotalMilli,
    this.discountAmountMilli = 0,
    this.variationName,
  });

  final int productVariationId;
  final String productName;
  final String? variationName;
  final int quantity;
  final int unitPriceMilli;
  final double taxPercent;
  final String taxMode;
  final int taxAmountMilli;
  final int discountAmountMilli;
  final int lineTotalMilli;

  /// A line priced on this device from a cached product (the snapshot the
  /// cashier sees in a local cart).
  static OfflineCheckoutLine fromProduct(OfflineProduct p, int quantity) {
    final t = PosTax.computeLine(
      unitPriceMilli: p.sellPriceMilli,
      quantity: quantity,
      percent: p.taxPercent,
      mode: p.taxMode,
    );
    return OfflineCheckoutLine(
      productVariationId: p.productVariationId,
      productName: p.productName,
      variationName: p.variationName,
      quantity: quantity,
      unitPriceMilli: p.sellPriceMilli,
      taxPercent: t.percent,
      taxMode: t.mode,
      taxAmountMilli: t.taxMilli,
      lineTotalMilli: t.totalMilli,
    );
  }

  OfflineCheckoutLine withQuantity(int quantity) {
    final t = PosTax.computeLine(
      unitPriceMilli: unitPriceMilli,
      quantity: quantity,
      percent: taxPercent,
      mode: taxMode,
    );
    return OfflineCheckoutLine(
      productVariationId: productVariationId,
      productName: productName,
      variationName: variationName,
      quantity: quantity,
      unitPriceMilli: unitPriceMilli,
      taxPercent: t.percent,
      taxMode: t.mode,
      taxAmountMilli: t.taxMilli,
      lineTotalMilli: t.totalMilli,
    );
  }

  int get listedAmountMilli => unitPriceMilli * quantity;
}

/// Everything needed to record one offline sale.
class OfflineCheckoutRequest {
  const OfflineCheckoutRequest({
    required this.localSaleId,
    required this.scope,
    required this.lines,
    required this.payments,
    this.staffName,
    this.customerId,
    this.customerName,
    this.sourceDraftSaleId,
    this.serverDiscountsApplied = false,
  });

  /// UUID v4 generated for this checkout attempt — the sale's identity.
  final String localSaleId;

  /// The signed-in staff session's scope (null = not signed in).
  final PosTokenScope? scope;
  final String? staffName;
  final List<OfflineCheckoutLine> lines;
  final List<PaymentLine> payments;
  final String? customerId;
  final String? customerName;

  /// The server draft the cart was built in (cart started online).
  final int? sourceDraftSaleId;

  /// True when the cart carries a promotion, loyalty discount/redemption or
  /// manual discount override — all evaluated by the server only.
  final bool serverDiscountsApplied;
}

/// A sale refused BEFORE anything was written (nothing saved, nothing
/// queued). [message] is cashier-facing.
class OfflineCheckoutRejected implements Exception {
  const OfflineCheckoutRejected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Saving on this device failed. The sale may be partly written (the sale
/// file without its queue entry); retrying with the SAME local sale id
/// finishes it via [OfflineStorageService.finishInterruptedSale], and app
/// start-up recovery repairs it too. Never reported as completed.
class OfflineCheckoutStorageFailure implements Exception {
  const OfflineCheckoutStorageFailure(this.cause);
  final Object cause;
  @override
  String toString() => OfflineCheckoutService.storageFailureMessage;
}

/// Completes sales on this device while the server cannot be reached.
///
/// Every check runs BEFORE anything is written (eligibility rules 1–15 of
/// the offline checkout spec): staff session; stored shift present, OPEN and
/// matching the session's company/store/register/device; non-empty cart;
/// every product in the offline catalogue and PIECE-sellable; whole positive
/// quantities; enough OFFLINE stock (last server stock minus unsynced local
/// sales); every payment allowed offline; no server-only discounts; every
/// line's tax and total equal to the ported server tax rule; totals and
/// payments consistent. Then the sale is recorded through
/// [OfflineStorageService.recordCompletedSale] (sale file -> queue entry ->
/// QUEUED; start-up recovery covers a crash in between).
///
/// Nothing here talks to the server, and nothing marks a sale synced.
class OfflineCheckoutService {
  OfflineCheckoutService(this.storage, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final OfflineStorageService storage;
  final DateTime Function() _clock;

  /// Completions run one at a time, so two sales can never both pass the
  /// stock check for the same last units.
  Future<void>? _tail;

  static const noSessionMessage =
      'Sign in again before making an offline sale.';
  static const noShiftMessage = 'Open a shift before making an offline sale.';
  static const shiftClosedMessage =
      'The shift stored on this device is closed. Open a shift before making an offline sale.';
  static const scopeMismatchMessage =
      'The shift stored on this device belongs to a different store, register or device. Reconnect to continue.';
  static const emptyCartMessage =
      'Add at least one item before taking payment.';
  static const invalidQuantityMessage =
      'Quantities must be whole numbers greater than zero.';
  static const serverDiscountsMessage =
      'Promotions, loyalty and manual discounts need an internet connection. Reconnect to complete this sale.';
  static const totalsMessage =
      'The sale totals could not be verified on this device. Reconnect to complete this sale.';
  static const paymentTotalMessage =
      'The payments do not add up to the sale total.';
  static const customerNotCachedMessage =
      'This customer is not available offline. Remove the customer or reconnect.';
  static const storageFailureMessage =
      'Unable to save the sale on this device. Please do not leave this screen and contact support.';

  static String notInCatalogueMessage(String name) =>
      '"$name" is not available offline. Reconnect to sell it.';
  static String notSellableMessage(String name) =>
      '"$name" cannot be sold at the POS (only items sold by the piece can be sold offline).';
  static String noStockInfoMessage(String name) =>
      'No offline stock information for "$name". Reconnect to refresh stock.';
  static String insufficientStockMessage(
    String name,
    double server,
    double available,
  ) =>
      'Insufficient offline stock for "$name". Last server stock: ${_qty(server)}. '
      'Available offline stock: ${_qty(available)}.';

  static String _qty(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  /// Validates and records the sale. Throws [OfflineCheckoutRejected]
  /// (nothing written) or [OfflineCheckoutStorageFailure] (see its doc).
  Future<OfflineSale> complete(OfflineCheckoutRequest request) {
    final previous = _tail;
    final run = previous == null
        ? _complete(request)
        : previous.then((_) => _complete(request));
    _tail = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  Future<OfflineSale> _complete(OfflineCheckoutRequest r) async {
    // A previous attempt with this id may have written the sale file before
    // failing: finish that save instead of recording it a second time.
    final OfflineSale? already;
    try {
      already = await storage.finishInterruptedSale(r.localSaleId);
    } catch (e) {
      throw OfflineCheckoutStorageFailure(e);
    }
    if (already != null) return already;

    final sale = await _build(r);
    try {
      return await storage.recordCompletedSale(sale);
    } on OfflinePaymentNotAllowed catch (e) {
      throw OfflineCheckoutRejected(e.message);
    } catch (e) {
      throw OfflineCheckoutStorageFailure(e);
    }
  }

  /// Runs every eligibility check and builds the COMPLETED_LOCAL sale.
  /// Throws [OfflineCheckoutRejected]; writes nothing.
  Future<OfflineSale> _build(OfflineCheckoutRequest r) async {
    final scope = r.scope;
    if (scope == null) throw const OfflineCheckoutRejected(noSessionMessage);

    final shift = await _read(storage.getCurrentShift);
    if (shift == null) throw const OfflineCheckoutRejected(noShiftMessage);
    if (!shift.isOpen) throw const OfflineCheckoutRejected(shiftClosedMessage);
    if (!_sameScope(shift, scope)) {
      throw const OfflineCheckoutRejected(scopeMismatchMessage);
    }

    if (r.lines.isEmpty) throw const OfflineCheckoutRejected(emptyCartMessage);
    if (r.serverDiscountsApplied) {
      throw const OfflineCheckoutRejected(serverDiscountsMessage);
    }

    final wanted = <int, int>{};
    for (final l in r.lines) {
      if (l.quantity <= 0) {
        throw const OfflineCheckoutRejected(invalidQuantityMessage);
      }
      final p = await _read(() => storage.getProduct(l.productVariationId));
      if (p == null) {
        throw OfflineCheckoutRejected(notInCatalogueMessage(l.productName));
      }
      if (!p.isPosSellable) {
        throw OfflineCheckoutRejected(notSellableMessage(l.productName));
      }
      if (l.unitPriceMilli < 0 || l.discountAmountMilli != 0) {
        throw const OfflineCheckoutRejected(totalsMessage);
      }
      // The figures shown must be exactly what the server's tax rule gives.
      final t = PosTax.computeLine(
        unitPriceMilli: l.unitPriceMilli,
        quantity: l.quantity,
        percent: l.taxPercent,
        mode: l.taxMode,
      );
      if (t.taxMilli != l.taxAmountMilli || t.totalMilli != l.lineTotalMilli) {
        throw const OfflineCheckoutRejected(totalsMessage);
      }
      wanted[l.productVariationId] =
          (wanted[l.productVariationId] ?? 0) + l.quantity;
    }

    final stock = await _read(storage.getStockLevels);
    for (final e in wanted.entries) {
      final name = r.lines
          .firstWhere((l) => l.productVariationId == e.key)
          .productName;
      final level = stock[e.key];
      if (level == null) {
        throw OfflineCheckoutRejected(noStockInfoMessage(name));
      }
      if (e.value > level.availableQuantity) {
        throw OfflineCheckoutRejected(
          insufficientStockMessage(
            name,
            level.serverQuantity,
            level.availableQuantity < 0 ? 0 : level.availableQuantity,
          ),
        );
      }
    }

    if (r.customerId != null) {
      final c = await _read(() => storage.getCustomer(r.customerId!));
      if (c == null) {
        throw const OfflineCheckoutRejected(customerNotCachedMessage);
      }
    }

    final subtotal = r.lines.fold<int>(0, (s, l) => s + l.listedAmountMilli);
    final tax = r.lines.fold<int>(0, (s, l) => s + l.taxAmountMilli);
    final grand = r.lines.fold<int>(0, (s, l) => s + l.lineTotalMilli);

    final policy = OfflinePaymentPolicy(await _read(storage.getSettings));
    final payments = <OfflinePayment>[];
    for (final p in r.payments) {
      final problem = policy.check(
        method: p.method.wire,
        provider: p.paymentAttemptId == null ? 'NONE' : 'PROVIDER',
      );
      if (problem != null) throw OfflineCheckoutRejected(problem);
      if (p.amountMilli <= 0) {
        throw const OfflineCheckoutRejected(paymentTotalMessage);
      }
      int? change;
      if (p.method == TenderMethod.cash && p.tenderedMilli != null) {
        if (p.tenderedMilli! < p.amountMilli) {
          throw const OfflineCheckoutRejected(paymentTotalMessage);
        }
        change = p.tenderedMilli! - p.amountMilli;
      }
      final ref = p.reference?.trim();
      payments.add(
        OfflinePayment(
          method: p.method.wire,
          amountMilli: p.amountMilli,
          tenderedMilli: p.method == TenderMethod.cash ? p.tenderedMilli : null,
          changeMilli: change,
          reference: (ref == null || ref.isEmpty) ? null : ref,
        ),
      );
    }
    if (payments.fold<int>(0, (s, p) => s + p.amountMilli) != grand) {
      throw const OfflineCheckoutRejected(paymentTotalMessage);
    }

    final device = await _read(storage.getOrCreateDeviceInfo);
    final now = _clock().toUtc();
    final sale = OfflineSale(
      localSaleId: r.localSaleId,
      status: OfflineSaleStatus.completedLocal,
      companyId: scope.companyId,
      storeId: scope.storeId,
      registerId: scope.registerId,
      deviceId: scope.deviceId,
      shiftId: shift.shiftId,
      salesmanId: scope.salesmanId,
      salesmanName: r.staffName,
      installationId: device.installationId,
      customerId: r.customerId,
      customerName: r.customerName,
      currency: shift.currency,
      createdAt: now,
      updatedAt: now,
      completedAt: now,
      sourceDraftSaleId: r.sourceDraftSaleId,
      lines: [
        for (final l in r.lines)
          OfflineSaleLine(
            productVariationId: l.productVariationId,
            productName: l.productName,
            variationName: l.variationName,
            quantity: l.quantity,
            unitPriceMilli: l.unitPriceMilli,
            taxPercent: l.taxPercent,
            taxMode: l.taxMode,
            taxAmountMilli: l.taxAmountMilli,
            discountAmountMilli: l.discountAmountMilli,
            lineTotalMilli: l.lineTotalMilli,
          ),
      ],
      payments: payments,
      subtotalMilli: subtotal,
      taxTotalMilli: tax,
      discountTotalMilli: 0,
      grandTotalMilli: grand,
    );
    if (sale.validateCompleted() != null) {
      throw const OfflineCheckoutRejected(totalsMessage);
    }
    return sale;
  }

  bool _sameScope(OfflineShiftContext shift, PosTokenScope scope) =>
      shift.companyId == scope.companyId &&
      shift.storeId == scope.storeId &&
      shift.registerId == scope.registerId &&
      (shift.deviceId == null || shift.deviceId == scope.deviceId);

  /// Reads that fail (unreadable cache, I/O) are a reason to refuse the sale,
  /// not to crash checkout: nothing has been written yet.
  Future<T> _read<T>(Future<T> Function() read) async {
    try {
      return await read();
    } catch (_) {
      throw const OfflineCheckoutRejected(
        'Offline data on this device could not be read. Reconnect to complete this sale.',
      );
    }
  }
}

/// What the cart needs to offer offline checkout. Everything is read lazily
/// at the moment it is needed, so connectivity and the session are always
/// current.
class OfflineCartSupport {
  const OfflineCartSupport({
    required this.checkout,
    required this.isOffline,
    required this.scope,
    this.staffName,
    this.onServerSale,
    this.onOfflineSaleRecorded,
  });

  final OfflineCheckoutService checkout;

  /// True only when the server is known to be unreachable
  /// (`PosApiClient.reachable == false`); unknown is not offline.
  final bool Function() isOffline;
  final PosTokenScope? Function() scope;
  final String? Function()? staffName;

  /// Every server sale view the cart applies (lets the shift context on this
  /// device follow the server's shift id).
  final void Function(CartSale sale)? onServerSale;
  final void Function(OfflineSale sale)? onOfflineSaleRecorded;
}
