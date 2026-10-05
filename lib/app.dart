import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'core/network/pos_api_client.dart';
import 'core/storage/token_store.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/auth_service.dart';
import 'features/auth/state/session_controller.dart';
import 'features/auth/ui/auth_pages.dart';
import 'features/cart/data/cart_service.dart';
import 'features/cart/state/cart_controller.dart';
import 'features/held_sales/data/held_sales_service.dart';
import 'features/held_sales/state/held_sales_controller.dart';
import 'features/barcode/camera_scanner.dart';
import 'features/products/data/product_service.dart';
import 'features/products/state/product_list_controller.dart';
import 'features/checkout/data/payment_terminal_service.dart';
import 'features/products/ui/products_page.dart';
import 'features/receipt/data/printer_settings.dart';
import 'features/receipt/data/receipt_delivery.dart';
import 'features/receipt/state/print_service.dart';
import 'features/receipt/state/receipt_services.dart';

class PosApp extends StatefulWidget {
  const PosApp({super.key, this.tokenStore, this.baseUrl, this.httpClient});

  /// Overridable for tests.
  final TokenStore? tokenStore;
  final String? baseUrl;
  final http.Client? httpClient;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  late final SessionController _session;
  late final PosApiClient _client;
  late final ReceiptServices _receipts;

  @override
  void initState() {
    super.initState();
    final store = widget.tokenStore ?? SecureTokenStore();
    final printerSettings = PrinterSettingsStore(store);
    _receipts = ReceiptServices(
      print: PrintService(settings: printerSettings),
      delivery: const UrlLauncherDelivery(),
      settings: printerSettings,
    );
    _client = PosApiClient(
      baseUrl: widget.baseUrl ?? AppConfig.baseUrl,
      httpClient: widget.httpClient,
      tokenProvider: () => _session.activeToken,
      onUnauthorized: (failedToken) => _session.handleUnauthorized(failedToken),
    );
    _session = SessionController(ApiAuthService(_client), store)..restore();
  }

  @override
  void dispose() {
    _session.dispose();
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _session),
        Provider<PosApiClient>.value(value: _client),
        Provider<ReceiptServices>.value(value: _receipts),
      ],
      child: MaterialApp(
        title: 'ThriveWoo POS',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: ThemeMode.system,
        debugShowCheckedModeBanner: false,
        home: const _AuthGate(),
      ),
    );
  }
}

class _AuthGate extends StatelessWidget {
  const _AuthGate();

  @override
  Widget build(BuildContext context) {
    final phase = context.select<SessionController, SessionPhase>(
      (s) => s.phase,
    );
    switch (phase) {
      case SessionPhase.restoring:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case SessionPhase.deviceLogin:
        return const DeviceLoginPage();
      case SessionPhase.staffLogin:
        return const StaffLoginPage();
      case SessionPhase.shiftOpen:
        return const ShiftOpenPage();
      case SessionPhase.ready:
        // POS state is created only once a cashier is signed in with an open
        // shift, and is discarded on sign-out.
        final client = context.read<PosApiClient>();
        // 401s are handled once, centrally: PosApiClient -> SessionController.
        // (Wiring the controllers' own callbacks as well would sign out twice.)
        final products = ApiProductService(client);
        return MultiProvider(
          providers: [
            Provider<ProductService>.value(value: products),
            Provider<CameraScanner>.value(value: const MobileCameraScanner()),
            // Card-terminal payments through the server's payment-attempt API.
            Provider<PaymentTerminalService>.value(value: ApiPaymentTerminalService(client)),
            ChangeNotifierProvider(
              create: (_) => ProductListController(ApiProductService(client)),
            ),
            ChangeNotifierProvider(
              create: (_) => HeldSalesController(
                ApiHeldSalesService(client),
                ApiCartService(client),
              ),
            ),
            ChangeNotifierProvider(
              // A hold/resume (or a resume that found the list out of date)
              // reloads the held-sales list.
              create: (ctx) => CartController(
                ApiCartService(client),
                onHeldSalesChanged: () =>
                    ctx.read<HeldSalesController>().refresh(),
              ),
            ),
          ],
          child: const ProductsPage(),
        );
    }
  }
}
