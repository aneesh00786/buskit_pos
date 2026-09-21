import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';

/// Right-hand sales summary for very wide screens. The backend has no
/// reporting endpoints yet, so every card is a clearly labelled placeholder —
/// no figures are invented and nothing calls an API.
class SalesSummaryPanel extends StatelessWidget {
  const SalesSummaryPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: const [
        SummaryCard(
          title: "Today's sales",
          icon: Icons.payments_outlined,
          gradient: true,
          message: 'Sales reporting is not available yet.',
        ),
        SizedBox(height: PosTokens.s12),
        SummaryCard(
          title: 'Top items',
          icon: Icons.emoji_events_outlined,
          message: 'Not available yet.',
        ),
        SizedBox(height: PosTokens.s12),
        SummaryCard(
          title: 'Staff performance',
          icon: Icons.groups_outlined,
          message: 'Not available yet.',
        ),
        SizedBox(height: PosTokens.s12),
        SummaryCard(
          title: 'Sales trend',
          icon: Icons.show_chart,
          message: 'Not available yet.',
        ),
        SizedBox(height: PosTokens.s12),
        SummaryCard(
          title: 'Inventory alerts',
          icon: Icons.warning_amber_outlined,
          message: 'Not available yet.',
        ),
      ],
    );
  }
}

/// A summary tile. With [gradient] it uses the brand gradient (the "hero" card).
class SummaryCard extends StatelessWidget {
  const SummaryCard({
    super.key,
    required this.title,
    required this.icon,
    required this.message,
    this.gradient = false,
  });

  final String title;
  final IconData icon;
  final String message;
  final bool gradient;

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
                '—',
                style: text.headlineMedium?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w800,
                ),
              ),
            Text(
              message,
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
