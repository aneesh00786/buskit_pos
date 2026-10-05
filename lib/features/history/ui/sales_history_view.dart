import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../checkout/models/payment.dart';
import '../../products/data/product_service.dart';
import '../../receipt/models/receipt_formatter.dart';
import '../../receipt/ui/receipt_actions.dart';
import '../data/sales_history_service.dart';
import '../models/partial_refund.dart';
import '../models/provider_refund.dart';
import '../models/sale_history_entry.dart';
import '../state/sales_history_controller.dart';
import 'partial_refund_view.dart';

/// Opens the completed-sales history: a wide dialog (list + detail
/// side-by-side) on tablets, a tall bottom sheet (list, pushing to detail) on
/// phones. `SessionController` and `PosApiClient` are provided above the app
/// shell, so only a fresh controller needs providing here.
Future<void> showSalesHistory(BuildContext context) {
  final client = context.read<PosApiClient>();
  final controller = SalesHistoryController(
    ApiSalesHistoryService(client),
    ApiProductService(client),
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<SalesHistoryController>.value(
    value: controller,
    child: const SalesHistoryView(),
  );

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 900,
            maxHeight: size.height * 0.9,
          ),
          child: content(),
        ),
      ),
    ).whenComplete(controller.dispose);
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(height: size.height * 0.92, child: content()),
  ).whenComplete(controller.dispose);
}

class SalesHistoryView extends StatefulWidget {
  const SalesHistoryView({super.key});

  @override
  State<SalesHistoryView> createState() => _SalesHistoryViewState();
}

class _SalesHistoryViewState extends State<SalesHistoryView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<SalesHistoryController>().refresh());
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = context.watch<SalesHistoryController>();
    return LayoutBuilder(
      builder: (context, box) {
        final sideBySide = box.maxWidth >= 640;
        final showingDetail = h.detailSaleId != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(showingDetail: !sideBySide && showingDetail),
            SizedBox(
              height: 4,
              child: h.isLoading || h.detailLoading
                  ? const LinearProgressIndicator()
                  : null,
            ),
            if (!sideBySide && !showingDetail) const _Filters(),
            if (sideBySide) const _Filters(),
            Expanded(
              child: sideBySide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: 360, child: const _ListBody()),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: showingDetail
                              ? const _DetailBody()
                              : const EmptyView(
                                  title: 'Select a sale',
                                  message: 'Choose a sale on the left to see its details.',
                                  icon: Icons.receipt_long_outlined,
                                ),
                        ),
                      ],
                    )
                  : (showingDetail ? const _DetailBody() : const _ListBody()),
            ),
          ],
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.showingDetail});
  final bool showingDetail;

  @override
  Widget build(BuildContext context) {
    final h = context.read<SalesHistoryController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          if (showingDetail)
            IconButton(
              tooltip: 'Back to sales history',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: h.closeDetail,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                showingDetail ? 'Sale details' : 'Sales history',
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          if (!showingDetail)
            IconButton(
              tooltip: 'Refresh sales history',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: h.isLoading ? null : h.refresh,
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

// -------------------------------------------------------------- filters

class _Filters extends StatefulWidget {
  const _Filters();

  @override
  State<_Filters> createState() => _FiltersState();
}

class _FiltersState extends State<_Filters> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) context.read<SalesHistoryController>().setQuery(text.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = context.watch<SalesHistoryController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Wrap(
        spacing: PosTokens.s8,
        runSpacing: PosTokens.s8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          SizedBox(
            width: 220,
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search),
                hintText: 'Search order number',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          SegmentedButton<HistoryDateFilter>(
            segments: const [
              ButtonSegment(
                value: HistoryDateFilter.today,
                label: Text('Today'),
              ),
              ButtonSegment(value: HistoryDateFilter.all, label: Text('All')),
            ],
            selected: {h.dateFilter},
            onSelectionChanged: (s) => h.setDateFilter(s.first),
          ),
          if (h.knownCashiers.length > 1)
            DropdownMenu<String?>(
              width: 160,
              label: const Text('Cashier'),
              initialSelection: h.cashierFilter,
              onSelected: h.setCashierFilter,
              dropdownMenuEntries: [
                const DropdownMenuEntry(value: null, label: 'All cashiers'),
                for (final c in h.knownCashiers)
                  DropdownMenuEntry(value: c, label: c),
              ],
            ),
          Tooltip(
            message:
                'Filtering by payment method needs each sale\'s '
                'payment details, which the sales list does not include yet',
            child: FilterChip(
              label: const Text('Payment method'),
              avatar: const Icon(Icons.payments_outlined, size: 18),
              onSelected: null,
            ),
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
    final h = context.watch<SalesHistoryController>();
    switch (h.status) {
      case HistoryListStatus.idle:
      case HistoryListStatus.loading:
        return const LoadingView(label: 'Loading sales history');
      case HistoryListStatus.error:
        final e = h.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? h.refresh
              : null,
        );
      case HistoryListStatus.empty:
        return const EmptyView(
          title: 'No completed sales',
          message: 'Sales you complete will appear here.',
          icon: Icons.receipt_long_outlined,
        );
      case HistoryListStatus.loaded:
        final page = h.pageItems;
        if (page.isEmpty) {
          return const EmptyView(
            title: 'No sales match these filters',
            icon: Icons.filter_alt_off_outlined,
          );
        }
        return Column(
          children: [
            if (h.error != null)
              _Notice(
                message: describeApiError(h.error!),
                action: h.error!.isRetryable
                    ? TextButton(
                        onPressed: h.refresh,
                        child: const Text('Retry'),
                      )
                    : null,
              ),
            Expanded(
              child: ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: page.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _SaleCard(
                  sale: page[i],
                  selected: page[i].id == h.detailSaleId,
                ),
              ),
            ),
            if (h.totalPages > 1) _Pager(h: h),
          ],
        );
    }
  }
}

class _Pager extends StatelessWidget {
  const _Pager({required this.h});
  final SalesHistoryController h;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          IconButton(
            tooltip: 'Previous page',
            onPressed: h.page > 1 ? () => h.setPage(h.page - 1) : null,
            icon: const Icon(Icons.chevron_left),
          ),
          Text('Page ${h.page} of ${h.totalPages}'),
          IconButton(
            tooltip: 'Next page',
            onPressed: h.page < h.totalPages
                ? () => h.setPage(h.page + 1)
                : null,
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _SaleCard extends StatelessWidget {
  const _SaleCard({required this.sale, required this.selected});
  final SaleHistoryEntry sale;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    final when = sale.when;
    final lines = <String>[
      if (sale.salesmanId != null && sale.salesmanId!.isNotEmpty)
        'Staff: ${sale.salesmanId}',
      if (when != null) formatTimestamp(when),
      if (sale.customerId != null) 'Customer ${sale.customerId}',
    ];
    return Semantics(
      button: true,
      selected: selected,
      label: [
        sale.displayNumber,
        ?sale.refundStatus.label,
        ...lines,
      ].join(', '),
      child: Card(
        margin: EdgeInsets.zero,
        color: selected ? t.surfaceMuted : null,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () =>
              context.read<SalesHistoryController>().selectSale(sale.id),
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
                        Text(
                          sale.displayNumber,
                          style: theme.textTheme.titleMedium,
                        ),
                        if (sale.refundStatus != SaleRefundStatus.none)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: RefundStatusBadge(status: sale.refundStatus),
                          ),
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

class _Notice extends StatelessWidget {
  const _Notice({required this.message, this.action});
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      width: double.infinity,
      color: t.danger.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(message, style: TextStyle(color: t.danger)),
          ),
          ?action,
        ],
      ),
    );
  }
}

// -------------------------------------------------------------- detail

class _DetailBody extends StatelessWidget {
  const _DetailBody();

  @override
  Widget build(BuildContext context) {
    final h = context.watch<SalesHistoryController>();
    if (h.detailLoading && h.detail == null) {
      return const LoadingView(label: 'Loading sale');
    }
    if (h.detailError != null && h.detail == null) {
      final e = h.detailError!;
      return ErrorView(
        message: describeApiError(e),
        onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
            ? () => h.selectSale(h.detailSaleId!)
            : null,
      );
    }
    final sale = h.detail;
    if (sale == null) return const SizedBox.shrink();

    final session = context.read<SessionController>();
    final receipt = ReceiptFormatter.build(
      sale: sale,
      names: h.detailNames,
      staffId: session.salesmanId,
      deviceId: session.deviceIdentifier,
    );

    return ListView(
      padding: const EdgeInsets.all(PosTokens.s16),
      children: [
        Wrap(
          spacing: PosTokens.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(sale.displayNumber, style: Theme.of(context).textTheme.titleLarge),
            RefundStatusBadge(status: sale.refundStatus),
          ],
        ),
        if (sale.completedAt != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(formatTimestamp(sale.completedAt!)),
          ),
        const SizedBox(height: PosTokens.s8),
        Text(
          sale.customerId != null
              ? 'Customer ${sale.customerId}'
              : 'Guest checkout',
        ),
        const Divider(height: PosTokens.s24),
        Text('Items', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: PosTokens.s4),
        for (final line in sale.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        h.detailNames[line.productVariationId] ??
                            'Item ${line.productVariationId}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${line.quantity} × ${formatMoney(line.unitPrice)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (sale.refundedQuantity(line) > 0)
                        Text(
                          'Refunded ${sale.refundedQuantity(line)} of ${line.quantity}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: PosTokens.s8),
                Text(formatMoney(line.lineTotal)),
              ],
            ),
          ),
        const Divider(height: PosTokens.s24),
        _KeyValue('Subtotal', formatMoney(sale.totals.subtotal)),
        _KeyValue('Tax', formatMoney(sale.totals.taxTotal)),
        if ((sale.totals.discountTotal ?? 0) != 0)
          _KeyValue('Discount', '-${formatMoney(sale.totals.discountTotal)}'),
        _KeyValue('Total', formatMoney(sale.totals.grandTotal), bold: true),
        const Divider(height: PosTokens.s24),
        Text('Payments', style: Theme.of(context).textTheme.titleSmall),
        for (final p in sale.payments)
          _KeyValue(
            TenderMethod.fromWire(p.method)?.label ?? p.method,
            formatMoney(p.amount),
          ),
        const SizedBox(height: PosTokens.s16),
        _RefundSection(sale: sale, names: h.detailNames),
        const SizedBox(height: PosTokens.s16),
        ReceiptActions(receipt: receipt),
      ],
    );
  }
}

/// Refund actions and history. Whole-sale refund (17.1) is offered only
/// while nothing has been refunded yet (D8); "Refund items" (17.8) stays
/// available until every line is used up. Visibility is a convenience, NOT
/// authorization: the backend is the only thing that ever decides whether a
/// refund is actually allowed, and a 403 here is handled exactly like any
/// other API failure.
/// Money returned through the payment provider (e.g. Razorpay UPI): the
/// provider's status per refund, and a status check while any is pending.
class _ProviderRefundsBox extends StatelessWidget {
  const _ProviderRefundsBox({required this.sale});
  final CompletedSale sale;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const Key('provider-refunds'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Refunds to the original payment', style: text.titleSmall),
        const SizedBox(height: PosTokens.s8),
        for (final r in sale.providerRefunds)
          Padding(
            padding: const EdgeInsets.only(bottom: PosTokens.s4),
            child: Row(
              children: [
                Icon(
                  switch (r.status) {
                    ProviderRefundStatus.succeeded => Icons.check_circle,
                    ProviderRefundStatus.failed => Icons.error,
                    _ => Icons.schedule,
                  },
                  size: 18,
                  color: r.status == ProviderRefundStatus.failed ? scheme.error : null,
                ),
                const SizedBox(width: PosTokens.s8),
                Expanded(child: Text('${r.providerLabel} · ${formatMoney(r.amount)} — ${r.statusText}')),
              ],
            ),
          ),
        if (sale.hasPendingProviderRefunds)
          Consumer<SalesHistoryController>(
            builder: (context, h, _) => Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const Key('check-provider-refunds'),
                onPressed: h.isRefreshingProviderRefunds ? null : h.refreshProviderRefunds,
                icon: const Icon(Icons.refresh),
                label: Text(h.isRefreshingProviderRefunds ? 'Checking…' : 'Check refund status'),
              ),
            ),
          ),
      ],
    );
  }
}

class _RefundSection extends StatelessWidget {
  const _RefundSection({required this.sale, required this.names});
  final CompletedSale sale;
  final Map<int, String> names;

  @override
  Widget build(BuildContext context) {
    final refund = sale.refund;
    final status = sale.refundStatus;
    final children = <Widget>[];

    if (refund != null) {
      children.add(
        _RefundedBox(
          title: 'Refunded ${formatMoney(refund.refundAmount)}',
          detail: [
            'by ${refund.refundedBy}',
            if (refund.refundedAt != null) formatTimestamp(refund.refundedAt!),
          ].join(' · '),
        ),
      );
    } else if (status == SaleRefundStatus.full) {
      children.add(
        _RefundedBox(
          title: 'Fully refunded ${formatMoney(sale.refundedTotal)}',
          detail: '${sale.refunds.length} refund${sale.refunds.length == 1 ? '' : 's'}',
        ),
      );
    }
    if (sale.refunds.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: PosTokens.s12));
      children.add(PartialRefundHistory(sale: sale, names: names));
    }
    if (sale.providerRefunds.isNotEmpty) {
      if (children.isNotEmpty) children.add(const SizedBox(height: PosTokens.s12));
      children.add(_ProviderRefundsBox(sale: sale));
    }

    // UI convenience only — SessionController.isDenied hides the actions
    // only when we POSITIVELY know payments.refund is absent (a loaded
    // context that doesn't grant it). If the context hasn't loaded yet or
    // its fetch failed, they stay visible and the backend's own 403 is what
    // actually decides — never hide on missing data alone.
    final session = context.watch<SessionController>();
    final canAct = sale.status == 'completed' &&
        status != SaleRefundStatus.full &&
        !session.isDenied('payments.refund');
    if (canAct) {
      if (children.isNotEmpty) children.add(const SizedBox(height: PosTokens.s12));
      children.add(
        Consumer<SalesHistoryController>(
          builder: (context, h, _) {
            final busy = h.isRefunding;
            final errorColor = Theme.of(context).colorScheme.error;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(bottom: PosTokens.s8),
                    child: Row(
                      children: [
                        SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: PosTokens.s8),
                        Text('Processing refund…'),
                      ],
                    ),
                  ),
                OutlinedButton.icon(
                  onPressed: busy ? null : () => _startItemsRefund(context, h),
                  icon: const Icon(Icons.playlist_remove),
                  label: const Text('Refund items'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: errorColor,
                    side: BorderSide(color: errorColor),
                  ),
                ),
                if (status == SaleRefundStatus.none) ...[
                  const SizedBox(height: PosTokens.s8),
                  OutlinedButton.icon(
                    onPressed: busy ? null : () => _startRefund(context, h),
                    icon: const Icon(Icons.replay_circle_filled_outlined),
                    label: const Text('Refund Sale'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: errorColor,
                      side: BorderSide(color: errorColor),
                    ),
                  ),
                ],
              ],
            );
          },
        ),
      );
    }

    if (children.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  void _showError(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startItemsRefund(BuildContext context, SalesHistoryController h) async {
    final request = await showRefundItemsDialog(context, sale: sale, names: names, controller: h);
    if (request == null || !context.mounted) return;
    final confirmed = await confirmPartialRefund(context, sale: sale, names: names, request: request);
    if (confirmed != true || !context.mounted) return;

    final ok = await h.refundItems(
      sale.id,
      request.lines,
      expectedRefundAmount: request.preview.refundAmount,
      refundMethod: request.refundMethod,
      reason: request.reason,
    );
    if (!context.mounted) return;
    if (ok) {
      final recorded = h.lastPartialRefund;
      final fresh = h.detail ?? sale;
      if (recorded != null) {
        await showPartialRefundResult(context, sale: fresh, names: names, refund: recorded);
      }
      h.clearLastPartialRefund();
      return;
    }
    final err = h.refundError;
    _showError(context, err != null ? describeApiError(err) : 'The refund could not be completed.');
    h.clearRefundError();
  }

  Future<void> _startRefund(
    BuildContext context,
    SalesHistoryController h,
  ) async {
    final confirmed = await confirmRefund(context, sale: sale);
    if (confirmed != true || !context.mounted) return;

    final ok = await h.refundSale(sale.id);
    if (!context.mounted) return;

    if (ok) {
      final refunded = h.detail;
      if (refunded?.refund != null) {
        await showRefundResult(context, sale: refunded!, refund: refunded.refund!);
      }
      return;
    }

    final err = h.refundError;
    _showError(context, err != null ? describeApiError(err) : 'The refund could not be completed.');
    h.clearRefundError();
  }
}

class _RefundedBox extends StatelessWidget {
  const _RefundedBox({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(PosTokens.s12),
      decoration: BoxDecoration(
        color: PosTokens.of(context).surfaceMuted,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.replay_circle_filled_outlined),
          const SizedBox(width: PosTokens.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                Text(detail, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// "Refund this entire sale?" — the 17.1 whole-sale refund, matches
/// [confirmVoid]'s destructive-confirmation shape from the cart. The refund
/// total is always the sale's full grand total; quantity-based refunds use
/// [showRefundItemsDialog] instead.
Future<bool?> confirmRefund(BuildContext context, {required CompletedSale sale}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Refund this entire sale?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Transaction', sale.displayNumber),
          if (sale.completedAt != null)
            _KeyValue('Sale date', formatTimestamp(sale.completedAt!)),
          if (sale.customerId != null)
            _KeyValue('Customer', sale.customerId!),
          const Divider(height: PosTokens.s24),
          _KeyValue('Original total', formatMoney(sale.totals.grandTotal)),
          _KeyValue(
            'Refund amount',
            formatMoney(sale.totals.grandTotal),
            bold: true,
          ),
          const SizedBox(height: PosTokens.s12),
          Text(
            'This refunds the entire sale. To refund only some items, use '
            'Refund items instead. This cannot be undone.',
            style: Theme.of(
              ctx,
            ).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: const Text('Refund Sale'),
        ),
      ],
    ),
  );
}

/// Shown once, right after a successful refund.
Future<void> showRefundResult(
  BuildContext context, {
  required CompletedSale sale,
  required RefundInfo refund,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        Icons.check_circle_outline,
        color: Theme.of(ctx).colorScheme.primary,
        size: 32,
      ),
      title: const Text('Refund successful'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Transaction', sale.displayNumber),
          _KeyValue('Refunded amount', formatMoney(refund.refundAmount)),
          for (final p in sale.payments)
            _KeyValue(
              'Refunded to',
              TenderMethod.fromWire(p.method)?.label ?? p.method,
            ),
          if (refund.refundedAt != null)
            _KeyValue('Date/time', formatTimestamp(refund.refundedAt!)),
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
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value, {this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.w800)
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: PosTokens.s8),
          Text(value, style: style),
        ],
      ),
    );
  }
}
