import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../auth/state/session_controller.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../loyalty/data/loyalty_service.dart';
import '../../loyalty/models/loyalty_profile.dart';
import '../data/customer_service.dart';
import '../models/customer.dart';
import '../state/customer_list_controller.dart';
import 'customer_form.dart';

/// Opens customer management: a wide dialog (list + detail side-by-side) on
/// tablets, a tall bottom sheet (list, pushing to detail) on phones — same
/// shape as `showSalesHistory`. `PosApiClient` is provided above the app
/// shell, so only a fresh controller needs providing here.
Future<void> showCustomers(BuildContext context) {
  final client = context.read<PosApiClient>();
  final controller = CustomerListController(
    ApiCustomerService(client),
    loyaltyService: ApiLoyaltyService(client),
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<CustomerListController>.value(
    value: controller,
    child: const CustomersView(),
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

class CustomersView extends StatefulWidget {
  const CustomersView({super.key});

  @override
  State<CustomersView> createState() => _CustomersViewState();
}

class _CustomersViewState extends State<CustomersView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(context.read<CustomerListController>().loadInitial());
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CustomerListController>();
    return LayoutBuilder(
      builder: (context, box) {
        final sideBySide = box.maxWidth >= 640;
        final showingDetail = c.detailCustomerId != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(showingDetail: !sideBySide && showingDetail),
            SizedBox(
              height: 4,
              child: c.status == CustomerListStatus.loading
                  ? const LinearProgressIndicator()
                  : null,
            ),
            if (!sideBySide && !showingDetail) const _SearchBar(),
            if (sideBySide) const _SearchBar(),
            Expanded(
              child: sideBySide
                  ? Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const SizedBox(width: 360, child: _ListBody()),
                        const VerticalDivider(width: 1),
                        Expanded(
                          child: showingDetail
                              ? const _DetailBody()
                              : const EmptyView(
                                  title: 'Select a customer',
                                  message: 'Choose a customer on the left to see their details.',
                                  icon: Icons.person_outline,
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
    final c = context.read<CustomerListController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          if (showingDetail)
            IconButton(
              tooltip: 'Back to customers',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: c.closeDetail,
              icon: const Icon(Icons.arrow_back),
            )
          else
            const SizedBox(width: 8),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                showingDetail ? 'Customer details' : 'Customers',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ),
          // Phase C5: hidden when the loaded permissions lack customers.create.
          if (!showingDetail && !context.watch<SessionController>().isDenied('customers.create'))
            IconButton(
              tooltip: 'New customer',
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              onPressed: () => showCustomerForm(context),
              icon: const Icon(Icons.person_add_alt_outlined),
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

class _SearchBar extends StatefulWidget {
  const _SearchBar();

  @override
  State<_SearchBar> createState() => _SearchBarState();
}

class _SearchBarState extends State<_SearchBar> {
  final _search = TextEditingController();
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: TextField(
        controller: _search,
        textInputAction: TextInputAction.search,
        onChanged: (v) =>
            context.read<CustomerListController>().onQueryChanged(v),
        onSubmitted: (v) =>
            context.read<CustomerListController>().submitQuery(v),
        decoration: InputDecoration(
          isDense: false,
          filled: true,
          fillColor: t.surfaceMuted,
          contentPadding: const EdgeInsets.symmetric(
            vertical: 14,
            horizontal: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(PosTokens.rPill),
            borderSide: BorderSide.none,
          ),
          prefixIcon: const Icon(Icons.search),
          hintText: 'Search customers by name or phone',
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _search,
            builder: (_, v, _) => v.text.isEmpty
                ? const SizedBox.shrink()
                : IconButton(
                    tooltip: 'Clear search',
                    icon: const Icon(Icons.clear),
                    onPressed: () {
                      _search.clear();
                      context.read<CustomerListController>().submitQuery('');
                    },
                  ),
          ),
        ),
      ),
    );
  }
}

class _ListBody extends StatelessWidget {
  const _ListBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CustomerListController>();
    switch (c.status) {
      case CustomerListStatus.idle:
      case CustomerListStatus.loading:
        return const LoadingView(label: 'Loading customers');
      case CustomerListStatus.error:
        final e = c.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? c.retry
              : null,
        );
      case CustomerListStatus.empty:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              EmptyView(
                title: c.query.isEmpty
                    ? 'No customers yet'
                    : 'No customers found',
                message: c.query.isEmpty
                    ? 'Add your first customer to get started.'
                    : 'Try a different search.',
                icon: Icons.people_outline,
              ),
              if (c.query.isEmpty && !context.watch<SessionController>().isDenied('customers.create'))
                FilledButton.icon(
                  onPressed: () => showCustomerForm(context),
                  icon: const Icon(Icons.person_add_alt_outlined),
                  label: const Text('New Customer'),
                ),
            ],
          ),
        );
      case CustomerListStatus.loaded:
        return NotificationListener<ScrollNotification>(
          onNotification: (n) {
            if (n.metrics.pixels >= n.metrics.maxScrollExtent - 200) {
              c.loadNextPage();
            }
            return false;
          },
          child: ListView.separated(
            padding: const EdgeInsets.all(12),
            itemCount: c.items.length + (c.loadingMore ? 1 : 0),
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (_, i) {
              if (i >= c.items.length) {
                return const Padding(
                  padding: EdgeInsets.all(12),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final customer = c.items[i];
              return _CustomerCard(
                customer: customer,
                selected: customer.customerId == c.detailCustomerId,
              );
            },
          ),
        );
    }
  }
}

/// Small curated gradient palette (kept in the same teal/green family as
/// `PosTokens.heroGradient`, with a few complementary accents) so each
/// customer gets a stable, distinguishable initials avatar without needing a
/// real photo — deterministic per `customerId`, not random per rebuild.
const _avatarPalette = <List<Color>>[
  [Color(0xFF0F766E), Color(0xFF16A34A)],
  [Color(0xFF2563EB), Color(0xFF7C3AED)],
  [Color(0xFFEA580C), Color(0xFFF59E0B)],
  [Color(0xFFDB2777), Color(0xFFE11D48)],
  [Color(0xFF0891B2), Color(0xFF2563EB)],
  [Color(0xFF7C3AED), Color(0xFFDB2777)],
];

List<Color> _avatarColors(String seed) =>
    _avatarPalette[seed.hashCode.abs() % _avatarPalette.length];

String _initials(String fullname) {
  final parts = fullname
      .trim()
      .split(RegExp(r'\s+'))
      .where((p) => p.isNotEmpty)
      .toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts[1].substring(0, 1)).toUpperCase();
}

class CustomerAvatar extends StatelessWidget {
  const CustomerAvatar({
    super.key,
    required this.customer,
    this.size = 44,
    this.fontSize = 16,
  });
  final Customer customer;
  final double size;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = _avatarColors(customer.customerId);
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: Text(
        _initials(customer.fullname),
        style: TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: fontSize,
        ),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  const _CustomerCard({required this.customer, required this.selected});
  final Customer customer;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final subtitle = [
      if (customer.mobileno != null && customer.mobileno!.isNotEmpty)
        customer.mobileno!,
      customer.customerId,
    ].join(' · ');
    return Semantics(
      button: true,
      selected: selected,
      label: '${customer.fullname}, $subtitle',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PosTokens.rCard),
        child: Container(
          decoration: BoxDecoration(
            color: selected ? t.surfaceMuted : t.surface,
            borderRadius: BorderRadius.circular(PosTokens.rCard),
            border: Border.all(
              color: selected ? theme.colorScheme.primary : t.border,
              width: selected ? 1.5 : 1,
            ),
            boxShadow: t.cardShadow,
          ),
          child: InkWell(
            onTap: () => context.read<CustomerListController>().selectCustomer(
              customer.customerId,
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 4,
                    color: selected
                        ? theme.colorScheme.primary
                        : Colors.transparent,
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 68),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            CustomerAvatar(customer: customer),
                            const SizedBox(width: PosTokens.s12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    customer.fullname,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.titleMedium
                                        ?.copyWith(fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (customer.mobileno != null &&
                                          customer.mobileno!.isNotEmpty) ...[
                                        Icon(
                                          Icons.call_outlined,
                                          size: 13,
                                          color: theme.colorScheme.outline,
                                        ),
                                        const SizedBox(width: 4),
                                        Flexible(
                                          child: Text(
                                            customer.mobileno!,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodySmall,
                                          ),
                                        ),
                                        const SizedBox(width: 10),
                                      ],
                                      Icon(
                                        Icons.badge_outlined,
                                        size: 13,
                                        color: theme.colorScheme.outline,
                                      ),
                                      const SizedBox(width: 4),
                                      Flexible(
                                        child: Text(
                                          customer.customerId,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right,
                              color: theme.colorScheme.outline,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  const _DetailBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CustomerListController>();
    if (c.detailLoading && c.detail == null) {
      return const LoadingView(label: 'Loading customer');
    }
    if (c.detailError != null && c.detail == null) {
      final e = c.detailError!;
      return ErrorView(
        message: describeApiError(e),
        onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
            ? () => c.selectCustomer(c.detailCustomerId!)
            : null,
      );
    }
    final customer = c.detail;
    if (customer == null) return const SizedBox.shrink();

    final t = PosTokens.of(context);
    return ListView(
      padding: const EdgeInsets.all(PosTokens.s16),
      children: [
        Row(
          children: [
            CustomerAvatar(customer: customer, size: 56, fontSize: 20),
            const SizedBox(width: PosTokens.s16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    customer.fullname,
                    style: Theme.of(context).textTheme.titleLarge
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: PosTokens.s8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: t.surfaceMuted,
                      borderRadius: BorderRadius.circular(PosTokens.rPill),
                    ),
                    child: Text(
                      customer.customerId,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
            // Phase C5: hidden when the loaded permissions lack customers.edit.
            if (!context.watch<SessionController>().isDenied('customers.edit'))
              TextButton.icon(
                onPressed: () => showCustomerForm(context, edit: customer),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Edit Customer'),
              ),
          ],
        ),
        const SizedBox(height: PosTokens.s16),
        Container(
          padding: const EdgeInsets.symmetric(
            horizontal: PosTokens.s12,
            vertical: PosTokens.s4,
          ),
          decoration: t.card(outlined: false),
          child: Column(
            children: [
              _KeyValue(
                'Phone',
                customer.mobileno ?? '—',
                icon: Icons.call_outlined,
              ),
              _KeyValue(
                'Email',
                customer.email ?? '—',
                icon: Icons.mail_outline,
              ),
              if (customer.status != null) _StatusRow(status: customer.status!),
            ],
          ),
        ),
        _LoyaltySection(controller: c),
        const SizedBox(height: PosTokens.s24),
        Row(
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(width: PosTokens.s8),
            Text('Purchases', style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: PosTokens.s8),
        Container(
          padding: const EdgeInsets.all(PosTokens.s12),
          decoration: t.card(outlined: false),
          child: _PurchaseSection(controller: c),
        ),
      ],
    );
  }
}

/// Points/wallet/tier for the open customer. Hidden entirely (not a "no
/// loyalty" card) when the company has no active program — most companies
/// won't have one configured, and an empty card for every customer would be
/// noise, not information.
class _LoyaltySection extends StatelessWidget {
  const _LoyaltySection({required this.controller});
  final CustomerListController controller;

  @override
  Widget build(BuildContext context) {
    final loading = controller.loyaltyLoading && controller.loyalty == null;
    final error = controller.loyaltyError;
    final loyalty = controller.loyalty;

    if (!loading && error == null && (loyalty == null || !loyalty.enabled)) {
      return const SizedBox.shrink();
    }

    final t = PosTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: PosTokens.s16),
        Row(
          children: [
            Icon(
              Icons.stars_outlined,
              size: 18,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(width: PosTokens.s8),
            Text('Loyalty', style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: PosTokens.s8),
        Container(
          padding: const EdgeInsets.all(PosTokens.s12),
          decoration: t.card(outlined: false),
          child: loading
              ? const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: LinearProgressIndicator(),
                )
              : error != null
              ? _InlineError(
                  message: describeApiError(error),
                  onRetry: controller.retryLoyalty,
                )
              : _LoyaltyStats(profile: loyalty!),
        ),
      ],
    );
  }
}

class _LoyaltyStats extends StatelessWidget {
  const _LoyaltyStats({required this.profile});
  final LoyaltyProfile profile;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (profile.tier != null)
          Padding(
            padding: const EdgeInsets.only(bottom: PosTokens.s8),
            child: Text(
              '${profile.tier!.name} member',
              style: Theme.of(context).textTheme.titleSmall
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        Row(
          children: [
            Expanded(
              child: _SummaryStat(
                icon: Icons.stars_outlined,
                label: 'Points',
                value: formatQty(profile.pointsBalance),
                style: Theme.of(context).textTheme,
              ),
            ),
            const SizedBox(width: PosTokens.s8),
            Expanded(
              child: _SummaryStat(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Wallet',
                value: formatMoney(profile.walletBalance),
                style: Theme.of(context).textTheme,
              ),
            ),
          ],
        ),
        if (profile.nextTier != null)
          Padding(
            padding: const EdgeInsets.only(top: PosTokens.s8),
            child: Text(
              'Spend ${formatMoney(profile.nextTier!.remainingSpend)} more to reach ${profile.nextTier!.name}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.status});
  final int status;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      2 => ('Active customer', PosTokens.of(context).success),
      3 => ('Lead', PosTokens.of(context).warning),
      1 => ('Rejected', PosTokens.of(context).danger),
      10 => ('Deleted', PosTokens.of(context).danger),
      _ => ('Status $status', Theme.of(context).colorScheme.outline),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            Icons.info_outline,
            size: 16,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: PosTokens.s8),
          SizedBox(
            width: 110,
            child: Text('Status', style: Theme.of(context).textTheme.bodySmall),
          ),
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: PosTokens.s8),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          Expanded(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// Summary + history come from one backend call, so they succeed or fail
/// together — shown as a single card with one loading/error state rather
/// than two independently-blank sections.
class _PurchaseSection extends StatelessWidget {
  const _PurchaseSection({required this.controller});
  final CustomerListController controller;

  @override
  Widget build(BuildContext context) {
    if (controller.purchasesLoading && controller.purchases == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(),
      );
    }
    if (controller.purchasesError != null && controller.purchases == null) {
      return _InlineError(
        message: describeApiError(controller.purchasesError!),
        onRetry: controller.retryPurchases,
      );
    }
    if (controller.purchases == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PurchaseSummary(controller: controller),
        const Divider(height: PosTokens.s24),
        Text('Purchase history', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: PosTokens.s4),
        _PurchaseHistory(controller: controller),
      ],
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(PosTokens.s12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(PosTokens.rSmall),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline, size: 18, color: scheme.error),
          const SizedBox(width: PosTokens.s8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: scheme.onErrorContainer),
            ),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class _PurchaseSummary extends StatelessWidget {
  const _PurchaseSummary({required this.controller});
  final CustomerListController controller;

  @override
  Widget build(BuildContext context) {
    final summary = controller.purchases?.summary;
    if (summary == null) return const SizedBox.shrink();
    final theme = Theme.of(context).textTheme;
    return Row(
      children: [
        Expanded(
          child: _SummaryStat(
            icon: Icons.receipt_long_outlined,
            label: 'Transactions',
            value: '${summary.transactionCount}',
            style: theme,
          ),
        ),
        const SizedBox(width: PosTokens.s8),
        Expanded(
          child: _SummaryStat(
            icon: Icons.payments_outlined,
            label: 'Total purchases',
            value: formatMoney(summary.totalPurchases),
            style: theme,
          ),
        ),
        const SizedBox(width: PosTokens.s8),
        Expanded(
          child: _SummaryStat(
            icon: Icons.event_outlined,
            label: 'Last purchase',
            value: summary.lastPurchaseAt == null
                ? 'None yet'
                : formatTimestamp(summary.lastPurchaseAt!),
            style: theme,
          ),
        ),
      ],
    );
  }
}

class _SummaryStat extends StatelessWidget {
  const _SummaryStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.style,
  });
  final IconData icon;
  final String label;
  final String value;
  final TextTheme style;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(PosTokens.s12),
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        borderRadius: BorderRadius.circular(PosTokens.rSmall),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: PosTokens.s4),
          Text(
            label,
            style: style.bodySmall,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            value,
            style: style.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _PurchaseHistory extends StatelessWidget {
  const _PurchaseHistory({required this.controller});
  final CustomerListController controller;

  @override
  Widget build(BuildContext context) {
    final page = controller.purchases;
    if (page == null) return const SizedBox.shrink();
    if (page.items.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Text('No completed sales yet.'),
      );
    }
    final theme = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final p in page.items)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(p.displayNumber, style: theme.titleSmall),
                      if (p.completedAt != null)
                        Text(
                          formatTimestamp(p.completedAt!),
                          style: theme.bodySmall,
                        ),
                    ],
                  ),
                ),
                Text(formatMoney(p.grandTotal)),
              ],
            ),
          ),
        if (page.hasMore)
          Center(
            child: TextButton(
              onPressed: controller.purchasesLoading
                  ? null
                  : controller.loadMorePurchases,
              child: controller.purchasesLoading
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Load more'),
            ),
          ),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value, {this.icon});
  final String label;
  final String value;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 16, color: Theme.of(context).colorScheme.outline),
            const SizedBox(width: PosTokens.s8),
          ],
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
