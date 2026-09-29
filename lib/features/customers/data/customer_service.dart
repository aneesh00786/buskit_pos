import '../../../core/network/api_exception.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/utils/json_read.dart';
import '../../products/models/product_page.dart';
import '../models/customer.dart';
import '../models/customer_purchase.dart';

/// One page of `GET /customers`.
class CustomerPage {
  const CustomerPage({required this.items, required this.pagination});
  final List<Customer> items;
  final Pagination pagination;

  bool get hasMore => pagination.page < pagination.totalPages;

  factory CustomerPage.fromJson(
    Object? json, {
    int requestedPage = 1,
    int requestedLimit = 20,
  }) {
    final m = asMap(json) ?? const <String, dynamic>{};
    final items = asList(m['items'])
        .map(Customer.fromJson)
        .whereType<Customer>()
        .toList();
    final pg = asMap(m['pagination']) ?? const <String, dynamic>{};
    final totalPages = asInt(pg['total_pages']) ?? 1;
    return CustomerPage(
      items: items,
      pagination: Pagination(
        page: asInt(pg['page']) ?? requestedPage,
        limit: asInt(pg['limit']) ?? requestedLimit,
        total: asInt(pg['total']) ?? items.length,
        totalPages: totalPages < 1 ? 1 : totalPages,
      ),
    );
  }
}

abstract class CustomerService {
  Future<CustomerPage> search({String? query, int page = 1, int limit = 20});
  Future<Customer?> findByCustomerId(String customerId);
  Future<Customer> create({
    required String fullname,
    required String mobileno,
    String? email,
  });
  Future<Customer> update(
    String customerId, {
    String? fullname,
    String? mobileno,
    Object? email = unsetCustomerField,
  });
  Future<CustomerPurchasePage> purchaseHistory(
    String customerId, {
    int page = 1,
    int limit = 20,
  });
}

/// Sentinel meaning "field not provided" for [CustomerService.update], so a
/// caller can still explicitly pass `email: null` to clear it — matching the
/// backend's own "only fields present in the body are written" semantics.
/// The ONE instance every caller/implementation/fake must share — passing a
/// different `Object()` here would silently break the "not provided" check
/// (`identical`), so nothing else in this feature should declare its own.
const unsetCustomerField = Object();

/// Verified against the backend: `GET /customers`, `GET /customers/:id`,
/// `POST /customers`, `PATCH /customers/:id`, `GET /customers/:id/purchases`
/// — all POS-scoped from the device/staff token, never a client-supplied
/// company id.
class ApiCustomerService implements CustomerService {
  ApiCustomerService(this._client);
  final PosApiClient _client;

  static const maxQueryLength = 100;

  @override
  Future<CustomerPage> search({
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    final q = <String, String>{'page': '$page', 'limit': '$limit'};
    final text = query?.trim();
    if (text != null && text.isNotEmpty) {
      q['search'] = text.length > maxQueryLength
          ? text.substring(0, maxQueryLength)
          : text;
    }
    final data = await _client.get('/customers', query: q);
    return CustomerPage.fromJson(
      data,
      requestedPage: page,
      requestedLimit: limit,
    );
  }

  @override
  Future<Customer?> findByCustomerId(String customerId) async {
    try {
      final data = await _client.get(
        '/customers/${Uri.encodeComponent(customerId)}',
      );
      return Customer.fromJson(data);
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.notFound) return null;
      rethrow;
    }
  }

  @override
  Future<Customer> create({
    required String fullname,
    required String mobileno,
    String? email,
  }) async {
    final data = await _client.post(
      '/customers',
      body: {
        'fullname': fullname.trim(),
        'mobileno': mobileno.trim(),
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
      },
    );
    final customer = Customer.fromJson(data);
    if (customer == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return customer;
  }

  @override
  Future<Customer> update(
    String customerId, {
    String? fullname,
    String? mobileno,
    Object? email = unsetCustomerField,
  }) async {
    final body = <String, dynamic>{
      if (fullname != null) 'fullname': fullname.trim(),
      if (mobileno != null) 'mobileno': mobileno.trim(),
    };
    if (!identical(email, unsetCustomerField)) {
      body['email'] = (email as String?)?.trim();
    }
    final data = await _client.patch(
      '/customers/${Uri.encodeComponent(customerId)}',
      body: body,
    );
    final customer = Customer.fromJson(data);
    if (customer == null) {
      throw const ApiException(
        kind: ApiErrorKind.unknown,
        message: 'Unexpected response from the server.',
      );
    }
    return customer;
  }

  @override
  Future<CustomerPurchasePage> purchaseHistory(
    String customerId, {
    int page = 1,
    int limit = 20,
  }) async {
    final data = await _client.get(
      '/customers/${Uri.encodeComponent(customerId)}/purchases',
      query: {'page': '$page', 'limit': '$limit'},
    );
    return CustomerPurchasePage.fromJson(
      data,
      requestedPage: page,
      requestedLimit: limit,
    );
  }
}
