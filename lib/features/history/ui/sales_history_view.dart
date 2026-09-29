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
import '../models/sale_history_entry.dart';
import '../state/sales_history_controller.dart';

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
      label: '${sale.displayNumber}, ${lines.join(', ')}',
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
        Text(sale.displayNumber, style: Theme.of(context).textTheme.titleLarge),
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
        ReceiptActions(receipt: receipt),
      ],
    );
  }
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
          Text(label, style: style),
          Text(value, style: style),
        ],
      ),
    );
  }
}
