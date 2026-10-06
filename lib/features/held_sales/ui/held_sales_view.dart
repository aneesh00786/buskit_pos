import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../cart/models/cart_sale.dart';
import '../../cart/state/cart_controller.dart';
import '../../cart/ui/cart_panel.dart' show confirmVoid;
import '../models/held_sale_summary.dart';
import '../state/held_sales_controller.dart';

/// Opens the held-sales list: a dialog on tablets, a tall bottom sheet on
/// phones. The routes sit above the provider tree, so the controllers are
/// re-provided.
Future<void> showHeldSales(BuildContext context) {
  final held = context.read<HeldSalesController>();
  final cart = context.read<CartController>();
  final size = MediaQuery.sizeOf(context);
  Widget content() => MultiProvider(
    providers: [
      ChangeNotifierProvider<HeldSalesController>.value(value: held),
      ChangeNotifierProvider<CartController>.value(value: cart),
    ],
    child: const HeldSalesView(),
  );

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: size.height * 0.85,
          ),
          child: content(),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(height: size.height * 0.85, child: content()),
  );
}

class HeldSalesView extends StatefulWidget {
  const HeldSalesView({super.key});

  @override
  State<HeldSalesView> createState() => _HeldSalesViewState();
}

class _HeldSalesViewState extends State<HeldSalesView> {
  @override
  void initState() {
    super.initState();
    // Controller methods notify synchronously — never during build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final held = context.read<HeldSalesController>();
      held.closeDetail();
      context.read<CartController>().clearError();
      unawaited(held.refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final held = context.watch<HeldSalesController>();
    final showingDetail = held.detailSaleId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(showingDetail: showingDetail),
        SizedBox(
          height: 4,
          child: held.isLoading || held.detailLoading
              ? const LinearProgressIndicator()
              : null,
        ),
        Expanded(
          child: showingDetail ? const _DetailBody() : const _ListBody(),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.showingDetail});
  final bool showingDetail;

  @override
  Widget build(BuildContext context) {
    final held = context.read<HeldSalesController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          if (showingDetail)
            IconButton(
              tooltip: 'Back to held sales',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () {
                context.read<CartController>().clearError();
                held.closeDetail();
              },
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                showingDetail ? 'Held sale' : 'Held sales',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          if (!showingDetail)
            IconButton(
              tooltip: 'Refresh held sales',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: held.isLoading ? null : held.refresh,
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: 'Close',
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------- list

class _ListBody extends StatelessWidget {
  const _ListBody();

  @override
  Widget build(BuildContext context) {
    final held = context.watch<HeldSalesController>();
    switch (held.status) {
      case HeldListStatus.idle:
      case HeldListStatus.loading:
        return const LoadingView(label: 'Loading held sales');
      case HeldListStatus.error:
        final e = held.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? held.refresh
              : null,
        );
      case HeldListStatus.empty:
        return const EmptyView(
          title: 'No held sales',
          message: 'Sales you put on hold will appear here.',
          icon: Icons.pause_circle_outline,
        );
      case HeldListStatus.loaded:
        return Column(
          children: [
            if (held.error != null)
              _Notice(
                message: describeApiError(held.error!),
                action: held.error!.isRetryable
                    ? TextButton(
                        onPressed: held.refresh,
                        child: const Text('Retry'),
                      )
                    : null,
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: held.sales.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _HeldSaleCard(sale: held.sales[i]),
              ),
            ),
          ],
        );
    }
  }
}

class _HeldSaleCard extends StatelessWidget {
  const _HeldSaleCard({required this.sale});
  final HeldSaleSummary sale;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = sale.heldAt ?? sale.updatedAt ?? sale.createdAt;
    final lines = <String>[
      if (sale.salesmanId != null && sale.salesmanId!.isNotEmpty)
        'Staff: ${sale.salesmanId}',
      if (when != null) 'Held ${formatTimestamp(when)}',
      if (sale.createdAt != null && sale.heldAt != null)
        'Started ${formatTimestamp(sale.createdAt!)}',
    ];
    return Semantics(
      button: true,
      label: '${sale.title}, ${lines.join(', ')}',
      child: Card(
        margin: EdgeInsets.zero,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => context.read<HeldSalesController>().openDetail(sale.id),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 72),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(sale.title, style: theme.textTheme.titleMedium),
                        for (final l in lines)
                          Text(l, style: theme.textTheme.bodySmall),
                      ],
                    ),
                  ),
                  if (sale.grandTotal != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      formatMoney(sale.grandTotal),
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                  const Icon(Icons.chevron_right),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------- detail

class _DetailBody extends StatelessWidget {
  const _DetailBody();

  @override
  Widget build(BuildContext context) {
    final held = context.watch<HeldSalesController>();
    final cart = context.watch<CartController>();
    final session = context.watch<SessionController>();
    final id = held.detailSaleId!;

    if (held.detailLoading && held.detail == null) {
      return const LoadingView(label: 'Loading sale');
    }
    if (held.detailError != null) {
      final e = held.detailError!;
      return ErrorView(
        message: describeApiError(e),
        onRetry: (e.isRetryable) ? () => held.openDetail(id) : null,
      );
    }
    final sale = held.detail;
    if (sale == null) return const LoadingView(label: 'Loading sale');

    final resumable = sale.status == 'held';
    final resumeError =
        (cart.error != null &&
            (cart.errorOperation == CartOperation.resume ||
                cart.errorOperation == CartOperation.cancelHeld))
        ? cart.error
        : null;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resumeError != null)
          _Notice(
            message: describeApiError(resumeError),
            onDismiss: cart.clearError,
          ),
        if (!resumable)
          _Notice(
            message: sale.status == 'draft'
                ? 'This sale has already been resumed and is now an open draft. It cannot be resumed again.'
                : 'This sale is ${sale.status} and is read-only. It cannot be resumed.',
            tone: _Tone.info,
          ),
        Expanded(
          child: sale.items.isEmpty
              ? const EmptyView(
                  title: 'No items',
                  icon: Icons.shopping_cart_outlined,
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: sale.items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (_, i) => _DetailLine(line: sale.items[i]),
                ),
        ),
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              _row(context, 'Subtotal', sale.totals.subtotal),
              _row(context, 'Tax', sale.totals.taxTotal),
              if (sale.totals.discountTotal != null)
                _row(context, 'Discount', sale.totals.discountTotal),
              _row(context, 'Total', sale.totals.grandTotal, bold: true),
              const SizedBox(height: 12),
              FilledButton.icon(
                // Phase C5: disabled when the loaded permissions lack sales.resume.
                onPressed: (resumable && !cart.isMutating && !session.isDenied('sales.resume'))
                    ? () => _resume(context, sale)
                    : null,
                icon: cart.isMutating
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow),
                label: Text(
                  cart.hasActiveDraftWithItems
                      ? 'Hold current & resume'
                      : 'Resume sale',
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
              // Hidden (not just disabled) once the loaded permission context
              // positively lacks sales.cancel — see
              // SessionController.isDenied.
              if (!session.isDenied('sales.cancel'))
                TextButton.icon(
                  onPressed: (resumable && !cart.isMutating)
                      ? () => _void(context, sale)
                      : null,
                  icon: const Icon(Icons.block),
                  label: const Text('Void sale'),
                  style: TextButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    foregroundColor: theme.colorScheme.error,
                  ),
                ),
              if (resumable && cart.hasActiveDraftWithItems)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'Your open sale will be put on hold first, so nothing is lost.',
                    style: theme.textTheme.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _row(
    BuildContext context,
    String label,
    double? v, {
    bool bold = false,
  }) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: style),
          Text(formatMoney(v), style: style),
        ],
      ),
    );
  }

  /// Voids the held sale (`POST /sales/:id/cancel`) after a confirmation.
  Future<void> _void(BuildContext context, CartSale detail) async {
    final cart = context.read<CartController>();
    final held = context.read<HeldSalesController>();
    final messenger = ScaffoldMessenger.of(context);
    final ok = await confirmVoid(context, subject: 'held sale #${detail.id}');
    if (ok != true) return;
    if (await cart.cancelHeldSale(
      saleId: detail.id,
      expectedVersion: detail.version,
    )) {
      held.removeLocally(detail.id);
      held.closeDetail();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Sale #${detail.id} voided')),
      );
    } else if (cart.error != null) {
      // Show the sale as it is now, so the cashier can review it.
      unawaited(held.openDetail(detail.id));
    }
  }

  Future<void> _resume(BuildContext context, CartSale detail) async {
    final cart = context.read<CartController>();
    final held = context.read<HeldSalesController>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    var holdFirst = false;
    if (cart.hasActiveDraftWithItems) {
      final count = cart.sale!.itemCount;
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('You have an open sale'),
          content: Text(
            'The current sale has $count ${count == 1 ? 'item' : 'items'}. '
            'It will be put on hold first so nothing is lost, and then this sale will be resumed.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Hold current & resume'),
            ),
          ],
        ),
      );
      if (ok != true) return;
      holdFirst = true;
    }

    final ok = await cart.resumeHeldSale(
      saleId: detail.id,
      expectedVersion: detail.version,
      holdCurrentFirst: holdFirst,
    );
    if (ok) {
      held.removeLocally(detail.id);
      held.closeDetail();
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(content: Text('Sale #${detail.id} resumed')),
      );
      if (navigator.canPop()) navigator.pop();
    } else if (cart.error != null) {
      // Show the affected sale as it is now, so the cashier can review it.
      unawaited(held.openDetail(detail.id));
    }
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.line});
  final CartLine line;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.productName ?? 'Item ${line.productVariationId}',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  line.isUnavailable
                      ? 'No longer available'
                      : '${line.quantityText} × ${formatMoney(line.unitPrice)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatMoney(line.lineTotal), style: theme.textTheme.titleSmall),
        ],
      ),
    );
  }
}

enum _Tone { error, info }

class _Notice extends StatelessWidget {
  const _Notice({
    required this.message,
    this.action,
    this.onDismiss,
    this.tone = _Tone.error,
  });
  final String message;
  final Widget? action;
  final VoidCallback? onDismiss;
  final _Tone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = tone == _Tone.error
        ? scheme.errorContainer
        : scheme.secondaryContainer;
    final fg = tone == _Tone.error
        ? scheme.onErrorContainer
        : scheme.onSecondaryContainer;
    return Semantics(
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(message, style: TextStyle(color: fg)),
            ),
            ?action,
            if (onDismiss != null)
              IconButton(
                tooltip: 'Dismiss',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onDismiss,
                icon: Icon(Icons.close, color: fg),
              ),
          ],
        ),
      ),
    );
  }
}
