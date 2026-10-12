import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../products/data/product_service.dart';
import '../../products/models/product_item.dart';
import '../../product_price/data/product_price_service.dart';
import '../../product_price/state/product_price_controller.dart';
import '../../product_price/ui/price_section.dart';
import '../data/inventory_service.dart';
import '../models/inventory_adjustment.dart';
import '../state/inventory_controller.dart';
import '../../../core/ui/safe_insets.dart';

/// Opens Inventory (the sidebar's previously-placeholder "Inventory" entry):
/// product search with current stock for everyone, the Increase/Decrease
/// action only for `inventory.adjust`, and adjustment history only for
/// `inventory.view` (SessionController.isDenied — a missing/failed permission
/// context never hides anything; the backend's own 403 decides).
///
/// [onCatalogueChanged] lets the caller refresh its own product catalogue
/// after a POS price change (the sales screen passes its list's reload).
Future<void> showInventory(
  BuildContext context, {
  Future<void> Function()? onCatalogueChanged,
}) {
  final client = context.read<PosApiClient>();
  final controller = InventoryController(
    ApiInventoryService(client),
    context.read<ProductService>(),
  );
  final priceController = ProductPriceController(
    ApiProductPriceService(client),
    onPriceChanged: () async {
      await controller.refreshSelected();
      await onCatalogueChanged?.call();
    },
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => MultiProvider(
    providers: [
      ChangeNotifierProvider<InventoryController>.value(value: controller),
      ChangeNotifierProvider<ProductPriceController>.value(
        value: priceController,
      ),
    ],
    child: const InventoryView(),
  );
  void disposeAll() {
    controller.dispose();
    priceController.dispose();
  }

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 700,
            maxHeight: size.height * 0.9,
          ),
          child: content(),
        ),
      ),
    ).whenComplete(disposeAll);
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(
      height: size.height * 0.92,
      child: SheetSafeArea(child: content()),
    ),
  ).whenComplete(disposeAll);
}

class InventoryView extends StatefulWidget {
  const InventoryView({super.key});

  @override
  State<InventoryView> createState() => _InventoryViewState();
}

class _InventoryViewState extends State<InventoryView> {
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<InventoryController>().search('');
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<InventoryController>();
    final selected = c.selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              if (selected != null)
                IconButton(
                  tooltip: 'Back',
                  onPressed: c.clearSelection,
                  icon: const Icon(Icons.arrow_back),
                ),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Inventory',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        Expanded(
          child: selected == null
              ? _SearchPane(controller: _search, inventory: c)
              : _ProductPane(product: selected, inventory: c),
        ),
      ],
    );
  }
}

class _SearchPane extends StatelessWidget {
  const _SearchPane({required this.controller, required this.inventory});
  final TextEditingController controller;
  final InventoryController inventory;

  @override
  Widget build(BuildContext context) {
    final c = inventory;
    Widget body;
    switch (c.searchStatus) {
      case InventoryLoadStatus.idle:
      case InventoryLoadStatus.loading:
        body = const LoadingView(label: 'Loading products');
      case InventoryLoadStatus.error:
        final e = c.searchError!;
        body = ErrorView(
          message: describeApiError(e),
          onRetry: e.isRetryable ? () => c.search(c.query) : null,
        );
      case InventoryLoadStatus.loaded:
        body = c.results.isEmpty
            ? const EmptyView(
                title: 'No products found',
                icon: Icons.inventory_2_outlined,
              )
            : ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: PosTokens.s16),
                itemCount: c.results.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) => _ProductRow(
                  product: c.results[i],
                  onTap: () => c.select(c.results[i]),
                ),
              );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(PosTokens.s16),
          child: TextField(
            controller: controller,
            textInputAction: TextInputAction.search,
            decoration: const InputDecoration(
              labelText: 'Search products',
              prefixIcon: Icon(Icons.search),
            ),
            onSubmitted: c.search,
          ),
        ),
        Expanded(child: body),
      ],
    );
  }
}

String _productLabel(ProductItem p) =>
    (p.variationName == null ||
        p.variationName!.isEmpty ||
        p.variationName == 'Default')
    ? p.productName
    : '${p.productName} · ${p.variationName}';

String _stockLabel(double? stock) => stock == null ? '—' : '${stock.round()}';

class _ProductRow extends StatelessWidget {
  const _ProductRow({required this.product, required this.onTap});
  final ProductItem product;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        _productLabel(product),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: product.productCode == null ? null : Text(product.productCode!),
      trailing: Text(
        'Stock ${_stockLabel(product.currentStock)}',
        style: Theme.of(context).textTheme.titleSmall,
      ),
      onTap: onTap,
    );
  }
}

class _ProductPane extends StatelessWidget {
  const _ProductPane({required this.product, required this.inventory});
  final ProductItem product;
  final InventoryController inventory;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final canAdjust = !session.isDenied('inventory.adjust');
    final canViewHistory = !session.isDenied('inventory.view');
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final c = inventory;

    return ListView(
      padding: const EdgeInsets.all(PosTokens.s16),
      children: [
        Container(
          padding: const EdgeInsets.all(PosTokens.s16),
          decoration: t.card(outlined: false),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_productLabel(product), style: theme.textTheme.titleMedium),
              const SizedBox(height: PosTokens.s8),
              Text('Current stock', style: theme.textTheme.bodySmall),
              Text(
                _stockLabel(product.currentStock),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (canAdjust) ...[
                const SizedBox(height: PosTokens.s12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: c.isAdjusting
                            ? null
                            : () => _startAdjustment(
                                context,
                                AdjustmentDirection.increase,
                              ),
                        icon: const Icon(Icons.add),
                        label: const Text('Increase'),
                      ),
                    ),
                    const SizedBox(width: PosTokens.s12),
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: c.isAdjusting
                            ? null
                            : () => _startAdjustment(
                                context,
                                AdjustmentDirection.decrease,
                              ),
                        icon: const Icon(Icons.remove),
                        label: const Text('Decrease'),
                      ),
                    ),
                  ],
                ),
                if (c.isAdjusting)
                  const Padding(
                    padding: EdgeInsets.only(top: PosTokens.s8),
                    child: LinearProgressIndicator(),
                  ),
              ],
            ],
          ),
        ),
        const SizedBox(height: PosTokens.s16),
        ProductPriceSection(product: product),
        if (canViewHistory) ...[
          const SizedBox(height: PosTokens.s16),
          Text('Recent adjustments', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s8),
          _History(inventory: c),
        ],
      ],
    );
  }

  Future<void> _startAdjustment(
    BuildContext context,
    AdjustmentDirection direction,
  ) async {
    final c = inventory;
    final current = c.selectedStock ?? 0;
    final request = await showDialog<_AdjustRequest>(
      context: context,
      builder: (_) => _AdjustForm(direction: direction, currentStock: current),
    );
    if (request == null || !context.mounted) return;

    final qty = int.parse(request.quantity);
    final newStock = direction == AdjustmentDirection.increase
        ? current + qty
        : current - qty;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm inventory adjustment'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _KeyValue('Product', _productLabel(product)),
            _KeyValue('Current stock', '$current'),
            _KeyValue(
              'Adjustment',
              direction == AdjustmentDirection.increase ? '+$qty' : '-$qty',
            ),
            _KeyValue('New stock', '$newStock'),
            _KeyValue('Reason', request.reason),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await c.adjust(
      direction: direction,
      quantity: request.quantity,
      reason: request.reason,
    );
    if (!context.mounted) return;
    if (ok) {
      final a = c.lastAdjustment;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(
            Icons.check_circle_outline,
            color: Theme.of(ctx).colorScheme.primary,
            size: 32,
          ),
          title: const Text('Stock adjusted'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _KeyValue('Product', _productLabel(product)),
              if (a != null) ...[
                _KeyValue('Adjustment', a.signedQuantity),
                _KeyValue('Previous stock', '${a.previousQuantity}'),
                _KeyValue('New stock', '${a.resultingQuantity}'),
                _KeyValue('Reference', '#${a.id}'),
              ],
            ],
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Done'),
            ),
          ],
        ),
      );
      return;
    }
    final err = c.adjustError;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            err != null
                ? describeApiError(err)
                : 'The adjustment could not be completed.',
          ),
        ),
      );
    c.clearAdjustError();
  }
}

class _History extends StatelessWidget {
  const _History({required this.inventory});
  final InventoryController inventory;

  @override
  Widget build(BuildContext context) {
    final c = inventory;
    switch (c.historyStatus) {
      case InventoryLoadStatus.idle:
      case InventoryLoadStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: PosTokens.s16),
          child: Center(child: CircularProgressIndicator()),
        );
      case InventoryLoadStatus.error:
        final e = c.historyError!;
        return Text(describeApiError(e));
      case InventoryLoadStatus.loaded:
        if (c.history.isEmpty) return const Text('No adjustments yet.');
        return Column(
          children: [
            for (final a in c.history)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  a.direction == AdjustmentDirection.increase
                      ? Icons.add
                      : Icons.remove,
                ),
                title: Text('${a.signedQuantity} → ${a.resultingQuantity}'),
                subtitle: Text(
                  [
                    a.reason,
                    if (a.createdAt != null) formatTimestamp(a.createdAt!),
                  ].join(' · '),
                ),
              ),
          ],
        );
    }
  }
}

class _AdjustRequest {
  const _AdjustRequest(this.quantity, this.reason);
  final String quantity;
  final String reason;
}

/// Quantity (whole pieces) + required reason. Client-side checks mirror the
/// backend's rules for fast feedback only — the server re-validates and
/// re-checks stock under a row lock regardless.
class _AdjustForm extends StatefulWidget {
  const _AdjustForm({required this.direction, required this.currentStock});
  final AdjustmentDirection direction;
  final int currentStock;

  @override
  State<_AdjustForm> createState() => _AdjustFormState();
}

class _AdjustFormState extends State<_AdjustForm> {
  final _qty = TextEditingController();
  final _reason = TextEditingController();
  String? _qtyError;
  String? _reasonError;

  static const minReason = 3;
  static const maxReason = 255;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _qty.text.trim();
    final reason = _reason.text.trim();
    String? qtyError;
    String? reasonError;
    final qty = RegExp(r'^\d+$').hasMatch(raw) ? int.tryParse(raw) : null;
    if (qty == null || qty <= 0) {
      qtyError = 'Enter a whole number greater than 0';
    } else if (widget.direction == AdjustmentDirection.decrease &&
        qty > widget.currentStock) {
      qtyError =
          'Cannot decrease below 0 (current stock ${widget.currentStock})';
    }
    if (reason.length < minReason) {
      reasonError = 'Enter a reason (at least $minReason characters)';
    }
    if (qtyError != null || reasonError != null) {
      setState(() {
        _qtyError = qtyError;
        _reasonError = reasonError;
      });
      return;
    }
    Navigator.of(context).pop(_AdjustRequest('$qty', reason));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.direction.label} stock'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _qty,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Quantity *',
                errorText: _qtyError,
              ),
              onChanged: (_) {
                if (_qtyError != null) setState(() => _qtyError = null);
              },
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _reason,
              maxLength: maxReason,
              decoration: InputDecoration(
                labelText: 'Reason *',
                errorText: _reasonError,
              ),
              onChanged: (_) {
                if (_reasonError != null) setState(() => _reasonError = null);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: PosTokens.s8),
          Flexible(
            child: Text(value, style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
