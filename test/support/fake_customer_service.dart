import 'package:buskit_pos/core/network/api_exception.dart';
import 'package:buskit_pos/features/customers/data/customer_service.dart';
import 'package:buskit_pos/features/customers/models/customer.dart';
import 'package:buskit_pos/features/customers/models/customer_purchase.dart';
import 'package:buskit_pos/features/products/models/product_page.dart';

Map<String, dynamic> customerJson({
  int id = 1,
  String? customerId,
  String fullname = 'Jane Doe',
  String? mobileno = '0400111222',
  String? email,
  int status = 1,
}) => {
  'id': id,
  'customer_id': customerId ?? 'CUSTO$id',
  'fullname': fullname,
  'mobileno': mobileno,
  'email': email,
  'status': status,
};

class SearchCall {
  SearchCall(this.query, this.page, this.limit);
  final String? query;
  final int page;
  final int limit;
}

class CreateCall {
  CreateCall(this.fullname, this.mobileno, this.email);
  final String fullname;
  final String mobileno;
  final String? email;
}

class UpdateCall {
  UpdateCall(this.customerId, this.fullname, this.mobileno, this.email);
  final String customerId;
  final String? fullname;
  final String? mobileno;
  final Object? email;
}

class FakeCustomerService implements CustomerService {
  final List<SearchCall> searchCalls = [];
  final List<String> detailCalls = [];
  final List<CreateCall> createCalls = [];
  final List<UpdateCall> updateCalls = [];
  final List<String> purchaseCalls = [];

  Future<CustomerPage> Function(SearchCall call) onSearch = (_) async =>
      const CustomerPage(
        items: [],
        pagination: Pagination(page: 1, limit: 20, total: 0, totalPages: 1),
      );
  Future<Customer?> Function(String id) onFindByCustomerId = (_) async => null;
  Future<Customer> Function(CreateCall call) onCreate = (c) async =>
      Customer.fromJson(
        customerJson(
          fullname: c.fullname,
          mobileno: c.mobileno,
          email: c.email,
        ),
      )!;
  Future<Customer> Function(UpdateCall call) onUpdate = (c) async =>
      Customer.fromJson(
        customerJson(
          customerId: c.customerId,
          fullname: c.fullname ?? 'X',
          mobileno: c.mobileno,
        ),
      )!;
  Future<CustomerPurchasePage> Function(String customerId, int page)
  onPurchaseHistory = (_, page) async => CustomerPurchasePage(
    summary: const CustomerPurchaseSummary(
      transactionCount: 0,
      totalPurchases: 0,
    ),
    items: const [],
    pagination: Pagination(page: page, limit: 20, total: 0, totalPages: 1),
  );

  @override
  Future<CustomerPage> search({String? query, int page = 1, int limit = 20}) {
    final c = SearchCall(query, page, limit);
    searchCalls.add(c);
    return onSearch(c);
  }

  @override
  Future<Customer?> findByCustomerId(String customerId) {
    detailCalls.add(customerId);
    return onFindByCustomerId(customerId);
  }

  @override
  Future<Customer> create({
    required String fullname,
    required String mobileno,
    String? email,
  }) {
    final c = CreateCall(fullname, mobileno, email);
    createCalls.add(c);
    return onCreate(c);
  }

  @override
  Future<Customer> update(
    String customerId, {
    String? fullname,
    String? mobileno,
    Object? email = unsetCustomerField,
  }) {
    // Must compare against the SAME sentinel CustomerService.update declares
    // (unsetCustomerField) — every real caller (CustomerListController) holds
    // this fake through the CustomerService interface type, so an omitted
    // `email` always arrives as that shared sentinel, never a locally
    // redeclared one.
    final c = UpdateCall(
      customerId,
      fullname,
      mobileno,
      identical(email, unsetCustomerField) ? unsetCustomerField : email,
    );
    updateCalls.add(c);
    return onUpdate(c);
  }

  @override
  Future<CustomerPurchasePage> purchaseHistory(
    String customerId, {
    int page = 1,
    int limit = 20,
  }) {
    purchaseCalls.add(customerId);
    return onPurchaseHistory(customerId, page);
  }
}

ApiException notFoundError([String message = 'Not found']) =>
    ApiException(kind: ApiErrorKind.notFound, message: message);

ApiException duplicateMobileError(String existingCustomerId) => ApiException(
  kind: ApiErrorKind.conflict,
  message: 'A customer with this mobile number already exists',
  errorCode: 'POS_DUPLICATE_MOBILE',
  data: {'existing_customer_id': existingCustomerId},
);
