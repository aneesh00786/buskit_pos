import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../data/promotion_service.dart';
import '../models/promotion.dart';
import '../state/promotion_list_controller.dart';
import '../../../core/ui/safe_insets.dart';

/// Opens a read-only Promotions browser: a wide dialog (list + detail
/// side-by-side) on tablets, a tall bottom sheet on phones — same shape as
/// `showCustomers`/`showSalesHistory`. There is no create/edit/delete/
/// activate anywhere here — promotions are defined entirely by the existing
/// Admin/Web system; POS only displays what's already there.
Future<void> showPromotions(BuildContext context) {
  final client = context.read<PosApiClient>();
  final controller = PromotionListController(ApiPromotionService(client));
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<PromotionListController>.value(
    value: controller,
    child: const PromotionsView(),
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
    builder: (_) => SizedBox(
      height: size.height * 0.92,
      child: SheetSafeArea(child: content()),
    ),
  ).whenComplete(controller.dispose);
}

class PromotionsView extends StatefulWidget {
  const PromotionsView({super.key});

  @override
  State<PromotionsView> createState() => _PromotionsViewState();
}

class _PromotionsViewState extends State<PromotionsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<PromotionListController>().loadInitial();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PromotionListController>();
    return LayoutBuilder(
      builder: (context, box) {
        final sideBySide = box.maxWidth >= 640;
        final showingDetail = c.selected != null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(showingDetail: !sideBySide && showingDetail),
            SizedBox(
              height: 4,
              child: c.status == PromotionListStatus.loading
                  ? const LinearProgressIndicator()
                  : null,
            ),
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
                                  title: 'Select a promotion',
                                  message: 'Choose an offer on the left to see its details.',
                                  icon: Icons.local_offer_outlined,
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
    final c = context.read<PromotionListController>();
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      child: Row(
        children: [
          if (showingDetail)
            IconButton(
              tooltip: 'Back to promotions',
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
                showingDetail ? 'Promotion details' : 'Promotions',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
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

class _ListBody extends StatelessWidget {
  const _ListBody();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<PromotionListController>();
    switch (c.status) {
      case PromotionListStatus.idle:
      case PromotionListStatus.loading:
        return const LoadingView(label: 'Loading promotions');
      case PromotionListStatus.error:
        final e = c.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? c.retry
              : null,
        );
      case PromotionListStatus.empty:
        return const EmptyView(
          title: 'No promotions available',
          message: 'Check back later for new offers.',
          icon: Icons.local_offer_outlined,
        );
      case PromotionListStatus.loaded:
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
              final promotion = c.items[i];
              return _PromotionCard(
                promotion: promotion,
                selected: promotion.id == c.selected?.id,
              );
            },
          ),
        );
    }
  }
}

class _PromotionCard extends StatelessWidget {
  const _PromotionCard({required this.promotion, required this.selected});
  final Promotion promotion;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      selected: selected,
      label: '${promotion.title}, ${promotion.discountLabel}',
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
          borderRadius: BorderRadius.circular(PosTokens.rCard),
          onTap: () =>
              context.read<PromotionListController>().select(promotion),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: t.heroGradient,
                    ),
                  ),
                  child: const Icon(
                    Icons.local_offer_outlined,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: PosTokens.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        promotion.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        promotion.discountLabel,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
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
    final c = context.watch<PromotionListController>();
    final promotion = c.selected;
    if (promotion == null) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(PosTokens.s16),
      children: [
        Text(
          promotion.title,
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: PosTokens.s4),
        Text(
          promotion.discountLabel,
          style: theme.textTheme.titleMedium?.copyWith(
            color: theme.colorScheme.primary,
            fontWeight: FontWeight.w700,
          ),
        ),
        if (promotion.description != null &&
            promotion.description!.isNotEmpty) ...[
          const SizedBox(height: PosTokens.s12),
          Text(promotion.description!),
        ],
        const Divider(height: PosTokens.s24),
        if (promotion.minOrderValue != null)
          _KeyValue(
            'Minimum purchase',
            formatMoney(promotion.minOrderValue),
            icon: Icons.shopping_bag_outlined,
          ),
        if (promotion.maxDiscount != null)
          _KeyValue(
            'Maximum discount',
            formatMoney(promotion.maxDiscount),
            icon: Icons.trending_down,
          ),
        _KeyValue(
          'Valid until',
          promotion.endDate == null
              ? 'No expiry'
              : formatTimestamp(promotion.endDate!),
          icon: Icons.event_outlined,
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
            width: 140,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
