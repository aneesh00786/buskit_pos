import 'package:buskit_pos/features/checkout/data/payment_exception_service.dart';
import 'package:buskit_pos/features/payment_exceptions/data/store_exception_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_recovery_service.dart';
import 'package:buskit_pos/features/checkout/data/payment_terminal_service.dart';

import 'dart:convert';

import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/auth/models/pos_token_scope.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/offline/offline_checkout_service.dart';
import 'package:buskit_pos/features/offline/offline_services.dart';
import 'package:buskit_pos/features/held_sales/state/held_sales_controller.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:buskit_pos/features/receipt/state/receipt_services.dart';
import 'package:buskit_pos/features/barcode/camera_scanner.dart';
import 'package:buskit_pos/features/products/data/product_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

/// A [PosApiClient] that answers every `GET .../customers` search with an
/// empty page, `GET .../analytics/summary` with an all-zero summary, and
/// 404s anything else — enough for the customer picker and the summary
/// panel/analytics screen to load without error when a test doesn't care
/// about their contents. Tests that do care pass their own `client` to
/// [PageHarness].
PosApiClient defaultTestApiClient() => PosApiClient(
  baseUrl: 'http://test',
  httpClient: MockClient((r) async {
    if (r.method == 'GET' && r.url.path.endsWith('/customers')) {
      return http.Response(
        jsonEncode({
          'status': true,
          'data': {
            'items': [],
            'pagination': {
              'page': 1,
              'limit': 20,
              'total': 0,
              'total_pages': 1,
            },
          },
        }),
        200,
      );
    }
    if (r.method == 'GET' && r.url.path.endsWith('/analytics/summary')) {
      return http.Response(
        jsonEncode({
          'status': true,
          'data': {
            'today': {'transaction_count': 0, 'sales_total': 0},
            'payment_breakdown': [],
            'top_products': [],
            'staff_performance': [],
          },
        }),
        200,
      );
    }
    return http.Response(
      jsonEncode({'status': false, 'message': 'no route'}),
      404,
    );
  }),
);

/// Everything a test needs to drive the real [ProductsPage] with fakes.
class PageHarness {
  /// Optional card-terminal service (null = not wired, as in the existing tests).
  PaymentTerminalService? terminal;

  /// Optional Phase 6 payment-recovery service (null = not wired, as in the
  /// tests written before it: no recovery check runs).
  PaymentRecoveryService? recovery;

  /// Optional Phase 7 captured-payment exception service.
  PaymentExceptionService? exceptions;

  /// Optional Phase 9 store-wide exception service (null = not wired: the
  /// sidebar item stays hidden, as in every earlier test).
  StoreExceptionService? storeExceptions;

  /// Optional offline wiring (real local storage); null = online-only, as
  /// in every test written before offline checkout.
  final OfflineServices? offline;

  /// The staff scope offline checkout stamps on sales (tests set it).
  PosTokenScope? offlineScope;

  PageHarness({bool withHeld = true, PosApiClient? client, this.offline})
    : client = client ?? defaultTestApiClient() {
    products = FakeProductService();
    carts = FakeCartService();
    heldService = FakeHeldSalesService();
    fakeAuth = FakeAuthService();
    receipts = FakeReceipts();
    camera = FakeCameraScanner();
    session = SessionController(fakeAuth, MemoryTokenStore());
    list = ProductListController(
      products,
      debounce: const Duration(milliseconds: 10),
      pageSize: 20,
    );
    held = withHeld ? HeldSalesController(heldService, carts) : null;
    cart = CartController(
      carts,
      onHeldSalesChanged: held == null ? null : () => held!.refresh(),
      offline: offline == null
          ? null
          : OfflineCartSupport(
              checkout: offline!.checkout,
              isOffline: () => this.client.reachable.value == false,
              scope: () => offlineScope,
            ),
    );
    products.onSearch = (_) async =>
        page([productJson(id: 1, name: 'Tea', variation: '250g')]);
    products.onCategories = () async => [];
  }

  late final FakeProductService products;
  late final FakeCartService carts;
  late final FakeHeldSalesService heldService;
  late final FakeAuthService fakeAuth;
  late final FakeReceipts receipts;
  late final FakeCameraScanner camera;
  late final SessionController session;
  late final ProductListController list;
  late final HeldSalesController? held;
  late final CartController cart;
  final PosApiClient client;

  /// Signs in so the header/sidebar show a staff id and device identifier.
  Future<void> signIn({String device = 'REG-1', String staff = 'S1'}) async {
    await session.loginDevice(device, 'secret');
    await session.loginStaff(staff, '1234');
  }

  void dispose() {
    list.dispose();
    cart.dispose();
    held?.dispose();
    session.dispose();
  }
}

Future<void> pumpProductsPage(
  WidgetTester tester,
  PageHarness h, {
  double width = 1400,
  double height = 900,
  ThemeData? theme,
  double textScale = 1.0,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(h.dispose);

  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.session),
        Provider<ReceiptServices>.value(value: h.receipts.services),
        Provider<ProductService>.value(value: h.products),
        Provider<CameraScanner>.value(value: h.camera),
        if (h.terminal != null)
          Provider<PaymentTerminalService>.value(value: h.terminal!),
        if (h.recovery != null)
          Provider<PaymentRecoveryService?>.value(value: h.recovery),
        if (h.exceptions != null)
          Provider<PaymentExceptionService?>.value(value: h.exceptions),
        if (h.storeExceptions != null)
          Provider<StoreExceptionService?>.value(value: h.storeExceptions),
        ChangeNotifierProvider.value(value: h.list),
        ChangeNotifierProvider.value(value: h.cart),
        if (h.held != null)
          ChangeNotifierProvider<HeldSalesController>.value(value: h.held!),
        Provider<PosApiClient>.value(value: h.client),
        if (h.offline != null)
          Provider<OfflineServices?>.value(value: h.offline),
      ],
      child: MaterialApp(
        theme: theme ?? AppTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const ProductsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Like [pumpProductsPage] but does not wait for the first frame's async work,
/// so loading states can be observed.
Future<void> pumpProductsPageRaw(
  WidgetTester tester,
  PageHarness h, {
  double width = 1400,
  double height = 900,
}) async {
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  addTearDown(h.dispose);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: h.session),
        Provider<ReceiptServices>.value(value: h.receipts.services),
        Provider<ProductService>.value(value: h.products),
        Provider<CameraScanner>.value(value: h.camera),
        if (h.terminal != null)
          Provider<PaymentTerminalService>.value(value: h.terminal!),
        if (h.recovery != null)
          Provider<PaymentRecoveryService?>.value(value: h.recovery),
        if (h.exceptions != null)
          Provider<PaymentExceptionService?>.value(value: h.exceptions),
        if (h.storeExceptions != null)
          Provider<StoreExceptionService?>.value(value: h.storeExceptions),
        ChangeNotifierProvider.value(value: h.list),
        ChangeNotifierProvider.value(value: h.cart),
        if (h.held != null)
          ChangeNotifierProvider<HeldSalesController>.value(value: h.held!),
        Provider<PosApiClient>.value(value: h.client),
        if (h.offline != null)
          Provider<OfflineServices?>.value(value: h.offline),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const ProductsPage()),
    ),
  );
  await tester.pump();
  await tester.pump();
}
