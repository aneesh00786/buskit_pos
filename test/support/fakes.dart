import 'dart:async';

import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/auth/data/auth_service.dart';
import 'package:buskit_pos/features/cart/data/cart_service.dart';
import 'package:buskit_pos/features/cart/models/cart_sale.dart';
import 'package:buskit_pos/features/checkout/models/payment.dart';
import 'package:buskit_pos/features/held_sales/data/held_sales_service.dart';
import 'package:buskit_pos/features/held_sales/models/held_sale_summary.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:buskit_pos/features/products/models/category.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';

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
  double total = 0,
}) => {
  'id': id,
  'version': version,
  'status': status,
  'has_unavailable_items': false,
  'items': items,
  'totals': {
    'subtotal': subtotal,
    'tax_total': tax,
    'discount_total': 0,
    'grand_total': total,
  },
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
}) => {
  'id': id,
  'status': 'completed',
  'sale_number': number,
  'customer_id': customerId,
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
  }) => CartSale.fromJson(
    saleJson(
      id: id,
      version: version,
      status: status,
      items: items,
      subtotal: total,
      total: total,
    ),
  )!;
}
