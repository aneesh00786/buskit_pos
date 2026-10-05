import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../data/analytics_service.dart';
import '../models/analytics_summary.dart';
import '../state/analytics_controller.dart';

/// Read-only sales analytics for this store, computed server-side from
/// POS's own completed sales — no promotion/inventory administration here.
/// "Inventory alerts" is deliberately absent: stock data isn't in the
/// tables this endpoint reads (pos_sales/pos_sale_items/pos_sale_payments).
Future<void> showAnalytics(BuildContext context) {
  final client = context.read<PosApiClient>();
  final controller = AnalyticsController(ApiAnalyticsService(client));
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<AnalyticsController>.value(
    value: controller,
    child: const AnalyticsView(),
  );

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

class AnalyticsView extends StatefulWidget {
  const AnalyticsView({super.key});

  @override
  State<AnalyticsView> createState() => _AnalyticsViewState();
}

class _AnalyticsViewState extends State<AnalyticsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AnalyticsController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<AnalyticsController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Analytics',
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
        _RangeBar(controller: c),
        SizedBox(
          height: 4,
          child: c.status == AnalyticsStatus.loading
              ? const LinearProgressIndicator()
              : null,
        ),
        Expanded(child: _Body(controller: c)),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});
  final AnalyticsController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case AnalyticsStatus.idle:
      case AnalyticsStatus.loading:
        return const LoadingView(label: 'Loading analytics');
      case AnalyticsStatus.error:
        final e = controller.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? controller.retry
              : null,
        );
      case AnalyticsStatus.loaded:
        final s = controller.summary!;
        return ListView(
          padding: const EdgeInsets.all(PosTokens.s16),
          children: [
            _TodaySalesCard(summary: s, custom: controller.hasCustomRange),
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: 'Sales by Payment Method',
              icon: Icons.payments_outlined,
              child: s.paymentBreakdown.isEmpty
                  ? const _EmptyLine('No completed sales today yet.')
                  : Column(
                      children: [
                        for (final p in s.paymentBreakdown)
                          _StatRow(
                            label: _methodLabel(p.method),
                            trailing: formatMoney(p.amount),
                            subtitle:
                                '${p.count} transaction${p.count == 1 ? '' : 's'}',
                          ),
                      ],
                    ),
            ),
            if (s.sales.refundCount > 0) ...[
              const SizedBox(height: PosTokens.s16),
              _SectionCard(
                title: 'Refunds by Method',
                icon: Icons.replay_circle_filled_outlined,
                child: Column(
                  children: [
                    for (final r in s.refundPayouts)
                      _StatRow(
                        label: _methodLabel(r.method),
                        trailing: '-${formatMoney(r.amount)}',
                        subtitle: r.method == 'wallet' ? 'returned to customer wallets' : 'paid out',
                      ),
                    _StatRow(
                      label: 'Total refunds',
                      trailing: '-${formatMoney(s.sales.refundsTotal)}',
                      subtitle:
                          '${s.sales.refundCount} refund${s.sales.refundCount == 1 ? '' : 's'} issued today',
                    ),
                  ],
                ),
              ),
            ],
            if (!s.cashMovements.isEmpty) ...[
              const SizedBox(height: PosTokens.s16),
              _SectionCard(
                title: 'Cash Drawer (not sales)',
                icon: Icons.account_balance_wallet_outlined,
                child: Column(
                  children: [
                    _StatRow(
                      label: 'Cash deposits',
                      trailing: formatMoney(s.cashMovements.deposits),
                      subtitle: '${s.cashMovements.depositCount} deposit${s.cashMovements.depositCount == 1 ? '' : 's'}',
                    ),
                    _StatRow(
                      label: 'Cash withdrawals',
                      trailing: '-${formatMoney(s.cashMovements.withdrawals)}',
                      subtitle: '${s.cashMovements.withdrawalCount} withdrawal${s.cashMovements.withdrawalCount == 1 ? '' : 's'}',
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: controller.hasCustomRange
                  ? 'Top Selling Products (selected period)'
                  : 'Top Selling Products (7 days)',
              icon: Icons.trending_up,
              child: s.topProducts.isEmpty
                  ? _EmptyLine(
                      controller.hasCustomRange
                          ? 'No completed sales in this period.'
                          : 'No completed sales in the last 7 days.',
                    )
                  : Column(
                      children: [
                        // Net of refunds (server figures); gross shown when
                        // anything was refunded.
                        for (final p in s.topProducts)
                          _StatRow(
                            label:
                                p.productName ?? 'Item ${p.productVariationId}',
                            trailing: '${formatQty(p.displayQuantity)} sold',
                            subtitle: p.refundedQuantity > 0
                                ? '${formatMoney(p.displayRevenue)} · '
                                      '${formatQty(p.refundedQuantity)} refunded of ${formatQty(p.quantitySold)}'
                                : formatMoney(p.displayRevenue),
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: controller.hasCustomRange
                  ? 'Staff Performance (selected period)'
                  : 'Staff Performance (today)',
              icon: Icons.groups_outlined,
              child: s.staffPerformance.isEmpty
                  ? _EmptyLine(
                      controller.hasCustomRange
                          ? 'No completed sales in this period.'
                          : 'No completed sales today yet.',
                    )
                  : Column(
                      children: [
                        for (final st in s.staffPerformance)
                          _StatRow(
                            label: st.fullname ?? st.salesmanId,
                            trailing: formatMoney(st.displayTotal),
                            subtitle:
                                '${st.transactionCount} transaction${st.transactionCount == 1 ? '' : 's'}'
                                '${st.refundedTotal > 0 ? ' · gross ${formatMoney(st.salesTotal)}, refunds −${formatMoney(st.refundedTotal)}' : ''}',
                          ),
                      ],
                    ),
            ),
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: 'Inventory Alerts',
              icon: Icons.warning_amber_outlined,
              placeholder: true,
              child: const _EmptyLine(
                'Not available yet — stock levels are not part of POS\'s own sales data.',
              ),
            ),
          ],
        );
    }
  }
}

String _methodLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'card' => 'Card',
  'wallet' => 'Wallet',
  _ => 'Other',
};

class _TodaySalesCard extends StatelessWidget {
  const _TodaySalesCard({required this.summary, this.custom = false});
  final AnalyticsSummary summary;
  final bool custom;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PosTokens.rCard),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: t.heroGradient,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  custom ? 'Net Sales' : "Today's Net Sales",
                  style: const TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: PosTokens.s4),
                Text(
                  formatMoney(summary.sales.netSales),
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: PosTokens.s4),
                // Server figures only: gross of today's completed sales and
                // refunds issued today (net = gross - refunds, server-side).
                Text(
                  'Gross ${formatMoney(summary.sales.grossSales)} · '
                  'Refunds ${summary.sales.refundsTotal == 0 ? formatMoney(0) : '-${formatMoney(summary.sales.refundsTotal)}'}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'Transactions',
                style: TextStyle(color: Colors.white70),
              ),
              Text(
                '${summary.sales.completedCount}',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
    this.placeholder = false,
  });
  final String title;
  final IconData icon;
  final Widget child;
  final bool placeholder;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: t.card(outlined: false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: PosTokens.s8),
              Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
              if (placeholder)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: t.surfaceMuted,
                    borderRadius: BorderRadius.circular(PosTokens.rPill),
                  ),
                  child: Text(
                    'Not available',
                    style: theme.textTheme.labelSmall,
                  ),
                ),
            ],
          ),
          const SizedBox(height: PosTokens.s8),
          child,
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.trailing, this.subtitle});
  final String label;
  final String trailing;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
                if (subtitle != null)
                  Text(subtitle!, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
          Text(
            trailing,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyLine extends StatelessWidget {
  const _EmptyLine(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(text, style: Theme.of(context).textTheme.bodySmall),
    );
  }
}

/// C4.x: which business dates are shown (the store's today by default) and a
/// date-range picker. Dates are the store's business dates; the server turns
/// them into its own time window.
class _RangeBar extends StatelessWidget {
  const _RangeBar({required this.controller});
  final AnalyticsController controller;

  static String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  static DateTime _parse(String s) => DateTime.parse(s);

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final initial = controller.hasCustomRange
        ? DateTimeRange(start: _parse(controller.from!), end: _parse(controller.to!))
        : DateTimeRange(start: today, end: today);
    final picked = await showDateRangePicker(
      context: context,
      // The backend allows ranges of up to 366 days.
      firstDate: today.subtract(const Duration(days: 365)),
      // The store's zone may already be a day ahead of this device.
      lastDate: today.add(const Duration(days: 1)),
      initialDateRange: initial,
      helpText: 'Select dates',
    );
    if (picked == null) return;
    await controller.setRange(_iso(picked.start), _iso(picked.end));
  }

  @override
  Widget build(BuildContext context) {
    final s = controller.summary;
    final custom = controller.hasCustomRange;
    final label = custom
        ? (controller.from == controller.to
              ? controller.from!
              : '${controller.from} – ${controller.to}')
        : 'Today';
    final zone = s?.timezone;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              zone == null ? label : '$label · $zone',
              key: const Key('analytics-range-label'),
              style: Theme.of(context).textTheme.bodySmall,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (custom)
            TextButton(
              key: const Key('analytics-range-today'),
              onPressed: controller.status == AnalyticsStatus.loading
                  ? null
                  : controller.clearRange,
              child: const Text('Today'),
            ),
          OutlinedButton.icon(
            key: const Key('analytics-range-pick'),
            onPressed: controller.status == AnalyticsStatus.loading
                ? null
                : () => _pick(context),
            icon: const Icon(Icons.date_range, size: 18),
            label: const Text('Dates'),
          ),
        ],
      ),
    );
  }
}
