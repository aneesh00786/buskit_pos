import '../../core/network/api_exception.dart';
import '../auth/models/pos_token_scope.dart';
import '../cart/models/cart_sale.dart';
import '../customers/data/customer_service.dart';
import '../customers/models/customer.dart';
import '../customers/models/customer_purchase.dart';
import '../products/data/product_service.dart';
import '../products/models/category.dart';
import '../products/models/product_item.dart';
import '../products/models/product_page.dart';
import 'models/offline_catalogue.dart';
import 'models/offline_context.dart';
import 'offline_checkout_service.dart';
import 'offline_storage_service.dart';
import 'offline_sync_service.dart';

/// The offline pieces the UI needs, created once per app run when local
/// storage is available (null otherwise — the POS then works online-only,
/// exactly as before).
class OfflineServices {
  OfflineServices(
    this.storage, {
    DateTime Function()? clock,
    OfflineSyncApi? syncApi,
    PosTokenScope? Function()? scope,
  }) : checkout = OfflineCheckoutService(storage, clock: clock),
       cache = OfflineCacheService(storage, clock: clock),
       sync = syncApi == null || scope == null
           ? null
           : OfflineSyncService(
               storage: storage,
               api: syncApi,
               scope: scope,
               clock: clock,
             );

  final OfflineStorageService storage;
  final OfflineCheckoutService checkout;
  final OfflineCacheService cache;

  /// Uploads queued offline sales (null when no server API is wired, e.g.
  /// in tests of local-only behaviour).
  final OfflineSyncService? sync;
}

/// The message shown when an action needs the server and it is unreachable.
const offlineActionMessage =
    'This needs an internet connection. Reconnect and try again.';

ApiException _offlineError([String message = offlineActionMessage]) =>
    ApiException(kind: ApiErrorKind.network, message: message);

/// Fills the offline caches while ONLINE (never while offline) and keeps the
/// stored shift context in step with the server. All best-effort: a failure
/// leaves the previous cache untouched and never interrupts the cashier.
class OfflineCacheService {
  OfflineCacheService(this.storage, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final OfflineStorageService storage;
  final DateTime Function() _clock;
  Future<bool>? _catalogueRun;

  static const pageLimit = 100; // backend maximum for GET /products
  static const maxPages = 500;
  static const maxCustomerPages = 200;

  /// Reads EVERY product page and replaces products.json and inventory.json
  /// together — only when every page loaded (a partial catalogue never
  /// replaces a complete one). Inventory = each variation's `current_stock`
  /// as the server reported it. Concurrent calls share one run.
  Future<bool> refreshCatalogue(ProductService api, PosTokenScope scope) =>
      _catalogueRun ??= _refreshCatalogue(
        api,
        scope,
      ).whenComplete(() => _catalogueRun = null);

  Future<bool> _refreshCatalogue(
    ProductService api,
    PosTokenScope scope,
  ) async {
    try {
      final items = <ProductItem>[];
      var page = 1;
      var total = 1;
      do {
        final res = await api.search(page: page, limit: pageLimit);
        items.addAll(res.items);
        total = res.pagination.totalPages;
        page++;
      } while (page <= total && page <= maxPages);
      if (page <= total) return false; // too large to cache completely
      final now = _clock().toUtc();
      final products = <OfflineProduct>[];
      final stock = <InventorySnapshotEntry>[];
      final seen = <int>{};
      for (final p in items) {
        if (!seen.add(p.id)) continue;
        final o = OfflineProduct.fromProductItem(p);
        if (o == null) continue; // no price: cannot be sold offline
        products.add(o);
        stock.add(
          InventorySnapshotEntry(
            productVariationId: p.id,
            serverQuantity: p.currentStock ?? 0,
          ),
        );
      }
      await storage.saveCatalogue(
        OfflineCatalogue(
          companyId: scope.companyId,
          storeId: scope.storeId,
          cachedAt: now,
          products: products,
        ),
      );
      await storage.saveInventory(
        InventorySnapshot(syncedAt: now, entries: stock),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reads the customer directory (up to [maxCustomerPages] pages) into the
  /// cache. Customers seen in online searches are also added as they appear
  /// (see [OfflineCustomerService]).
  Future<bool> refreshCustomers(CustomerService api) async {
    try {
      var page = 1;
      var total = 1;
      final all = <OfflineCustomer>[];
      do {
        final res = await api.search(page: page, limit: pageLimit);
        all.addAll(res.items.map(OfflineCustomer.fromCustomer));
        total = res.pagination.totalPages;
        page++;
      } while (page <= total && page <= maxCustomerPages);
      await storage.upsertCustomers(all);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Records the shift the server says this register is working in. Sources
  /// (all online): the shift this session opened, and the shift id on every
  /// server sale view. A different shift id replaces the stored one.
  Future<void> recordShift({
    required PosTokenScope scope,
    required int shiftId,
    DateTime? openedAt,
  }) async {
    try {
      final current = await storage.getCurrentShift();
      if (current != null &&
          current.shiftId == shiftId &&
          current.isOpen &&
          current.companyId == scope.companyId &&
          current.storeId == scope.storeId &&
          current.registerId == scope.registerId &&
          current.deviceId == scope.deviceId) {
        if (current.openedAt == null && openedAt != null) {
          await storage.saveCurrentShift(current.copyWith(openedAt: openedAt));
        }
        return;
      }
      await storage.saveCurrentShift(
        OfflineShiftContext(
          companyId: scope.companyId,
          storeId: scope.storeId,
          registerId: scope.registerId,
          deviceId: scope.deviceId,
          shiftId: shiftId,
          salesmanId: scope.salesmanId,
          openedAt:
              openedAt ??
              (current?.shiftId == shiftId ? current?.openedAt : null),
          status: 'open',
        ),
      );
    } catch (_) {
      // Best-effort: offline checkout simply stays unavailable.
    }
  }

  /// From a server sale view (draft or completed) in the current session.
  Future<void> recordShiftFromSale(CartSale sale, PosTokenScope? scope) async {
    final shiftId = sale.shiftId;
    if (scope == null || shiftId == null || sale.isLocal) return;
    if ((sale.storeId != null && sale.storeId != scope.storeId) ||
        (sale.registerId != null && sale.registerId != scope.registerId)) {
      return;
    }
    await recordShift(scope: scope, shiftId: shiftId);
  }

  /// The shift was closed on the server: offline sales must stop.
  Future<void> markShiftClosed(int shiftId) async {
    try {
      final current = await storage.getCurrentShift();
      if (current != null && current.shiftId == shiftId) {
        await storage.saveCurrentShift(current.copyWith(status: 'closed'));
      }
    } catch (_) {}
  }
}

/// Products from the server while online; from the offline catalogue when
/// the server is unreachable (`isOffline()`), or when a request fails with a
/// network error. Offline results carry the OFFLINE available stock.
class OfflineProductService implements ProductService {
  OfflineProductService(this._api, this._storage, {required this.isOffline});

  final ProductService _api;
  final OfflineStorageService _storage;
  final bool Function() isOffline;

  Future<T> _either<T>(
    Future<T> Function() online,
    Future<T> Function() local,
  ) async {
    if (isOffline()) return local();
    try {
      return await online();
    } on ApiException catch (e) {
      if (e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout) {
        return local();
      }
      rethrow;
    }
  }

  Future<ProductItem> _withStock(OfflineProduct p) async {
    final level = (await _storage.getStockLevels())[p.productVariationId];
    return p.toProductItem(stock: level?.availableQuantity);
  }

  @override
  Future<ProductPage> search({
    String? query,
    int? categoryId,
    String? brand,
    int page = 1,
    int limit = 20,
  }) => _either(
    () => _api.search(
      query: query,
      categoryId: categoryId,
      brand: brand,
      page: page,
      limit: limit,
    ),
    () async {
      var all = await _storage.searchProducts(query ?? '', limit: 1 << 30);
      if (categoryId != null) {
        all = all.where((p) => p.categoryId == categoryId).toList();
      }
      final levels = await _storage.getStockLevels();
      final start = (page - 1) * limit;
      final slice = all.skip(start).take(limit).toList();
      final pages = all.isEmpty ? 1 : (all.length + limit - 1) ~/ limit;
      return ProductPage(
        items: [
          for (final p in slice)
            p.toProductItem(
              stock: levels[p.productVariationId]?.availableQuantity,
            ),
        ],
        pagination: Pagination(
          page: page,
          limit: limit,
          total: all.length,
          totalPages: pages,
        ),
      );
    },
  );

  @override
  Future<List<ProductCategory>> categories() =>
      _either(_api.categories, () async => const <ProductCategory>[]);

  @override
  Future<ProductItem?> findByBarcode(String barcode) =>
      _either(() => _api.findByBarcode(barcode), () async {
        final p = await _storage.findByCode(barcode);
        return p == null ? null : _withStock(p);
      });

  @override
  Future<ProductItem?> findById(int id) =>
      _either(() => _api.findById(id), () async {
        final p = await _storage.getProduct(id);
        return p == null ? null : _withStock(p);
      });
}

/// Customers from the server while online (each result is also added to the
/// offline cache); from the cache while offline. Creating or editing a
/// customer, and purchase history, need the server.
class OfflineCustomerService implements CustomerService {
  OfflineCustomerService(this._api, this._storage, {required this.isOffline});

  final CustomerService _api;
  final OfflineStorageService _storage;
  final bool Function() isOffline;

  static Customer _toCustomer(OfflineCustomer c) => Customer(
    id: c.id,
    customerId: c.customerId,
    fullname: c.fullname,
    mobileno: c.mobileno,
    email: c.email,
  );

  bool _isNetwork(ApiException e) =>
      e.kind == ApiErrorKind.network || e.kind == ApiErrorKind.timeout;

  Future<void> _remember(Iterable<Customer> list) async {
    try {
      await _storage.upsertCustomers(
        list.map(OfflineCustomer.fromCustomer).toList(),
      );
    } catch (_) {}
  }

  Future<CustomerPage> _localSearch(String? query, int page, int limit) async {
    final q = query?.trim() ?? '';
    final all = q.isEmpty
        ? await _storage.getCustomers()
        : await _storage.searchCustomers(q, limit: 1 << 30);
    final slice = all.skip((page - 1) * limit).take(limit);
    return CustomerPage(
      items: slice.map(_toCustomer).toList(),
      pagination: Pagination(
        page: page,
        limit: limit,
        total: all.length,
        totalPages: all.isEmpty ? 1 : (all.length + limit - 1) ~/ limit,
      ),
    );
  }

  @override
  Future<CustomerPage> search({
    String? query,
    int page = 1,
    int limit = 20,
  }) async {
    if (isOffline()) return _localSearch(query, page, limit);
    try {
      final res = await _api.search(query: query, page: page, limit: limit);
      await _remember(res.items);
      return res;
    } on ApiException catch (e) {
      if (_isNetwork(e)) return _localSearch(query, page, limit);
      rethrow;
    }
  }

  @override
  Future<Customer?> findByCustomerId(String customerId) async {
    Future<Customer?> local() async {
      final c = await _storage.getCustomer(customerId);
      return c == null ? null : _toCustomer(c);
    }

    if (isOffline()) return local();
    try {
      final c = await _api.findByCustomerId(customerId);
      if (c != null) await _remember([c]);
      return c;
    } on ApiException catch (e) {
      if (_isNetwork(e)) return local();
      rethrow;
    }
  }

  @override
  Future<Customer> create({
    required String fullname,
    required String mobileno,
    String? email,
  }) async {
    if (isOffline()) {
      throw _offlineError(
        'Customers cannot be created offline. Reconnect to add a customer.',
      );
    }
    final c = await _api.create(
      fullname: fullname,
      mobileno: mobileno,
      email: email,
    );
    await _remember([c]);
    return c;
  }

  @override
  Future<Customer> update(
    String customerId, {
    String? fullname,
    String? mobileno,
    Object? email = unsetCustomerField,
  }) async {
    if (isOffline()) throw _offlineError();
    final c = await _api.update(
      customerId,
      fullname: fullname,
      mobileno: mobileno,
      email: email,
    );
    await _remember([c]);
    return c;
  }

  @override
  Future<CustomerPurchasePage> purchaseHistory(
    String customerId, {
    int page = 1,
    int limit = 20,
  }) {
    if (isOffline()) return Future.error(_offlineError());
    return _api.purchaseHistory(customerId, page: page, limit: limit);
  }
}
