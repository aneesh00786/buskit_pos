import '../../../core/utils/json_read.dart';

/// Lifecycle of a sale created while offline.
///
///   draft          being built on this device (not yet paid); may be cancelled
///   completedLocal paid and stored on THIS device only — NOT server-confirmed
///   queued         its queue entry exists; waiting for a future sync
///   syncing        a sync attempt is in progress
///   syncFailed     the server rejected the sale; kept for review, retried
///                  only when the cashier asks
///   synced         the SERVER confirmed it (has a server_sale_id)
///   cancelled      a draft abandoned before payment (never sent anywhere)
///
/// Only [synced] means server-confirmed. Every other state must be shown as
/// "saved on this device".
enum OfflineSaleStatus {
  draft('DRAFT'),
  completedLocal('COMPLETED_LOCAL'),
  queued('QUEUED'),
  syncing('SYNCING'),
  syncFailed('SYNC_FAILED'),
  synced('SYNCED'),
  cancelled('CANCELLED');

  const OfflineSaleStatus(this.wire);
  final String wire;

  static OfflineSaleStatus? fromWire(String? s) {
    for (final v in values) {
      if (v.wire == s) return v;
    }
    return null;
  }

  static const _next = {
    OfflineSaleStatus.draft: {
      OfflineSaleStatus.completedLocal,
      OfflineSaleStatus.cancelled,
    },
    OfflineSaleStatus.completedLocal: {OfflineSaleStatus.queued},
    OfflineSaleStatus.queued: {OfflineSaleStatus.syncing},
    // A crash mid-sync leaves `syncing`: it may go back to queued for a retry.
    OfflineSaleStatus.syncing: {
      OfflineSaleStatus.synced,
      OfflineSaleStatus.syncFailed,
      OfflineSaleStatus.queued,
    },
    OfflineSaleStatus.syncFailed: {OfflineSaleStatus.queued},
    OfflineSaleStatus.synced: <OfflineSaleStatus>{},
    OfflineSaleStatus.cancelled: <OfflineSaleStatus>{},
  };

  bool canMoveTo(OfflineSaleStatus to) => _next[this]!.contains(to);

  /// Paid on this device and not yet confirmed by the server: these count
  /// against offline stock and must never be lost.
  bool get isUnsynced =>
      this == completedLocal ||
      this == queued ||
      this == syncing ||
      this == syncFailed;

  /// Cashier-facing description; never claims server confirmation unless synced.
  String get label => switch (this) {
    draft => 'Draft',
    completedLocal || queued => 'Saved on this device — not yet synced',
    syncing => 'Syncing…',
    syncFailed => 'Sync failed',
    synced => 'Synced',
    cancelled => 'Cancelled',
  };
}

/// One sale line with the price and tax used AT SALE TIME (never recomputed
/// later from products.json). Money in integer thousandths ("milli"), the
/// same unit and fields as the server's completed-sale snapshot
/// (pos_sale_items unit_price / tax_rate / tax_included / tax_amount /
/// discount_amount / line_total) plus the tax mode the server derived them
/// from.
class OfflineSaleLine {
  const OfflineSaleLine({
    required this.productVariationId,
    required this.productName,
    required this.quantity,
    required this.unitPriceMilli,
    required this.taxPercent,
    required this.taxMode,
    required this.taxAmountMilli,
    required this.lineTotalMilli,
    this.variationName,
    this.discountAmountMilli = 0,
  });

  final int productVariationId;
  final String productName;
  final String? variationName;

  /// Whole pieces only (PIECE selling; WEIGHT stays unsupported).
  final int quantity;
  final int unitPriceMilli;
  final double taxPercent;

  /// 'inclusive' | 'exclusive' | 'none'.
  final String taxMode;
  final int taxAmountMilli;
  final int discountAmountMilli;
  final int lineTotalMilli;

  bool get taxIncluded => taxMode == 'inclusive';
  int get listedAmountMilli => unitPriceMilli * quantity;

  Map<String, dynamic> toJson() => {
    'product_variation_id': productVariationId,
    'product_name': productName,
    'variation_name': variationName,
    'quantity': quantity,
    'unit_price_milli': unitPriceMilli,
    'tax_percent': taxPercent,
    'tax_mode': taxMode,
    'tax_included': taxIncluded,
    'tax_amount_milli': taxAmountMilli,
    'discount_amount_milli': discountAmountMilli,
    'line_total_milli': lineTotalMilli,
  };

  static OfflineSaleLine? fromJson(Object? json) {
    final m = asMap(json);
    if (m == null) return null;
    final id = asInt(m['product_variation_id']);
    final name = asString(m['product_name']);
    final qty = asInt(m['quantity']);
    final unit = asInt(m['unit_price_milli']);
    final tax = asInt(m['tax_amount_milli']);
    final total = asInt(m['line_total_milli']);
    final mode = asString(m['tax_mode']);
    if (id == null ||
        name == null ||
        qty == null ||
        unit == null ||
        tax == null ||
        total == null ||
        mode == null) {
      return null;
    }
    return OfflineSaleLine(
      productVariationId: id,
      productName: name,
      variationName: asString(m['variation_name']),
      quantity: qty,
      unitPriceMilli: unit,
      taxPercent: asDouble(m['tax_percent']) ?? 0,
      taxMode: mode,
      taxAmountMilli: tax,
      discountAmountMilli: asInt(m['discount_amount_milli']) ?? 0,
      lineTotalMilli: total,
    );
  }
}

/// A tender taken offline. Always a recorded tender with no provider
/// (provider NONE): cash, or a manual card/other explicitly approved for
/// offline use. Never a provider payment, never "captured".
class OfflinePayment {
  const OfflinePayment({
    required this.method,
    required this.amountMilli,
    this.tenderedMilli,
    this.changeMilli,
    this.reference,
  });

  /// Existing tender methods: 'cash' | 'card' | 'other'.
  final String method;
  final int amountMilli;
  final int? tenderedMilli;
  final int? changeMilli;
  final String? reference;

  static const provider = 'NONE';

  Map<String, dynamic> toJson() => {
    'method': method,
    'provider': provider,
    'amount_milli': amountMilli,
    'tendered_milli': tenderedMilli,
    'change_milli': changeMilli,
    'reference': reference,
  };

  static OfflinePayment? fromJson(Object? json) {
    final m = asMap(json);
    final method = asString(m?['method']);
    final amount = asInt(m?['amount_milli']);
    if (m == null ||
        method == null ||
        amount == null ||
        (asString(m['provider']) ?? 'NONE') != 'NONE') {
      return null;
    }
    return OfflinePayment(
      method: method,
      amountMilli: amount,
      tenderedMilli: asInt(m['tendered_milli']),
      changeMilli: asInt(m['change_milli']),
      reference: asString(m['reference']),
    );
  }
}

/// A sale created on this device while offline (`sales/<local_sale_id>.json`).
///
/// [localSaleId] is a UUID v4 created on the device: the sale's identity
/// everywhere, and the idempotency key a future sync must send so a retried
/// upload can never create a second server sale. [serverSaleId] stays null
/// until the server confirms the sale.
class OfflineSale {
  const OfflineSale({
    required this.localSaleId,
    required this.status,
    required this.companyId,
    required this.storeId,
    required this.registerId,
    required this.shiftId,
    required this.salesmanId,
    required this.installationId,
    required this.createdAt,
    required this.updatedAt,
    required this.lines,
    required this.payments,
    required this.subtotalMilli,
    required this.taxTotalMilli,
    required this.discountTotalMilli,
    required this.grandTotalMilli,
    this.serverSaleId,
    this.deviceId,
    this.customerId,
    this.currency,
    this.completedAt,
    this.lastError,
    this.sourceDraftSaleId,
    this.salesmanName,
    this.customerName,
    this.lastErrorCode,
    this.syncedAt,
    this.serverSaleNumber,
    this.resolvedBy,
    this.resolvedAt,
    this.resolutionReason,
  });

  final String localSaleId;
  final int? serverSaleId;
  final OfflineSaleStatus status;
  final int companyId;
  final int storeId;
  final int registerId;
  final int? deviceId;
  final int shiftId;
  final String salesmanId;
  final String installationId;
  final String? customerId;
  final String? currency;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
  final List<OfflineSaleLine> lines;
  final List<OfflinePayment> payments;

  /// Server semantics: sum of listed prices (gross for inclusive lines).
  final int subtotalMilli;
  final int taxTotalMilli;
  final int discountTotalMilli;
  final int grandTotalMilli;
  final String? lastError;

  /// The server DRAFT this sale was built in when the cart was started online
  /// and paid after the connection dropped (null for a cart started offline).
  /// That draft was never completed on the server; a future sync must cancel
  /// (or otherwise retire) it so it can never be completed a second time.
  final int? sourceDraftSaleId;

  /// Display-only names captured at checkout (the ids are authoritative).
  final String? salesmanName;
  final String? customerName;

  /// Machine code of the last sync rejection (e.g. OFFLINE_STOCK_CONFLICT);
  /// [lastError] holds the cashier-facing message.
  final String? lastErrorCode;

  /// When this device recorded the server's confirmation (device clock).
  final DateTime? syncedAt;

  /// The server's sale number (e.g. POS-00000042) once synced.
  final String? serverSaleNumber;

  /// Set when a manager resolved this sale (Phase 4): who authorized the sync,
  /// when, and why. The sale itself stays attributed to [salesmanId] and
  /// [shiftId] — the resolver never replaces the original cashier.
  final String? resolvedBy;
  final DateTime? resolvedAt;
  final String? resolutionReason;

  /// Short cashier-facing reference derived from [localSaleId] (the full
  /// UUID stays the authoritative id): `LOCAL-` + its first 8 hex digits.
  String get displayReference => displayReferenceFor(localSaleId);

  static String displayReferenceFor(String localSaleId) =>
      'LOCAL-${localSaleId.replaceAll('-', '').substring(0, 8).toUpperCase()}';

  static final idPattern = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  );

  /// Problems that make the sale unsafe to keep as COMPLETED_LOCAL, or null.
  String? validateCompleted() {
    if (!idPattern.hasMatch(localSaleId)) {
      return 'local_sale_id must be a UUID v4';
    }
    if (lines.isEmpty) return 'a sale needs at least one line';
    for (final l in lines) {
      if (l.quantity <= 0) return 'quantities must be whole and positive';
      if (l.unitPriceMilli < 0 ||
          l.taxAmountMilli < 0 ||
          l.discountAmountMilli < 0 ||
          l.lineTotalMilli < 0) {
        return 'amounts cannot be negative';
      }
      if (l.discountAmountMilli > l.listedAmountMilli) {
        return 'a line discount cannot exceed the line amount';
      }
      // Server line semantics: inclusive lines charge the (discounted) listed
      // amount with the tax inside it; other lines add the tax on top.
      final net = l.listedAmountMilli - l.discountAmountMilli;
      final expected = l.taxIncluded ? net : net + l.taxAmountMilli;
      if (l.lineTotalMilli != expected) {
        return 'line total does not match price, quantity, discount and tax';
      }
    }
    if (subtotalMilli !=
        lines.fold<int>(0, (s, l) => s + l.listedAmountMilli)) {
      return 'subtotal does not match the lines';
    }
    if (taxTotalMilli != lines.fold<int>(0, (s, l) => s + l.taxAmountMilli)) {
      return 'tax total does not match the lines';
    }
    if (discountTotalMilli !=
        lines.fold<int>(0, (s, l) => s + l.discountAmountMilli)) {
      return 'discount total does not match the lines';
    }
    if (grandTotalMilli != lines.fold<int>(0, (s, l) => s + l.lineTotalMilli)) {
      return 'grand total does not match the lines';
    }
    if (payments.isEmpty) return 'a completed sale needs a payment';
    for (final p in payments) {
      if (p.amountMilli <= 0) return 'payment amounts must be positive';
    }
    if (payments.fold<int>(0, (s, p) => s + p.amountMilli) != grandTotalMilli) {
      return 'payments must equal the sale total';
    }
    return null;
  }

  OfflineSale copyWith({
    OfflineSaleStatus? status,
    int? serverSaleId,
    DateTime? updatedAt,
    DateTime? completedAt,
    String? lastError,
    String? lastErrorCode,
    bool clearError = false,
    DateTime? syncedAt,
    String? serverSaleNumber,
    String? resolvedBy,
    DateTime? resolvedAt,
    String? resolutionReason,
  }) => OfflineSale(
    localSaleId: localSaleId,
    serverSaleId: serverSaleId ?? this.serverSaleId,
    status: status ?? this.status,
    companyId: companyId,
    storeId: storeId,
    registerId: registerId,
    deviceId: deviceId,
    shiftId: shiftId,
    salesmanId: salesmanId,
    installationId: installationId,
    customerId: customerId,
    currency: currency,
    createdAt: createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: completedAt ?? this.completedAt,
    lines: lines,
    payments: payments,
    subtotalMilli: subtotalMilli,
    taxTotalMilli: taxTotalMilli,
    discountTotalMilli: discountTotalMilli,
    grandTotalMilli: grandTotalMilli,
    lastError: clearError ? null : (lastError ?? this.lastError),
    sourceDraftSaleId: sourceDraftSaleId,
    salesmanName: salesmanName,
    customerName: customerName,
    lastErrorCode: clearError ? null : (lastErrorCode ?? this.lastErrorCode),
    syncedAt: syncedAt ?? this.syncedAt,
    serverSaleNumber: serverSaleNumber ?? this.serverSaleNumber,
    resolvedBy: resolvedBy ?? this.resolvedBy,
    resolvedAt: resolvedAt ?? this.resolvedAt,
    resolutionReason: resolutionReason ?? this.resolutionReason,
  );

  Map<String, dynamic> toJson() => {
    'local_sale_id': localSaleId,
    'server_sale_id': serverSaleId,
    'status': status.wire,
    'company_id': companyId,
    'store_id': storeId,
    'register_id': registerId,
    'device_id': deviceId,
    'shift_id': shiftId,
    'salesman_id': salesmanId,
    'installation_id': installationId,
    'customer_id': customerId,
    'currency': currency,
    'created_at': createdAt.toUtc().toIso8601String(),
    'updated_at': updatedAt.toUtc().toIso8601String(),
    'completed_at': completedAt?.toUtc().toIso8601String(),
    'lines': lines.map((l) => l.toJson()).toList(),
    'payments': payments.map((p) => p.toJson()).toList(),
    'subtotal_milli': subtotalMilli,
    'tax_total_milli': taxTotalMilli,
    'discount_total_milli': discountTotalMilli,
    'grand_total_milli': grandTotalMilli,
    'last_error': lastError,
    'source_draft_sale_id': sourceDraftSaleId,
    'salesman_name': salesmanName,
    'customer_name': customerName,
    'last_error_code': lastErrorCode,
    'synced_at': syncedAt?.toUtc().toIso8601String(),
    'server_sale_number': serverSaleNumber,
    'resolved_by': resolvedBy,
    'resolved_at': resolvedAt?.toUtc().toIso8601String(),
    'resolution_reason': resolutionReason,
  };

  /// The body of `POST /api/v1/pos/offline-sales/sync`. Scope values are
  /// sent for correlation only — the server compares them with the signed-in
  /// session and rejects a mismatch. Money stays in integer milli.
  Map<String, dynamic> toSyncJson() => {
    'local_sale_id': localSaleId,
    'company_id': companyId,
    'store_id': storeId,
    'register_id': registerId,
    'device_id': deviceId,
    'salesman_id': salesmanId,
    'shift_id': shiftId,
    'customer_id': customerId,
    'currency': currency,
    'created_at': createdAt.toUtc().toIso8601String(),
    'source_draft_sale_id': sourceDraftSaleId,
    'lines': [
      for (final l in lines)
        {
          'product_variation_id': l.productVariationId,
          'quantity': l.quantity,
          'unit_price_milli': l.unitPriceMilli,
          'tax_percent': l.taxPercent,
          'tax_mode': l.taxMode,
          'tax_amount_milli': l.taxAmountMilli,
          'discount_amount_milli': l.discountAmountMilli,
          'line_total_milli': l.lineTotalMilli,
        },
    ],
    'payments': [
      for (final p in payments)
        {
          'method': p.method,
          'provider': OfflinePayment.provider,
          'amount_milli': p.amountMilli,
          'tendered_milli': p.tenderedMilli,
          'change_milli': p.changeMilli,
          'reference': p.reference,
        },
    ],
    'totals': {
      'subtotal_milli': subtotalMilli,
      'tax_total_milli': taxTotalMilli,
      'discount_total_milli': discountTotalMilli,
      'grand_total_milli': grandTotalMilli,
    },
  };

  static OfflineSale? fromJson(Map<String, dynamic> m) {
    final id = asString(m['local_sale_id']);
    final status = OfflineSaleStatus.fromWire(asString(m['status']));
    final company = asInt(m['company_id']);
    final store = asInt(m['store_id']);
    final register = asInt(m['register_id']);
    final shift = asInt(m['shift_id']);
    final staff = asString(m['salesman_id']);
    final installation = asString(m['installation_id']);
    final created = DateTime.tryParse(asString(m['created_at']) ?? '');
    final updated = DateTime.tryParse(asString(m['updated_at']) ?? '');
    final rawLines = asList(m['lines']);
    final lines = rawLines
        .map(OfflineSaleLine.fromJson)
        .whereType<OfflineSaleLine>()
        .toList();
    final rawPays = asList(m['payments']);
    final pays = rawPays
        .map(OfflinePayment.fromJson)
        .whereType<OfflinePayment>()
        .toList();
    final sub = asInt(m['subtotal_milli']);
    final tax = asInt(m['tax_total_milli']);
    final disc = asInt(m['discount_total_milli']);
    final total = asInt(m['grand_total_milli']);
    if (id == null ||
        status == null ||
        company == null ||
        store == null ||
        register == null ||
        shift == null ||
        staff == null ||
        installation == null ||
        created == null ||
        updated == null ||
        sub == null ||
        tax == null ||
        disc == null ||
        total == null) {
      return null;
    }
    // A line or payment that does not parse makes the whole sale unreadable
    // (it is preserved and reported, never half-loaded).
    if (lines.length != rawLines.length || pays.length != rawPays.length) {
      return null;
    }
    return OfflineSale(
      localSaleId: id,
      serverSaleId: asInt(m['server_sale_id']),
      status: status,
      companyId: company,
      storeId: store,
      registerId: register,
      deviceId: asInt(m['device_id']),
      shiftId: shift,
      salesmanId: staff,
      installationId: installation,
      customerId: asString(m['customer_id']),
      currency: asString(m['currency']),
      createdAt: created.toUtc(),
      updatedAt: updated.toUtc(),
      completedAt: DateTime.tryParse(asString(m['completed_at']) ?? '')
          ?.toUtc(),
      lines: lines,
      payments: pays,
      subtotalMilli: sub,
      taxTotalMilli: tax,
      discountTotalMilli: disc,
      grandTotalMilli: total,
      lastError: asString(m['last_error']),
      sourceDraftSaleId: asInt(m['source_draft_sale_id']),
      salesmanName: asString(m['salesman_name']),
      customerName: asString(m['customer_name']),
      lastErrorCode: asString(m['last_error_code']),
      syncedAt: DateTime.tryParse(asString(m['synced_at']) ?? '')?.toUtc(),
      serverSaleNumber: asString(m['server_sale_number']),
      resolvedBy: asString(m['resolved_by']),
      resolvedAt: DateTime.tryParse(asString(m['resolved_at']) ?? '')?.toUtc(),
      resolutionReason: asString(m['resolution_reason']),
    );
  }
}
