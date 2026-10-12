import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../analytics/data/analytics_service.dart';
import '../../analytics/state/analytics_controller.dart';
import '../../auth/state/session_controller.dart';

/// Phase C5: the backend opens /analytics/summary with ANY one of these.
const _reportPermissions = [
  'reports.sales',
  'reports.cashier',
  'reports.payment',
  'reports.product',
];

/// Right-hand sales summary for very wide screens. Three cards (today's
/// sales, top items, staff performance) show real figures from
/// `GET /analytics/summary` — the same endpoint and controller shape the
/// full Analytics screen uses. "Sales trend" (a day-by-day series) and
/// "Inventory alerts" (stock levels) are NOT part of that summary — POS's
/// own sales tables have neither — so those two stay honest placeholders
/// rather than fabricated figures.
class SalesSummaryPanel extends StatefulWidget {
  const SalesSummaryPanel({super.key});

  @override
  State<SalesSummaryPanel> createState() => _SalesSummaryPanelState();
}

class _SalesSummaryPanelState extends State<SalesSummaryPanel> {
  late final AnalyticsController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnalyticsController(
      ApiAnalyticsService(context.read<PosApiClient>()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // No reporting permission at all (known up front): don't call.
      if (context.read<SessionController>().isDeniedAll(_reportPermissions))
        return;
      _controller.load();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final session = context.watch<SessionController>();
        // Phase C5: no reporting permission (known up front, or the backend's
        // 403) is its own state — never "loading", never "temporarily
        // unavailable".
        final noAccess =
            session.isDeniedAll(_reportPermissions) ||
            (_controller.status == AnalyticsStatus.error &&
                _controller.error?.errorCode == PosErrorCodes.permissionDenied);
        final loading =
            !noAccess &&
            (_controller.status == AnalyticsStatus.idle ||
                _controller.status == AnalyticsStatus.loading);
        // Every card below treats "no access" like "unavailable".
        final failed = noAccess || _controller.status == AnalyticsStatus.error;
        final s = noAccess ? null : _controller.summary;
        final available = !loading && !failed && s != null;

        final topItem = available && s.topProducts.isNotEmpty
            ? s.topProducts.first
            : null;
        final topStaff = available && s.staffPerformance.isNotEmpty
            ? s.staffPerformance.first
            : null;

        return ListView(
          padding: EdgeInsets.zero,
          children: [
            SummaryCard(
              title: "Today's net sales",
              icon: Icons.payments_outlined,
              gradient: true,
              figure: available ? formatMoney(s.sales.netSales) : null,
              message: noAccess
                  ? 'Sales figures need a reporting permission.'
                  : failed
                  ? 'Sales reporting is temporarily unavailable.'
                  : loading
                  ? 'Loading…'
                  : '${s!.sales.completedCount} transaction${s.sales.completedCount == 1 ? '' : 's'} today'
                        '${s.sales.refundsTotal > 0 ? ' · refunds -${formatMoney(s.sales.refundsTotal)}' : ''}',
              showPill: loading || (failed && !noAccess),
            ),
            const SizedBox(height: PosTokens.s12),
            SummaryCard(
              title: 'Top items',
              icon: Icons.emoji_events_outlined,
              message: failed
                  ? 'Not available yet.'
                  : loading
                  ? 'Loading…'
                  : topItem == null
                  ? 'No sales in the last 7 days yet.'
                  : '${topItem.productName ?? 'Item ${topItem.productVariationId}'} — ${formatQty(topItem.quantitySold)} sold',
              showPill: loading || (failed && !noAccess),
            ),
            const SizedBox(height: PosTokens.s12),
            SummaryCard(
              title: 'Staff performance',
              icon: Icons.groups_outlined,
              message: failed
                  ? 'Not available yet.'
                  : loading
                  ? 'Loading…'
                  : topStaff == null
                  ? 'No sales today yet.'
                  : '${topStaff.fullname ?? topStaff.salesmanId} — ${formatMoney(topStaff.salesTotal)}',
              showPill: loading || (failed && !noAccess),
            ),
            const SizedBox(height: PosTokens.s12),
            const SummaryCard(
              title: 'Sales trend',
              icon: Icons.show_chart,
              message: 'Not available yet.',
            ),
            const SizedBox(height: PosTokens.s12),
            const SummaryCard(
              title: 'Inventory alerts',
              icon: Icons.warning_amber_outlined,
              message: 'Not available yet.',
            ),
          ],
        );
      },
    );
  }
}

/// A summary tile. With [gradient] it uses the brand gradient (the "hero"
/// card). [figure] is an optional bold headline (e.g. a money amount);
/// [showPill] (default true) shows a small "Coming soon" pill — set false
/// once real data backs the card.
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
    this.gradient = false,
    this.figure,
    this.showPill = true,
  });

  final String title;
  final IconData icon;
  final String message;
  final bool gradient;
  final String? figure;
  final bool showPill;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final text = Theme.of(context).textTheme;
    final fg = gradient
        ? Colors.white
        : Theme.of(context).colorScheme.onSurface;
    final pillBg = gradient ? Colors.white24 : t.surfaceMuted;

    return Semantics(
      container: true,
      label: '$title. $message',
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s16),
        decoration: gradient
            ? BoxDecoration(
                gradient: LinearGradient(
                  colors: t.heroGradient,
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(PosTokens.rCard),
                boxShadow: t.cardShadow,
              )
            : t.card(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: fg, size: 20),
                const SizedBox(width: PosTokens.s8),
                Expanded(
                  child: Text(
                    title,
                    style: text.titleSmall?.copyWith(color: fg),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (showPill)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: pillBg,
                      borderRadius: BorderRadius.circular(PosTokens.rPill),
                    ),
                    child: Text(
                      'Coming soon',
                      style: text.labelSmall?.copyWith(color: fg),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: PosTokens.s12),
            if (gradient)
              Text(
                figure ?? '—',
                style: text.headlineMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w800,
                ),
              ),
            Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: text.bodySmall?.copyWith(
                color: fg.withValues(alpha: 0.85),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
