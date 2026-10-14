import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'core/config/app_config.dart';
import 'features/scale/mock_scale_adapter.dart';
import 'features/scale/scale_controller.dart';
import 'features/scale/ui/scale_weight_panel.dart';
import 'core/network/pos_api_client.dart';
import 'core/storage/token_store.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/data/auth_service.dart';
import 'features/auth/state/session_controller.dart';
import 'features/auth/ui/auth_pages.dart';
import 'features/cart/data/cart_service.dart';
import 'features/cart/data/line_pricing_service.dart';
import 'features/cart/state/cart_controller.dart';
import 'features/held_sales/data/held_sales_service.dart';
import 'features/held_sales/state/held_sales_controller.dart';
import 'features/barcode/camera_scanner.dart';
import 'features/barcode/scale_label.dart';
import 'features/products/data/product_service.dart';
import 'features/products/state/product_list_controller.dart';
import 'features/checkout/data/payment_exception_service.dart';
import 'features/payment_exceptions/data/store_exception_service.dart';
import 'features/checkout/data/payment_recovery_service.dart';
import 'features/checkout/data/payment_terminal_service.dart';
import 'features/offline/offline_checkout_service.dart';
import 'features/offline/offline_services.dart';
import 'features/offline/offline_session_sync.dart';
import 'features/offline/offline_storage_service.dart';
import 'features/offline/offline_sync_service.dart';
import 'features/products/ui/products_page.dart';
import 'features/receipt/data/printer_settings.dart';
import 'features/receipt/data/receipt_delivery.dart';
import 'features/receipt/state/print_service.dart';
import 'features/receipt/state/cash_drawer_service.dart';
import 'features/receipt/state/receipt_services.dart';

class PosApp extends StatefulWidget {
  const PosApp({
    super.key,
    this.tokenStore,
    this.baseUrl,
    this.httpClient,
    this.offlineStorage,
    this.scale,
  });

  /// Overridable for tests.
  final TokenStore? tokenStore;
  final String? baseUrl;
  final http.Client? httpClient;

  /// Local offline storage; when null the default location is opened at
  /// start-up. If it cannot be opened the POS runs online-only.
  final OfflineStorageService? offlineStorage;

  /// Phase 18A: the weighing scale, if any. Null = manual weight entry only
  /// (the default: no scale model has been chosen yet). In a non-release
  /// build `--dart-define=POS_SCALE=mock` enables the SIMULATED scale.
  final ScaleController? scale;

  @override
  State<PosApp> createState() => _PosAppState();
}

class _PosAppState extends State<PosApp> {
  late final SessionController _session;
  late final PosApiClient _client;
  late final ReceiptServices _receipts;
  OfflineServices? _offline;
  ScaleController? _scale;
  bool _ownsScale = false;

  static const _scaleSetting = String.fromEnvironment('POS_SCALE');

  @override
  void initState() {
    super.initState();
    final store = widget.tokenStore ?? SecureTokenStore();
    final printerSettings = PrinterSettingsStore(store);
    _receipts = ReceiptServices(
      print: PrintService(settings: printerSettings),
      delivery: const UrlLauncherDelivery(),
      settings: printerSettings,
      drawer: CashDrawerService(settings: printerSettings),
    );
    _client = PosApiClient(
      baseUrl: widget.baseUrl ?? AppConfig.baseUrl,
      httpClient: widget.httpClient,
      tokenProvider: () => _session.activeToken,
      onUnauthorized: (failedToken) => _session.handleUnauthorized(failedToken),
    );
    _session = SessionController(ApiAuthService(_client), store)..restore();
    _scale = widget.scale;
    if (_scale == null && !kReleaseMode && _scaleSetting == 'mock') {
      final mock = MockScaleAdapter();
      _scale = ScaleController(mock);
      _ownsScale = true;
      mock.connect().then((_) => mock.startDemo(), onError: (_) {});
    }
    _openOffline();
  }

  Future<void> _openOffline() async {
    try {
      final storage =
          widget.offlineStorage ?? await OfflineStorageService.openDefault();
      if (widget.offlineStorage != null) await storage.initialize();
      if (!mounted) return;
      setState(
        () => _offline = OfflineServices(
          storage,
          syncApi: ApiOfflineSyncApi(_client),
          scope: () => _session.tokenScope,
        ),
      );
    } catch (_) {
      // No local storage on this platform/run: online-only, as before.
    }
  }

  @override
  void dispose() {
    if (_ownsScale) {
      final adapter = _scale!.adapter;
      _scale!.dispose();
      adapter.dispose();
    }
    _session.dispose();
    _client.close();
    super.dispose();
  }

  /// Phase 18A: above the navigator so the weight dialog can find the scale.
  Widget _withScale(Widget app) {
    final scale = _scale;
    return scale == null ? app : ScaleScope(controller: scale, child: app);
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: _session),
        Provider<PosApiClient>.value(value: _client),
        Provider<ReceiptServices>.value(value: _receipts),
        Provider<OfflineServices?>.value(value: _offline),
      ],
      child: _withScale(
        MaterialApp(
          title: 'ThriveWoo POS',
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: ThemeMode.system,
          debugShowCheckedModeBanner: false,
          home: const _AuthGate(),
        ),
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
        final session = context.read<SessionController>();
        final offline = context.watch<OfflineServices?>();
        bool isOffline() => client.reachable.value == false;
        // 401s are handled once, centrally: PosApiClient -> SessionController.
        // (Wiring the controllers' own callbacks as well would sign out twice.)
        final ProductService products = offline == null
            ? ApiProductService(client)
            : OfflineProductService(
                ApiProductService(client),
                offline.storage,
                isOffline: isOffline,
              );
        return MultiProvider(
          key: ValueKey(offline),
          providers: [
            // Fills the offline caches while online (no-op without storage).
            Provider<OfflineSessionSync?>(
              create: (_) => offline == null
                  ? null
                  : (OfflineSessionSync(
                      offline: offline,
                      client: client,
                      session: session,
                      products: ApiProductService(client),
                    )..start()),
              dispose: (_, sync) => sync?.dispose(),
              lazy: false,
            ),
            Provider<ProductService>.value(value: products),
            Provider<CameraScanner>.value(value: const MobileCameraScanner()),
            // Line discounts and per-sale price overrides (online only; the
            // server checks permission and limits on every request).
            Provider<LinePricingService>.value(
              value: ApiLinePricingService(client),
            ),
            // Supermarket scale labels: recognised only for formats an
            // administrator activated; the server reads every label.
            Provider<ScaleLabelRecognizer>(
              create: (_) => ScaleLabelRecognizer(
                ApiScaleLabelService(client),
                save: offline?.storage.saveScaleLabelFormats,
                restore: offline?.storage.getScaleLabelFormats,
              ),
            ),
            // Card-terminal payments through the server's payment-attempt API.
            Provider<PaymentTerminalService>.value(
              value: ApiPaymentTerminalService(client),
            ),
            // Phase 6: unfinished sales/payments of this device after a restart.
            Provider<PaymentRecoveryService?>.value(
              value: ApiPaymentRecoveryService(client),
            ),
            // Phase 7: manager resolution of captured payments whose sale
            // cannot complete (refund / manual-refund flag, server-enforced).
            Provider<PaymentExceptionService?>.value(
              value: ApiPaymentExceptionService(client),
            ),
            // Phase 9: the store-wide manager view of payment exceptions.
            Provider<StoreExceptionService?>.value(
              value: ApiStoreExceptionService(client),
            ),
            ChangeNotifierProvider(
              create: (_) => ProductListController(products),
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
                // Phase 6: a completed sale needs no recovery reminder.
                onServerSaleCompleted: (id) =>
                    offline?.storage.removePaymentRecoveryMarker(id),
                offline: offline == null
                    ? null
                    : OfflineCartSupport(
                        checkout: offline.checkout,
                        isOffline: isOffline,
                        scope: () => session.tokenScope,
                        staffName: () => session.authContext?.staff.name,
                        onServerSale: (sale) => offline.cache
                            .recordShiftFromSale(sale, session.tokenScope),
                        // Saved locally while the server IS reachable (e.g.
                        // a local cart finished after the connection came
                        // back): send it now rather than waiting.
                        onOfflineSaleRecorded: (_) {
                          if (client.reachable.value == true) {
                            ctx.read<OfflineSessionSync?>()?.syncAndRefresh();
                          }
                        },
                      ),
              ),
            ),
          ],
          child: const ProductsPage(),
        );
    }
  }
}
