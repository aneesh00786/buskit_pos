import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/data/auth_service.dart';
import 'package:buskit_pos/features/auth/models/pos_auth_context.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/held_sales/data/held_sales_service.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';
import 'package:flutter/widgets.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/features/barcode/camera_scanner.dart';
import 'package:buskit_pos/features/cash_movements/data/cash_movement_service.dart';
import 'package:buskit_pos/features/cash_movements/models/cash_movement.dart';
import 'package:buskit_pos/features/inventory/data/inventory_service.dart';
import 'package:buskit_pos/features/inventory/models/inventory_adjustment.dart';
import 'package:buskit_pos/features/product_price/data/product_price_service.dart';
import 'package:buskit_pos/features/product_price/models/price_change.dart';
import 'package:buskit_pos/features/products/models/product_item.dart';
import 'package:buskit_pos/features/receipt/data/printer_settings.dart';
import 'package:buskit_pos/features/receipt/data/receipt_delivery.dart';
import 'package:buskit_pos/features/receipt/models/receipt.dart';
import 'package:buskit_pos/features/receipt/state/print_service.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';

/// JSON shaped exactly like one row of `GET /products` `data.items`.
Map<String, dynamic> productJson({
  required int id,
  String? productId,
  String name = 'Widget',
  String? variationId,
  String? variation = 'Default',
  double price = 10,
  double? stock = 5,
  String unit = 'unit',
  String taxMode = 'exclusive',
  double taxPercent = 12,
  String? image,
  int categoryId = 1,
}) => {
  'id': id,
  'product_id': productId ?? 'P$id',
  'product_code': 'C$id',
  'variation_id': variationId ?? 'V$id',
  'variation_name': variation,
  'product_name': name,
  'brandname': 'Brand',
  'barcode': 'BC$id',
  'unit_type': unit,
  'image_url': image,
  'category': {'id': categoryId, 'name': 'Cat $categoryId'},
  'stock': {'current_stock': stock},
  'status': 1,
  'incl_tax': null,
  'category_tax_percent': taxPercent,
  'pricing': {
    'sell_price': price,
    'tax_percent': taxPercent,
    'tax_mode': taxMode,
    'tax_included': taxMode == 'inclusive',
    'tax_amount': 1.2,
    'discount': 0,
    'final_price': null,
    'pricing_status': 'base_price_only',
  },
};

Map<String, dynamic> pageJson(
  List<Map<String, dynamic>> items, {
  int page = 1,
  int limit = 20,
  int? total,
  int? totalPages,
}) => {
  'items': items,
  'pagination': {
    'page': page,
    'limit': limit,
    'total': total ?? items.length,
    'total_pages': totalPages ?? 1,
  },
};

ProductPage page(
  List<Map<String, dynamic>> items, {
  int page = 1,
  int? total,
  int totalPages = 1,
}) => ProductPage.fromJson(
  pageJson(items, page: page, total: total, totalPages: totalPages),
);

Map<String, dynamic> saleJson({
  int id = 7,
  int version = 1,
  String status = 'draft',
  List<Map<String, dynamic>> items = const [],
  double subtotal = 0,
  double tax = 0,
  double discount = 0,
  double total = 0,
  Map<String, dynamic>? promotion,
  String? customerId,
  Map<String, dynamic>? loyalty,
  Map<String, dynamic>? discountOverride,
}) => {
  'id': id,
  'version': version,
  'status': status,
  'customer_id': customerId,
  'has_unavailable_items': false,
  'items': items,
  'totals': {
    'subtotal': subtotal,
    'tax_total': tax,
    'discount_total': discount,
    'grand_total': total,
  },
  'promotion': promotion,
  'loyalty': loyalty,
  'discount_override': discountOverride,
};

Map<String, dynamic> discountOverrideJson({
  String discountType = 'percentage',
  double discountValue = 10,
  double? discountAmount,
  String? reason,
  String? appliedBy,
}) => {
  'discount_type': discountType,
  'discount_value': discountValue,
  'discount_amount': discountAmount,
  'reason': reason,
  'applied_by': appliedBy,
};

Map<String, dynamic> loyaltySaleInfoJson({
  Map<String, dynamic>? tier,
  double? pointsBalance,
  double? walletBalance,
  double tierDiscountAmount = 0,
  int pointsRedeemed = 0,
  double pointsRedeemedValue = 0,
  int? pointsEarned,
  int? pointsToEarn,
  double walletRedeemed = 0,
  double? cashbackEarned,
  double? cashbackToEarn,
  bool eligible = true,
  String? reasonCode,
  String? message,
}) => {
  'tier': tier,
  'points_balance': pointsBalance,
  'wallet_balance': walletBalance,
  'tier_discount_amount': tierDiscountAmount,
  'points_redeemed': pointsRedeemed,
  'points_redeemed_value': pointsRedeemedValue,
  if (pointsEarned != null) 'points_earned': pointsEarned,
  if (pointsToEarn != null) 'points_to_earn': pointsToEarn,
  'wallet_redeemed': walletRedeemed,
  if (cashbackEarned != null) 'cashback_earned': cashbackEarned,
  if (cashbackToEarn != null) 'cashback_to_earn': cashbackToEarn,
  'eligible': eligible,
  'reason_code': reasonCode,
  'message': message,
};

Map<String, dynamic> appliedPromotionJson({
  int id = 1,
  String title = 'Test 10% Off',
  String? discountType = 'percentage',
  double? discountValue = 10,
  double? maxDiscount,
  bool eligible = true,
  String? reasonCode,
  String? message,
  double discountAmount = 0,
}) => {
  'id': id,
  'title': title,
  'discount_type': discountType,
  'discount_value': discountValue,
  'max_discount': maxDiscount,
  'eligible': eligible,
  'reason_code': reasonCode,
  'message': message,
  'discount_amount': discountAmount,
};

class SearchCall {
  SearchCall(this.query, this.categoryId, this.page, this.limit);
  final String? query;
  final int? categoryId;
  final int page;
  final int limit;
  @override
  String toString() => 'search(q=$query, cat=$categoryId, page=$page)';
}

class FakeProductService implements ProductService {
  final List<SearchCall> calls = [];
  Future<ProductPage> Function(SearchCall call) onSearch = (c) async =>
      page([]);
  Future<List<ProductCategory>> Function() onCategories = () async => [];
  int categoryCalls = 0;
  final List<String> barcodeCalls = [];
  Future<ProductItem?> Function(String code) onBarcode = (_) async => null;
  final List<int> idCalls = [];
  Future<ProductItem?> Function(int id) onFindById = (_) async => null;

  @override
  Future<ProductItem?> findByBarcode(String barcode) {
    barcodeCalls.add(barcode);
    return onBarcode(barcode);
  }

  @override
  Future<ProductItem?> findById(int id) {
    idCalls.add(id);
    return onFindById(id);
  }

  @override
  Future<ProductPage> search({
    String? query,
    int? categoryId,
    String? brand,
    int page = 1,
    int limit = 20,
  }) {
    final c = SearchCall(query, categoryId, page, limit);
    calls.add(c);
    return onSearch(c);
  }

  @override
  Future<List<ProductCategory>> categories() {
    categoryCalls++;
    return onCategories();
  }
}

class AddCall {
  AddCall(this.saleId, this.variationId, this.quantity, this.expectedVersion);
  final int saleId;
  final int variationId;
  final int quantity;
  final int expectedVersion;
}

class CompleteCall {
  CompleteCall(this.saleId, this.expectedVersion, this.key, this.payments);
  final int saleId;
  final int expectedVersion;
  final String key;
  final List<PaymentLine> payments;
}

class CancelCall {
  CancelCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

/// The immutable completed-sale view the server returns from `complete`
/// (items have NO product names; payments carry the server's change figures).
Map<String, dynamic> completedJson({
  int id = 7,
  String number = 'POS-00000007',
  List<PaymentLine> payments = const [],
  double subtotal = 100,
  double tax = 12,
  double total = 112,
  String completedAt = '2026-09-21 15:23:52',
  String? customerId,
  List<Map<String, dynamic>>? items,
  Map<String, dynamic>? loyalty,
}) => {
  'id': id,
  'status': 'completed',
  'sale_number': number,
  'customer_id': customerId,
  'loyalty': loyalty,
  'version': 5,
  'stock_deducted': false,
  'items':
      items ??
      [
        {
          'id': 1,
          'product_variation_id': 42,
          'quantity': 2,
          'unit_price': 50,
          'tax_percent': 12,
          'tax_included': false,
          'tax_amount': 12,
          'discount_amount': 0,
          'line_total': 112,
        },
      ],
  'totals': {
    'subtotal': subtotal,
    'tax_total': tax,
    'discount_total': 0,
    'grand_total': total,
  },
  'payments': [
    for (final p in payments)
      {
        'method': p.method.wire,
        'amount': p.amountMilli / 1000,
        'tendered_amount': p.method == TenderMethod.cash
            ? (p.tenderedMilli ?? p.amountMilli) / 1000
            : null,
        'change_due': p.method == TenderMethod.cash
            ? ((p.tenderedMilli ?? p.amountMilli) - p.amountMilli) / 1000
            : null,
        'status': 'completed',
      },
  ],
  'completed_at': completedAt,
};

class HoldCall {
  HoldCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

class ResumeCall {
  ResumeCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

class ApplyPromotionCall {
  ApplyPromotionCall(this.saleId, this.promotionId, this.expectedVersion);
  final int saleId;
  final int promotionId;
  final int expectedVersion;
}

class RemovePromotionCall {
  RemovePromotionCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

class ApplyDiscountCall {
  ApplyDiscountCall(this.saleId, this.discountType, this.discountValue, this.reason, this.expectedVersion);
  final int saleId;
  final String discountType;
  final String discountValue;
  final String? reason;
  final int expectedVersion;
}

class RemoveDiscountCall {
  RemoveDiscountCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

/// A raw `pos_sales` row as returned by `GET /sales?status=held` (note the
/// null totals and the internal columns the app must ignore).
Map<String, dynamic> heldRowJson({
  required int id,
  int version = 2,
  String? saleNumber,
  String salesman = 'S1',
  double? total,
  String heldAt = '2026-09-21 15:23:52',
}) => {
  'id': id,
  'company_id': 1,
  'store_id': 3,
  'register_id': 5,
  'shift_id': 8,
  'device_id': 4,
  'salesman_id': salesman,
  'customer_id': null,
  'sale_number': saleNumber,
  'status': 'held',
  'version': version,
  'idempotency_key': null,
  'subtotal': null,
  'tax_total': null,
  'discount_total': null,
  'grand_total': total,
  'held_at': heldAt,
  'created_at': '2026-09-21 15:00:00',
  'updated_at': heldAt,
};

class FakeHeldSalesService implements HeldSalesService {
  int calls = 0;
  Future<List<HeldSaleSummary>> Function() onList = () async => [];

  @override
  Future<List<HeldSaleSummary>> listHeld() {
    calls++;
    return onList();
  }
}

class UpdateCall {
  UpdateCall(this.saleId, this.itemId, this.quantity, this.expectedVersion);
  final int saleId;
  final int itemId;
  final int quantity;
  final int expectedVersion;
}

class RemoveCall {
  RemoveCall(this.saleId, this.itemId, this.expectedVersion);
  final int saleId;
  final int itemId;
  final int expectedVersion;
}

/// A sale-line JSON row shaped like the server's live draft view.
Map<String, dynamic> lineJson({
  required int id,
  int variationId = 42,
  int quantity = 1,
  String name = 'Tea',
  double unitPrice = 10,
  double tax = 1.2,
  bool taxIncluded = false,
  double taxPercent = 12,
  double? lineTotal,
  String availability = 'available',
}) => {
  'id': id,
  'product_variation_id': variationId,
  'quantity': quantity,
  'product_name': name,
  'barcode': 'BC$id',
  'brandname': 'Brand',
  'availability_status': availability,
  'unit_price': unitPrice,
  'tax_percent': taxPercent,
  'tax_included': taxIncluded,
  'tax_amount': tax,
  'line_total': lineTotal ?? unitPrice * quantity + tax,
};

class FakeCartService implements CartService {
  final List<HoldCall> holdCalls = [];
  final List<ResumeCall> resumeCalls = [];

  /// Every mutating call in the order it was made ("hold:7", "resume:9").
  final List<String> callLog = [];
  Future<CartSale> Function(HoldCall call) onHold = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1, status: 'held'),
      )!;
  Future<CartSale> Function(ResumeCall call) onResume = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  @override
  Future<CartSale> holdSale({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = HoldCall(saleId, expectedVersion);
    holdCalls.add(c);
    callLog.add('hold:$saleId');
    return onHold(c);
  }

  @override
  Future<CartSale> resumeSale({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = ResumeCall(saleId, expectedVersion);
    resumeCalls.add(c);
    callLog.add('resume:$saleId');
    return onResume(c);
  }

  final List<UpdateCall> updateCalls = [];
  final List<RemoveCall> removeCalls = [];
  Future<CartSale> Function(UpdateCall call) onUpdate = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
  Future<CartSale> Function(RemoveCall call) onRemove = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  @override
  Future<CartSale> updateItem({
    required int saleId,
    required int itemId,
    required int quantity,
    required int expectedVersion,
  }) {
    final c = UpdateCall(saleId, itemId, quantity, expectedVersion);
    updateCalls.add(c);
    return onUpdate(c);
  }

  @override
  Future<CartSale> removeItem({
    required int saleId,
    required int itemId,
    required int expectedVersion,
  }) {
    final c = RemoveCall(saleId, itemId, expectedVersion);
    removeCalls.add(c);
    return onRemove(c);
  }

  int createCalls = 0;
  int getCalls = 0;
  final List<AddCall> addCalls = [];
  Future<CartSale> Function() onCreate = () async =>
      CartSale.fromJson(saleJson())!;
  Future<CartSale> Function(int saleId) onGet = (id) async =>
      CartSale.fromJson(saleJson(id: id))!;
  Future<CartSale> Function(AddCall call) onAdd = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  final List<String?> createCustomerIds = [];

  @override
  Future<CartSale> createSale({String? customerId}) {
    createCalls++;
    createCustomerIds.add(customerId);
    return onCreate();
  }

  final List<CompleteCall> completeCalls = [];
  final List<CancelCall> cancelCalls = [];
  Future<CompletedSale> Function(CompleteCall call) onComplete = (c) async =>
      CompletedSale.fromJson(
        completedJson(id: c.saleId, payments: c.payments),
      )!;
  Future<CartSale> Function(CancelCall call) onCancel = (c) async =>
      CartSale.fromJson(
        saleJson(
          id: c.saleId,
          version: c.expectedVersion + 1,
          status: 'canceled',
        ),
      )!;

  @override
  Future<CartSale> cancelSale({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = CancelCall(saleId, expectedVersion);
    cancelCalls.add(c);
    callLog.add('cancel:$saleId');
    return onCancel(c);
  }

  @override
  Future<CompletedSale> completeSale({
    required int saleId,
    required int expectedVersion,
    required String idempotencyKey,
    required List<PaymentLine> payments,
  }) {
    final c = CompleteCall(saleId, expectedVersion, idempotencyKey, payments);
    completeCalls.add(c);
    callLog.add('complete:$saleId');
    return onComplete(c);
  }

  @override
  Future<CartSale> getSale(int saleId) {
    getCalls++;
    return onGet(saleId);
  }

  final List<ApplyPromotionCall> applyPromotionCalls = [];
  final List<RemovePromotionCall> removePromotionCalls = [];
  Future<CartSale> Function(ApplyPromotionCall call) onApplyPromotion =
      (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
  Future<CartSale> Function(RemovePromotionCall call) onRemovePromotion =
      (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  @override
  Future<CartSale> applyPromotion({
    required int saleId,
    required int promotionId,
    required int expectedVersion,
  }) {
    final c = ApplyPromotionCall(saleId, promotionId, expectedVersion);
    applyPromotionCalls.add(c);
    return onApplyPromotion(c);
  }

  @override
  Future<CartSale> removePromotion({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = RemovePromotionCall(saleId, expectedVersion);
    removePromotionCalls.add(c);
    return onRemovePromotion(c);
  }

  final List<ApplyDiscountCall> applyDiscountCalls = [];
  final List<RemoveDiscountCall> removeDiscountCalls = [];
  Future<CartSale> Function(ApplyDiscountCall call) onApplyDiscount =
      (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
  Future<CartSale> Function(RemoveDiscountCall call) onRemoveDiscount =
      (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  @override
  Future<CartSale> applyDiscountOverride({
    required int saleId,
    required String discountType,
    required String discountValue,
    String? reason,
    required int expectedVersion,
  }) {
    final c = ApplyDiscountCall(saleId, discountType, discountValue, reason, expectedVersion);
    applyDiscountCalls.add(c);
    return onApplyDiscount(c);
  }

  @override
  Future<CartSale> removeDiscountOverride({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = RemoveDiscountCall(saleId, expectedVersion);
    removeDiscountCalls.add(c);
    return onRemoveDiscount(c);
  }

  @override
  Future<CartSale> addItem({
    required int saleId,
    required int productVariationId,
    required int quantity,
    required int expectedVersion,
  }) {
    final c = AddCall(saleId, productVariationId, quantity, expectedVersion);
    addCalls.add(c);
    return onAdd(c);
  }

  final List<RedeemPointsCall> redeemPointsCalls = [];
  final List<RedeemWalletCall> redeemWalletCalls = [];
  final List<RemoveLoyaltyCall> removeLoyaltyCalls = [];
  Future<CartSale> Function(RedeemPointsCall call) onRedeemPoints = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
  Future<CartSale> Function(RedeemWalletCall call) onRedeemWallet = (c) async =>
      CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;
  Future<CartSale> Function(RemoveLoyaltyCall call) onRemoveLoyalty =
      (c) async => CartSale.fromJson(
        saleJson(id: c.saleId, version: c.expectedVersion + 1),
      )!;

  @override
  Future<CartSale> redeemLoyaltyPoints({
    required int saleId,
    required int points,
    required int expectedVersion,
  }) {
    final c = RedeemPointsCall(saleId, points, expectedVersion);
    redeemPointsCalls.add(c);
    return onRedeemPoints(c);
  }

  @override
  Future<CartSale> redeemLoyaltyWallet({
    required int saleId,
    required double amount,
    required int expectedVersion,
  }) {
    final c = RedeemWalletCall(saleId, amount, expectedVersion);
    redeemWalletCalls.add(c);
    return onRedeemWallet(c);
  }

  @override
  Future<CartSale> removeLoyaltyRedemption({
    required int saleId,
    required int expectedVersion,
  }) {
    final c = RemoveLoyaltyCall(saleId, expectedVersion);
    removeLoyaltyCalls.add(c);
    return onRemoveLoyalty(c);
  }
}

class RedeemPointsCall {
  RedeemPointsCall(this.saleId, this.points, this.expectedVersion);
  final int saleId;
  final int points;
  final int expectedVersion;
}

class RedeemWalletCall {
  RedeemWalletCall(this.saleId, this.amount, this.expectedVersion);
  final int saleId;
  final double amount;
  final int expectedVersion;
}

class RemoveLoyaltyCall {
  RemoveLoyaltyCall(this.saleId, this.expectedVersion);
  final int saleId;
  final int expectedVersion;
}

class FakeAuthService implements AuthService {
  Future<String> Function(String id, String secret) onDevice = (i, s) async =>
      'device-token';
  Future<String> Function(String device, String id, String pin) onStaff = (
    d,
    i,
    p,
  ) async => 'staff-token';
  Future<int?> Function(String staff, double amount) onShift = (s, a) async =>
      1;
  Future<PosAuthContext?> Function(String staffToken) onAuthContext =
      (t) async => null;
  final List<String> log = [];

  @override
  Future<String> deviceLogin({
    required String deviceIdentifier,
    required String deviceSecret,
  }) {
    log.add('device:$deviceIdentifier');
    return onDevice(deviceIdentifier, deviceSecret);
  }

  @override
  Future<String> staffLogin({
    required String deviceToken,
    required String salesmanId,
    required String pin,
  }) {
    log.add('staff:$salesmanId');
    return onStaff(deviceToken, salesmanId, pin);
  }

  @override
  Future<int?> openShift({
    required String staffToken,
    required double openingAmount,
  }) {
    log.add('shift:$openingAmount');
    return onShift(staffToken, openingAmount);
  }

  @override
  Future<PosAuthContext?> getAuthContext({required String staffToken}) {
    log.add('authContext');
    return onAuthContext(staffToken);
  }
}

ApiException apiError(
  int status, {
  String? message,
  String? code,
  Object? data,
}) => ApiException.fromStatus(
  status,
  message: message,
  errorCode: code,
  data: data,
);

/// Builds a draft [CartSale] for tests that only care about its lines/total.
class CartSaleFactory {
  static CartSale sale({
    int id = 7,
    int version = 2,
    List<Map<String, dynamic>> items = const [],
    double total = 0,
    String status = 'draft',
    String? customerId,
    Map<String, dynamic>? loyalty,
    Map<String, dynamic>? discountOverride,
  }) => CartSale.fromJson(
    saleJson(
      id: id,
      version: version,
      status: status,
      items: items,
      subtotal: total,
      total: total,
      customerId: customerId,
      loyalty: loyalty,
      discountOverride: discountOverride,
    ),
  )!;
}

/// Records receipts sent to "print" and returns a scripted outcome.
class FakePrintService extends PrintService {
  FakePrintService()
    : super(settings: PrinterSettingsStore(MemoryTokenStore()));
  final List<ReceiptData> printed = [];
  Future<PrintOutcome> Function(ReceiptData)? onPrint;

  @override
  Future<PrintOutcome> print(ReceiptData receipt) async {
    printed.add(receipt);
    if (onPrint != null) return onPrint!(receipt);
    return const PrintOutcome(channel: PrintChannel.thermal);
  }
}

class FakeDelivery implements ReceiptDelivery {
  final List<Uri> opened = [];
  bool result = true;
  @override
  Future<bool> open(Uri uri) async {
    opened.add(uri);
    return result;
  }
}

class FakeReceipts {
  FakeReceipts() {
    settings = PrinterSettingsStore(MemoryTokenStore());
    print = FakePrintService();
    delivery = FakeDelivery();
    services = ReceiptServices(
      print: print,
      delivery: delivery,
      settings: settings,
    );
  }
  late final PrinterSettingsStore settings;
  late final FakePrintService print;
  late final FakeDelivery delivery;
  late final ReceiptServices services;
}

class FakeCameraScanner implements CameraScanner {
  FakeCameraScanner({this.supported = true});
  @override
  bool supported;
  int opened = 0;

  /// What the "camera" reads next; null = the cashier closed it.
  String? next;
  Future<String?> Function()? onScan;

  @override
  Future<String?> scan(BuildContext context) async {
    opened++;
    if (onScan != null) return onScan!();
    return next;
  }
}

class FakeCashMovementService implements CashMovementService {
  CurrentShiftCashMovements listResult = const CurrentShiftCashMovements(
    shift: CurrentShiftSummary(id: 1, status: 'open', openingAmount: 0),
    movements: [],
  );
  Future<CurrentShiftCashMovements> Function()? onList;
  int listCalls = 0;

  Future<CashMovement?> Function(String amount, String? reason, String key)?
  onWithdraw;
  final List<String> withdrawKeys = [];

  Future<CashMovement?> Function(String amount, String? reason, String key)?
  onDeposit;
  final List<String> depositKeys = [];

  /// Movements this fake "recorded" — like the backend, a later list call
  /// returns them newest-first ahead of [listResult]'s own movements.
  final List<CashMovement> created = [];

  @override
  Future<CurrentShiftCashMovements> listCurrentShift() async {
    listCalls++;
    if (onList != null) return onList!();
    if (created.isEmpty) return listResult;
    return CurrentShiftCashMovements(
      shift: listResult.shift,
      movements: [...created.reversed, ...listResult.movements],
    );
  }

  CashMovement _record(CashMovement? m) {
    if (m != null) created.add(m);
    return m!;
  }

  @override
  Future<CashMovement?> withdraw({
    required String amount,
    String? reason,
    required String idempotencyKey,
  }) async {
    withdrawKeys.add(idempotencyKey);
    if (onWithdraw != null) {
      final m = await onWithdraw!(amount, reason, idempotencyKey);
      return m == null ? null : _record(m);
    }
    return _record(
      CashMovement(
        id: 1000 + withdrawKeys.length,
        amount: double.parse(amount),
        reason: reason,
        status: 'completed',
        shiftId: 1,
        movementType: CashMovementType.withdrawal,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
  }

  @override
  Future<CashMovement?> deposit({
    required String amount,
    String? reason,
    required String idempotencyKey,
  }) async {
    depositKeys.add(idempotencyKey);
    if (onDeposit != null) {
      final m = await onDeposit!(amount, reason, idempotencyKey);
      return m == null ? null : _record(m);
    }
    return _record(
      CashMovement(
        id: 2000 + depositKeys.length,
        amount: double.parse(amount),
        reason: reason,
        status: 'completed',
        shiftId: 1,
        movementType: CashMovementType.deposit,
        createdAt: DateTime(2026, 1, 1),
      ),
    );
  }
}

class AdjustCall {
  AdjustCall(this.productVariationId, this.direction, this.quantity, this.reason, this.key);
  final int productVariationId;
  final AdjustmentDirection direction;
  final String quantity;
  final String reason;
  final String key;
}

class FakeInventoryService implements InventoryService {
  final List<AdjustCall> adjustCalls = [];
  int historyCalls = 0;
  List<InventoryAdjustment> history = const [];
  Future<List<InventoryAdjustment>> Function(int? id)? onHistory;

  /// Default: a successful adjustment computed from [stock].
  int stock = 10;
  Future<InventoryAdjustment?> Function(AdjustCall c)? onAdjust;

  @override
  Future<InventoryAdjustment?> adjust({
    required int productVariationId,
    required AdjustmentDirection direction,
    required String quantity,
    required String reason,
    required String idempotencyKey,
  }) async {
    final c = AdjustCall(productVariationId, direction, quantity, reason, idempotencyKey);
    adjustCalls.add(c);
    if (onAdjust != null) return onAdjust!(c);
    final q = int.parse(quantity);
    final prev = stock;
    stock = direction == AdjustmentDirection.increase ? prev + q : prev - q;
    return InventoryAdjustment(
      id: adjustCalls.length,
      productVariationId: productVariationId,
      direction: direction,
      quantity: q,
      previousQuantity: prev,
      resultingQuantity: stock,
      reason: reason,
      createdAt: DateTime(2026, 1, 1),
    );
  }

  @override
  Future<List<InventoryAdjustment>> listHistory({int? productVariationId}) async {
    historyCalls++;
    if (onHistory != null) return onHistory!(productVariationId);
    return history;
  }
}

class PriceCall {
  PriceCall(this.action, this.productId, this.price, this.expectedVersion, this.key, this.reason);
  final String action; // 'set' | 'reset'
  final int productId;
  final String? price;
  final int expectedVersion;
  final String key;
  final String? reason;
}

/// Default behaviour: a successful change against an in-memory price state.
class FakeProductPriceService implements ProductPriceService {
  FakeProductPriceService({this.price = 25, this.cataloguePrice = 25});
  double price;
  double cataloguePrice;
  int version = 0;
  final List<PriceCall> calls = [];
  final List<PriceChange> changes = [];
  int historyCalls = 0;
  Future<ProductPriceState?> Function(PriceCall c)? onChange;
  Future<ProductPriceState?> Function(int productId)? onHistory;

  ProductPriceState _state(PriceChange? change) => ProductPriceState(
    sellPrice: price,
    cataloguePrice: cataloguePrice,
    priceSource: price == cataloguePrice ? 'catalogue' : 'pos',
    priceVersion: version,
    change: change,
    history: List.of(changes.reversed),
  );

  Future<ProductPriceState?> _apply(PriceCall c) async {
    calls.add(c);
    if (onChange != null) return onChange!(c);
    final prev = price;
    price = c.action == 'set' ? double.parse(c.price!) : cataloguePrice;
    version++;
    final change = PriceChange(
      id: changes.length + 1,
      action: c.action,
      previousPrice: prev,
      previousSource: 'pos',
      newPrice: price,
      newSource: c.action == 'set' ? 'pos' : 'catalogue',
      reason: c.reason,
      createdAt: DateTime(2026, 1, 1),
    );
    changes.add(change);
    return _state(change);
  }

  @override
  Future<ProductPriceState?> setPrice({
    required int productId,
    required String price,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) => _apply(PriceCall('set', productId, price, expectedVersion, idempotencyKey, reason));

  @override
  Future<ProductPriceState?> resetPrice({
    required int productId,
    required int expectedVersion,
    required String idempotencyKey,
    String? reason,
  }) => _apply(PriceCall('reset', productId, null, expectedVersion, idempotencyKey, reason));

  @override
  Future<ProductPriceState?> history(int productId) async {
    historyCalls++;
    if (onHistory != null) return onHistory!(productId);
    return _state(null);
  }
}
