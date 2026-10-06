import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/layout/responsive.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/quantity.dart';
import '../../auth/state/session_controller.dart';
import '../../barcode/barcode_key_listener.dart';
import '../../barcode/barcode_scan_handler.dart';
import '../../barcode/camera_scanner.dart';
import '../../cart/state/cart_controller.dart';
import '../../cart/ui/quantity_dialog.dart';
import '../../cart/ui/cart_panel.dart';
import '../../held_sales/state/held_sales_controller.dart';
import '../../held_sales/ui/held_sales_view.dart';
import '../../customers/ui/customers_view.dart';
import '../../history/ui/sales_history_view.dart';
import '../../inventory/ui/inventory_view.dart';
import '../../offline/ui/offline_sale_views.dart';
import '../../payment_exceptions/data/store_exception_service.dart';
import '../../payment_exceptions/ui/store_exceptions_view.dart';
import '../../checkout/data/payment_exception_service.dart';
import '../../checkout/data/payment_recovery_service.dart';
import '../../checkout/ui/payment_recovery_view.dart';
import '../../promotions/ui/promotions_view.dart';
import '../../analytics/ui/analytics_view.dart';
import '../../settings/ui/settings_view.dart';
import '../../shell/ui/pos_header.dart';
import '../../shell/ui/pos_scaffold.dart';
import '../../shell/ui/pos_sidebar.dart';
import '../../shell/ui/summary_panel.dart';
import '../data/product_service.dart';
import '../models/product_group.dart';
import '../state/product_list_controller.dart';
import 'product_filter_bar.dart';
import 'product_card.dart';
import 'variation_sheet.dart';
import '../../shift_close/ui/shift_close_view.dart';

enum _CatalogView { grid, list }

/// The POS sales screen: navigation, product catalog and the current sale.
/// Layout adapts to the window width (see [PosLayoutClass]); all product,
/// search, category and cart behavior is unchanged.
class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});
  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  _CatalogView _view = _CatalogView.grid;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_onScroll);
    // Controller methods notify listeners synchronously, which is not allowed
    // while the tree is still being built — start the first loads after it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<ProductListController>();
      unawaited(c.loadCategories());
      unawaited(c.loadInitial());
      _startPaymentRecovery();
    });
  }

  // ---- Phase 6: payment & sale recovery after a restart ----
  PaymentRecoveryService? _recovery;
  ValueNotifier<bool?>? _reachable;
  bool? _lastReachable;
  bool _recoveryRunning = false;
  PaymentExceptionService? _exceptions;

  /// Only when the app wired a recovery service (tests without one keep the
  /// previous behaviour). Runs now (app start / sign-in) and again whenever
  /// the connection comes back while the cart is empty.
  void _startPaymentRecovery() {
    try {
      _recovery = Provider.of<PaymentRecoveryService?>(context, listen: false);
    } on ProviderNotFoundException {
      _recovery = null;
    }
    if (_recovery == null) return;
    try {
      _exceptions = Provider.of<PaymentExceptionService?>(
        context,
        listen: false,
      );
    } on ProviderNotFoundException {
      _exceptions = null;
    }
    _reachable = Provider.of<PosApiClient?>(context, listen: false)?.reachable;
    _lastReachable = _reachable?.value;
    _reachable?.addListener(_onReachability);
    if (_lastReachable != false) unawaited(_checkRecovery());
  }

  void _onReachability() {
    final now = _reachable?.value;
    final wasOffline = _lastReachable == false;
    _lastReachable = now;
    if (wasOffline && now == true) unawaited(_checkRecovery());
  }

  StoreExceptionService? _storeExceptions(BuildContext context) {
    try {
      return Provider.of<StoreExceptionService?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// Phase 7: back from the background (e.g. after a UPI app or a call) —
  /// check again, with the same guards (empty cart, nothing on top).
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _lastReachable != false) {
      unawaited(_checkRecovery());
    }
  }

  Future<void> _checkRecovery() async {
    final service = _recovery;
    if (service == null || _recoveryRunning || !mounted) return;
    final cart = context.read<CartController>();
    // Never interrupt a sale being rung up.
    if (cart.sale != null || cart.isMutating) return;
    // Nor a dialog / screen the cashier has open on top of this page.
    if (ModalRoute.of(context)?.isCurrent == false) return;
    _recoveryRunning = true;
    try {
      await runPaymentRecovery(
        context,
        service: service,
        cart: cart,
        storage: readOfflineServices(context)?.storage,
        exceptions: _exceptions,
      );
    } finally {
      _recoveryRunning = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _reachable?.removeListener(_onReachability);
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 300) {
      context.read<ProductListController>().loadNextPage();
    }
  }

  Future<void> _onSelect(ProductGroup g) async {
    final cart = context.read<CartController>();
    if (g.hasMultipleVariations) {
      cart.clearError();
      await showVariationSheet(context, g);
      return;
    }
    final first = g.first;
    // Selling mode (server-decided): only PIECE products can be added here.
    // The server refuses the rest too; this just avoids a pointless request.
    final notSellable = first.notSellableMessage;
    if (notSellable != null) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(_snackBar(notSellable, duration: const Duration(seconds: 5)));
      return;
    }
    final label = [
      first.variationName,
      first.unitType,
    ].where((x) => x != null && x.trim().isNotEmpty).join(' · ');
    // Phase 12B: a product sold by weight asks for the weight first (the
    // existing quantity dialog in weight mode); pieces add 1 as before.
    num quantity = 1;
    if (first.isWeight) {
      final w = await showQuantityDialog(
        context,
        initial: 1,
        itemName: g.name,
        weight: true,
      );
      if (w == null || !mounted) return;
      quantity = w;
    }
    final ok = await cart.addItem(
      g.first.id,
      quantity,
      label: label.isEmpty ? null : label,
      imageUrl: g.imageUrl,
      sellingMode: first.sellingMode,
    );
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    if (ok) {
      messenger.showSnackBar(
        _snackBar(
          'Added ${formatQuantity(quantity, weight: first.isWeight)} × ${g.name}',
        ),
      );
    } else if (cart.error != null) {
      messenger.showSnackBar(
        _snackBar(
          describeApiError(cart.error!),
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  BarcodeScanHandler? _scanHandler;
  bool _cameraOpen = false;

  BarcodeScanHandler get _scans => _scanHandler ??= BarcodeScanHandler(
    products: context.read<ProductService>(),
    cart: context.read<CartController>(),
  );

  /// A scanner-speed burst ending in Enter was typed (hardware scanner), or the
  /// camera read a code: look it up and add it to the cart.
  Future<void> _onBarcode(String code) async {
    final list = context.read<ProductListController>();
    final result = await _scans.handle(code);
    if (!mounted) return;
    // A scanner types into a focused search box too; don't leave the code there.
    if (_search.text.trim() == code) {
      _search.clear();
      if (list.query.isNotEmpty) {
        unawaited(list.submitQuery(''));
      } else {
        list.onQueryChanged('');
      }
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      _snackBar(
        result.message,
        duration: Duration(seconds: result.added ? 3 : 5),
      ),
    );
  }

  Future<void> _scanWithCamera() async {
    if (_cameraOpen) return;
    _cameraOpen = true;
    try {
      final code = await context.read<CameraScanner>().scan(context);
      if (code != null && mounted) await _onBarcode(code);
    } finally {
      _cameraOpen = false;
    }
  }

  void _showHelp(BuildContext context, String? device) {
    // Compact layouts show the sidebar in a drawer: close it first.
    if (PosLayoutClass.forWidth(MediaQuery.sizeOf(context).width).isCompact) {
      Navigator.of(context).pop();
    }
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Help'),
        content: Text(
          'ThriveWoo POS · version ${AppConfig.appVersion}'
          '${device == null ? '' : '\nDevice $device'}\n\n'
          'For assistance, contact your store administrator.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// On tablets the current sale sits at the right; a full-width snackbar would
  /// cover its action buttons (e.g. Hold sale), so it is floated clear of it.
  SnackBar _snackBar(
    String text, {
    Duration duration = const Duration(seconds: 4),
  }) {
    final layout = PosLayoutClass.forWidth(MediaQuery.sizeOf(context).width);
    final side = layout.hasSideCart;
    return SnackBar(
      content: Text(text),
      duration: duration,
      behavior: side ? SnackBarBehavior.floating : SnackBarBehavior.fixed,
      margin: side
          ? EdgeInsets.fromLTRB(
              16,
              0,
              layout.sideCartWidth + 28 + (layout.hasSummary ? 312 : 0),
              16,
            )
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final cart = context.watch<CartController>();
    // Present only when the app wires held-sales support in (see app.dart).
    final held = context.watch<HeldSalesController?>();
    final client = context.read<PosApiClient?>();
    final camera = context.read<CameraScanner?>();
    final VoidCallback? onScan = (camera != null && camera.supported)
        ? _scanWithCamera
        : null;

    return BarcodeKeyListener(
      onBarcode: (code) => unawaited(_onBarcode(code)),
      child: ResponsivePosLayout(
        builder: (context, layout) {
          final staff = session.salesmanId == null
              ? null
              : 'Staff ${session.salesmanId}';
          return PosScaffold(
            layout: layout,
            compactTitle: 'Products',
            compactActions: [
              if (client != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: NetworkStatusChip(
                    reachable: client.reachable,
                    showLabel: false,
                  ),
                ),
              if (camera != null)
                IconButton(
                  tooltip: onScan == null
                      ? 'Camera scanning is not available on this device'
                      : 'Scan barcode with camera',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onScan,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              if (held != null) _HeldSalesAction(held: held),
            ],
            sidebarBuilder: (collapsed) => PosSidebar(
              collapsed: collapsed,
              brandTitle: 'ThriveWoo POS',
              brandSubtitle: 'Point of sale',
              deviceLabel: session.deviceIdentifier,
              appVersion: AppConfig.appVersion,
              onHelp: () => _showHelp(context, session.deviceIdentifier),
              heldCount: held?.heldCount,
              onOpenOrders: held == null
                  ? null
                  : () {
                      // The compact layout shows the sidebar in a drawer: close it first.
                      if (layout.isCompact) Navigator.of(context).pop();
                      showHeldSales(context);
                    },
              onOpenHistory: () {
                // The compact layout shows the sidebar in a drawer: close it first.
                if (layout.isCompact) Navigator.of(context).pop();
                showSalesHistory(context);
              },
              onOpenCustomers: () {
                if (layout.isCompact) Navigator.of(context).pop();
                showCustomers(context);
              },
              onOpenInventory: () {
                if (layout.isCompact) Navigator.of(context).pop();
                showInventory(
                  context,
                  onCatalogueChanged: context.read<ProductListController>().retry,
                );
              },
              onOpenPromotions: () {
                if (layout.isCompact) Navigator.of(context).pop();
                showPromotions(context);
              },
              onOpenAnalytics: () {
                if (layout.isCompact) Navigator.of(context).pop();
                showAnalytics(context);
              },
              onOpenSettings: () {
                if (layout.isCompact) Navigator.of(context).pop();
                showSettings(context);
              },
              // Phase 9: store-wide payment exceptions — only when wired
              // and not positively denied payments.view_store_exceptions
              // (the server enforces it either way).
              onOpenPaymentExceptions:
                  _storeExceptions(context) == null ||
                      session.isDenied('payments.view_store_exceptions')
                  ? null
                  : () {
                      if (layout.isCompact) Navigator.of(context).pop();
                      showStoreExceptions(context);
                    },
              onSignOut: session.logoutStaff,
              // Hidden only when the loaded permissions positively lack
              // shifts.view (the summary needs it); the backend still
              // enforces shifts.view / shifts.close itself.
              onCloseShift: session.isDenied('shifts.view')
                  ? null
                  : () async {
                      if (layout.isCompact) Navigator.of(context).pop();
                      // Sales saved offline and not yet synced (warned about).
                      var unsynced = 0;
                      try {
                        unsynced =
                            (await readOfflineServices(
                                      context,
                                    )?.storage.getPendingSales() ??
                                    const [])
                                .length;
                      } catch (_) {}
                      if (!context.mounted) return;
                      showShiftClose(
                        context,
                        cartHasItems: cart.hasActiveDraftWithItems,
                        unsyncedOfflineSales: unsynced,
                        onClosed: (result) {
                          // Offline sales must stop with the shift.
                          readOfflineServices(
                            context,
                          )?.cache.markShiftClosed(result.shiftId);
                          session.logoutStaff(
                            notice:
                                'Shift #${result.shiftId} closed. Sign in to open the next shift.',
                          );
                        },
                      );
                    },
            ),
            header: PosHeader(
              search: _SearchField(controller: _search),
              staffLabel: staff,
              reachable: client?.reachable,
              onScanBarcode: onScan,
            ),
            banner: OfflineBanner(reachable: client?.reachable),
            body: _Catalog(
              layout: layout,
              search: _search,
              scroll: _scroll,
              view: _view,
              onViewChanged: (v) => setState(() => _view = v),
              onSelect: _onSelect,
            ),
            cart: const CartPanel(),
            summary: const SalesSummaryPanel(),
            bottomBar: _CartBar(cart: cart),
          );
        },
      ),
    );
  }
}

/// Phone/small-tablet bottom bar: item count and the server total, opening the
/// current sale in a sheet.
class _CartBar extends StatelessWidget {
  const _CartBar({required this.cart});
  final CartController cart;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final sale = cart.sale;
    final hasItems = sale != null && sale.items.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(top: BorderSide(color: t.border)),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(PosTokens.s8),
          child: FilledButton.icon(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              useSafeArea: true,
              showDragHandle: true,
              builder: (_) => ChangeNotifierProvider.value(
                value: cart,
                child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * 0.85,
                  child: const CartPanel(),
                ),
              ),
            ),
            icon: const Icon(Icons.shopping_cart_outlined),
            label: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    sale == null ? 'Cart' : 'Cart · ${sale.itemCount} items',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (hasItems && sale.totals.grandTotal != null) ...[
                  const SizedBox(width: PosTokens.s12),
                  Text(
                    formatMoney(sale.totals.grandTotal),
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({required this.controller});
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final c = context.read<ProductListController>();
    final t = PosTokens.of(context);
    return TextField(
      controller: controller,
      textInputAction: TextInputAction.search,
      decoration: InputDecoration(
        hintText: 'Search products, SKU or barcode',
        labelText: 'Search products, SKU or barcode',
        floatingLabelBehavior: FloatingLabelBehavior.never,
        filled: true,
        fillColor: t.surfaceMuted,
        isDense: false,
        contentPadding: const EdgeInsets.symmetric(
          vertical: 14,
          horizontal: 12,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PosTokens.rPill),
          borderSide: BorderSide.none,
        ),
        prefixIcon: const Icon(Icons.search),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: controller,
          builder: (_, v, _) => v.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: 'Clear search',
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    controller.clear();
                    c.submitQuery('');
                  },
                ),
        ),
      ),
      onChanged: c.onQueryChanged,
      onSubmitted: c.submitQuery,
    );
  }
}

class _Catalog extends StatelessWidget {
  const _Catalog({
    required this.layout,
    required this.search,
    required this.scroll,
    required this.view,
    required this.onViewChanged,
    required this.onSelect,
  });

  final PosLayoutClass layout;
  final TextEditingController search;
  final ScrollController scroll;
  final _CatalogView view;
  final ValueChanged<_CatalogView> onViewChanged;
  final Future<void> Function(ProductGroup) onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ProductListController>();
    final busy = context.select<CartController, bool>((x) => x.isMutating);

    return LayoutBuilder(
      builder: (context, box) {
        // Narrow phones: the sort dropdown joins the grid/list toggle above the
        // chips, so the category row (with its scroll arrows) keeps the full width.
        final narrow = box.maxWidth < 480;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // On compact layouts the search field lives here (the header is not shown).
            if (layout.isCompact)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PosTokens.s12,
                  PosTokens.s12,
                  PosTokens.s12,
                  PosTokens.s4,
                ),
                child: _SearchField(controller: search),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PosTokens.s16,
                PosTokens.s12,
                PosTokens.s12,
                0,
              ),
              child: Row(
                children: [
                  if (!layout.isCompact)
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          'Products',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                      ),
                    )
                  else if (narrow)
                    // Shrinks (label ellipsizes) instead of overflowing at large text scales.
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 170),
                        child: SortDropdown(
                          value: c.sort,
                          onChanged: c.setSort,
                          compact: true,
                          expand: true,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (narrow) const Spacer(),
                  _ViewToggle(view: view, onChanged: onViewChanged),
                ],
              ),
            ),
            ProductFilterBar(controller: c, showSort: !narrow),
            Expanded(
              child: _Body(
                controller: c,
                scroll: scroll,
                onSelect: onSelect,
                busy: busy,
                view: view,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ViewToggle extends StatelessWidget {
  const _ViewToggle({required this.view, required this.onChanged});
  final _CatalogView view;
  final ValueChanged<_CatalogView> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final scheme = Theme.of(context).colorScheme;
    Widget button(_CatalogView v, IconData icon, String tooltip) {
      final selected = view == v;
      return Semantics(
        button: true,
        selected: selected,
        label: tooltip,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(PosTokens.rSmall),
            onTap: () => onChanged(v),
            child: Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: selected ? scheme.primaryContainer : Colors.transparent,
                borderRadius: BorderRadius.circular(PosTokens.rSmall),
              ),
              child: Icon(
                icon,
                color: selected
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
        border: Border.all(color: t.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(_CatalogView.grid, Icons.grid_view_rounded, 'Grid view'),
          button(_CatalogView.list, Icons.view_list_rounded, 'List view'),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.scroll,
    required this.onSelect,
    required this.busy,
    required this.view,
  });
  final ProductListController controller;
  final ScrollController scroll;
  final Future<void> Function(ProductGroup) onSelect;
  final bool busy;
  final _CatalogView view;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    switch (c.status) {
      case ListStatus.idle:
      case ListStatus.loading:
        return const LoadingView(label: 'Loading products');
      case ListStatus.error:
        final e = c.error!;
        return ErrorView(
          message: describeApiError(e),
          // Validation/auth/permission errors would fail identically, so no Retry.
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? c.retry
              : null,
        );
      case ListStatus.empty:
        return EmptyView(
          title: 'No products found',
          message: c.query.isNotEmpty || c.categoryId != null
              ? 'Try a different search or category.'
              : 'There are no products to show.',
        );
      case ListStatus.loaded:
        return RefreshIndicator(
          onRefresh: c.retry,
          child: CustomScrollView(
            controller: scroll,
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.all(12),
                sliver: view == _CatalogView.grid
                    ? SliverGrid(
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisExtent: 300,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                            ),
                        delegate: SliverChildBuilderDelegate(
                          (_, i) => ProductCard(
                            group: c.groups[i],
                            busy: busy,
                            onTap: () => onSelect(c.groups[i]),
                          ),
                          childCount: c.groups.length,
                        ),
                      )
                    : SliverList.separated(
                        itemCount: c.groups.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 8),
                        itemBuilder: (_, i) => ProductListTile(
                          group: c.groups[i],
                          busy: busy,
                          onTap: () => onSelect(c.groups[i]),
                        ),
                      ),
              ),
              SliverToBoxAdapter(child: _Footer(controller: c)),
            ],
          ),
        );
    }
  }
}

class _Footer extends StatelessWidget {
  const _Footer({required this.controller});
  final ProductListController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    if (c.loadingMore) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (c.loadMoreError != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Flexible(child: Text(describeApiError(c.loadMoreError!))),
            if (c.loadMoreError!.isRetryable)
              TextButton(onPressed: c.loadNextPage, child: const Text('Retry')),
          ],
        ),
      );
    }
    return const SizedBox(height: 16);
  }
}

class _HeldSalesAction extends StatelessWidget {
  const _HeldSalesAction({required this.held});
  final HeldSalesController held;

  @override
  Widget build(BuildContext context) {
    final count = held.heldCount ?? 0;
    return IconButton(
      tooltip: count > 0 ? 'Held sales ($count)' : 'Held sales',
      constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      onPressed: () => showHeldSales(context),
      icon: Badge(
        isLabelVisible: count > 0,
        label: Text('$count'),
        child: const Icon(Icons.pause_circle_outline),
      ),
    );
  }
}
