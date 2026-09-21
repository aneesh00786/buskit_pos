import 'package:buskit_pos/core/network/pos_api_client.dart';
import 'package:buskit_pos/core/storage/token_store.dart';
import 'package:buskit_pos/core/theme/app_theme.dart';
import 'package:buskit_pos/features/auth/state/session_controller.dart';
import 'package:buskit_pos/features/cart/state/cart_controller.dart';
import 'package:buskit_pos/features/held_sales/state/held_sales_controller.dart';
import 'package:buskit_pos/features/products/state/product_list_controller.dart';
import 'package:buskit_pos/features/products/ui/products_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'fakes.dart';

/// Everything a test needs to drive the real [ProductsPage] with fakes.
class PageHarness {
  PageHarness({bool withHeld = true, this.client}) {
    products = FakeProductService();
    carts = FakeCartService();
    heldService = FakeHeldSalesService();
    fakeAuth = FakeAuthService();
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
    );
    products.onSearch = (_) async =>
        page([productJson(id: 1, name: 'Tea', variation: '250g')]);
    products.onCategories = () async => [];
  }

  late final FakeProductService products;
  late final FakeCartService carts;
  late final FakeHeldSalesService heldService;
  late final FakeAuthService fakeAuth;
  late final SessionController session;
  late final ProductListController list;
  late final HeldSalesController? held;
  late final CartController cart;
  final PosApiClient? client;

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
        ChangeNotifierProvider.value(value: h.list),
        ChangeNotifierProvider.value(value: h.cart),
        if (h.held != null)
          ChangeNotifierProvider<HeldSalesController>.value(value: h.held!),
        if (h.client != null) Provider<PosApiClient>.value(value: h.client!),
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
        ChangeNotifierProvider.value(value: h.list),
        ChangeNotifierProvider.value(value: h.cart),
        if (h.held != null)
          ChangeNotifierProvider<HeldSalesController>.value(value: h.held!),
      ],
      child: MaterialApp(theme: AppTheme.light(), home: const ProductsPage()),
    ),
  );
  await tester.pump();
  await tester.pump();
}
