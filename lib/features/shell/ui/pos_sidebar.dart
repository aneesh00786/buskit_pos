import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';

enum PosSection {
  sales,
  orders,
  history,
  customers,
  inventory,
  promotions,
  analytics,
  paymentExceptions,
  settings,
}

class _NavItem {
  const _NavItem(
    this.section,
    this.icon,
    this.label, {
    this.placeholder = true,
  });
  final PosSection section;
  final IconData icon;
  final String label;
  final bool placeholder;
}

const _items = [
  _NavItem(PosSection.sales, Icons.point_of_sale, 'Sales', placeholder: false),
  _NavItem(
    PosSection.orders,
    Icons.receipt_long_outlined,
    'Orders',
    placeholder: false,
  ),
  _NavItem(
    PosSection.history,
    Icons.history,
    'Sales history',
    placeholder: false,
  ),
  _NavItem(
    PosSection.customers,
    Icons.people_outline,
    'Customers',
    placeholder: false,
  ),
  _NavItem(
    PosSection.inventory,
    Icons.inventory_2_outlined,
    'Inventory',
    placeholder: false,
  ),
  _NavItem(
    PosSection.promotions,
    Icons.local_offer_outlined,
    'Promotions',
    placeholder: false,
  ),
  _NavItem(
    PosSection.analytics,
    Icons.insights_outlined,
    'Analytics',
    placeholder: false,
  ),
  // Phase 9: only shown when [PosSidebar.onOpenPaymentExceptions] is set
  // (a manager with payments.view_store_exceptions).
  _NavItem(
    PosSection.paymentExceptions,
    Icons.report_gmailerrorred_outlined,
    'Payment exceptions',
    placeholder: false,
  ),
  _NavItem(
    PosSection.settings,
    Icons.settings_outlined,
    'Settings',
    placeholder: false,
  ),
];

/// Dark navigation. Sales is the active section (green highlight); Orders opens
/// the held sales; the remaining sections are placeholders (they say so instead
/// of pretending to work). The footer carries Help, Sign out, the device ID and
/// the app version. [collapsed] shows an icon-only rail.
class PosSidebar extends StatelessWidget {
  const PosSidebar({
    super.key,
    required this.collapsed,
    required this.brandTitle,
    this.brandSubtitle,
    this.deviceLabel,
    this.appVersion,
    this.heldCount,
    this.onOpenOrders,
    this.onOpenHistory,
    this.onOpenCustomers,
    this.onOpenInventory,
    this.onOpenPromotions,
    this.onOpenAnalytics,
    this.onOpenSettings,
    this.onOpenPaymentExceptions,
    this.onHelp,
    this.onSignOut,
    this.onCloseShift,
    this.active = PosSection.sales,
  });

  final bool collapsed;
  final String brandTitle;
  final String? brandSubtitle;

  /// e.g. the registered device identifier.
  final String? deviceLabel;
  final String? appVersion;
  final int? heldCount;
  final VoidCallback? onOpenOrders;
  final VoidCallback? onOpenHistory;
  final VoidCallback? onOpenCustomers;
  final VoidCallback? onOpenInventory;
  final VoidCallback? onOpenPromotions;
  final VoidCallback? onOpenAnalytics;
  final VoidCallback? onOpenSettings;

  /// Phase 9 — the store-wide Payment Exceptions screen; null hides it.
  final VoidCallback? onOpenPaymentExceptions;
  final VoidCallback? onHelp;
  final VoidCallback? onSignOut;

  /// Opens Shift Close; the tile is hidden when null.
  final VoidCallback? onCloseShift;
  final PosSection active;

  static const double expandedWidth = 232;
  static const double collapsedWidth = 76;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Semantics(
      container: true,
      label: 'Navigation',
      child: Container(
        width: collapsed ? collapsedWidth : expandedWidth,
        color: t.sidebar,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Brand(
                collapsed: collapsed,
                title: brandTitle,
                subtitle: brandSubtitle,
              ),
              const SizedBox(height: PosTokens.s8),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PosTokens.s12,
                  ),
                  children: [
                    for (final item in _items.where(
                      (i) =>
                          i.section != PosSection.paymentExceptions ||
                          onOpenPaymentExceptions != null,
                    ))
                      _NavTile(
                        item: item,
                        collapsed: collapsed,
                        selected: item.section == active,
                        badge: item.section == PosSection.orders
                            ? heldCount
                            : null,
                        onTap: switch (item.section) {
                          PosSection.orders => onOpenOrders,
                          PosSection.history => onOpenHistory,
                          PosSection.customers => onOpenCustomers,
                          PosSection.inventory => onOpenInventory,
                          PosSection.promotions => onOpenPromotions,
                          PosSection.analytics => onOpenAnalytics,
                          PosSection.settings => onOpenSettings,
                          PosSection.paymentExceptions =>
                            onOpenPaymentExceptions,
                          _ => null,
                        },
                        tooltip: _tooltip(item),
                      ),
                  ],
                ),
              ),
              Divider(color: t.onSidebar.withValues(alpha: 0.14)),
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  PosTokens.s12,
                  PosTokens.s4,
                  PosTokens.s12,
                  PosTokens.s12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _FooterTile(
                      icon: Icons.help_outline,
                      label: 'Help',
                      collapsed: collapsed,
                      onTap: onHelp,
                    ),
                    if (onCloseShift != null)
                      _FooterTile(
                        icon: Icons.lock_clock,
                        label: 'Close shift',
                        collapsed: collapsed,
                        onTap: onCloseShift,
                      ),
                    _FooterTile(
                      icon: Icons.logout,
                      label: 'Sign out',
                      collapsed: collapsed,
                      onTap: onSignOut,
                    ),
                    if (!collapsed &&
                        (deviceLabel != null || appVersion != null))
                      Padding(
                        padding: const EdgeInsets.fromLTRB(
                          PosTokens.s12,
                          PosTokens.s8,
                          PosTokens.s12,
                          0,
                        ),
                        child: DefaultTextStyle.merge(
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: t.onSidebar.withValues(alpha: 0.65),
                              ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (deviceLabel != null)
                                Text(
                                  'Device $deviceLabel',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              if (appVersion != null)
                                Text(
                                  'Version $appVersion',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _tooltip(_NavItem item) {
    if (item.section == PosSection.orders) {
      return (heldCount ?? 0) > 0 ? 'Held sales ($heldCount)' : 'Held sales';
    }
    return item.label;
  }
}

class _Brand extends StatelessWidget {
  const _Brand({required this.collapsed, required this.title, this.subtitle});
  final bool collapsed;
  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final logo = Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: t.heroGradient,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Icon(Icons.storefront, color: Colors.white, size: 22),
    );
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        PosTokens.s12,
        PosTokens.s16,
        PosTokens.s12,
        PosTokens.s8,
      ),
      child: collapsed
          ? Center(
              child: Semantics(label: title, child: logo),
            )
          : Row(
              children: [
                logo,
                const SizedBox(width: PosTokens.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: text.titleMedium?.copyWith(color: t.onSidebar),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: t.onSidebar.withValues(alpha: 0.65),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.item,
    required this.collapsed,
    required this.selected,
    required this.tooltip,
    this.badge,
    this.onTap,
  });

  final _NavItem item;
  final bool collapsed;
  final bool selected;
  final String tooltip;
  final int? badge;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final fg = selected ? t.onSuccess : t.onSidebar;
    final isPlaceholder = onTap == null && !selected;

    void handleTap() {
      if (onTap != null) {
        onTap!();
      } else if (!selected) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(content: Text('${item.label} is coming soon')),
          );
      }
    }

    final icon = Badge(
      isLabelVisible: (badge ?? 0) > 0,
      label: Text('${badge ?? 0}'),
      child: Icon(
        item.icon,
        color: fg.withValues(alpha: isPlaceholder ? 0.6 : 1),
      ),
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          selected: selected,
          label: item.label,
          child: Material(
            color: selected ? t.success : Colors.transparent,
            borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
              onTap: handleTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PosTokens.s12,
                  ),
                  child: collapsed
                      ? Center(child: icon)
                      : Row(
                          children: [
                            icon,
                            const SizedBox(width: PosTokens.s12),
                            Expanded(
                              child: Text(
                                item.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(
                                      color: fg.withValues(
                                        alpha: isPlaceholder ? 0.75 : 1,
                                      ),
                                      fontWeight: selected
                                          ? FontWeight.w700
                                          : FontWeight.w500,
                                    ),
                              ),
                            ),
                            if (item.placeholder && !selected)
                              const _SoonPill(),
                          ],
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FooterTile extends StatelessWidget {
  const _FooterTile({
    required this.icon,
    required this.label,
    required this.collapsed,
    this.onTap,
  });
  final IconData icon;
  final String label;
  final bool collapsed;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final fg = t.onSidebar.withValues(alpha: 0.9);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Tooltip(
        message: label,
        child: Semantics(
          button: true,
          label: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: PosTokens.s12),
                child: collapsed
                    ? Center(child: Icon(icon, color: fg))
                    : Row(
                        children: [
                          Icon(icon, color: fg),
                          const SizedBox(width: PosTokens.s12),
                          Expanded(
                            child: Text(
                              label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(color: fg),
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SoonPill extends StatelessWidget {
  const _SoonPill();

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: t.onSidebar.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(PosTokens.rPill),
      ),
      child: Text(
        'Soon',
        style: Theme.of(context).textTheme.labelSmall
            ?.copyWith(color: t.onSidebar),
      ),
    );
  }
}
