import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../promotions/data/promotion_service.dart';
import '../../promotions/models/promotion.dart';
import '../state/cart_controller.dart';
import '../../../core/ui/safe_insets.dart';

/// "Add Promotion" / "Change Promotion": only the promotions CURRENTLY
/// eligible for this sale (`GET /sales/:id/promotions`), each already
/// carrying its computed discount — tapping one calls the backend, which
/// recalculates and returns the updated sale. Nothing discount-related is
/// ever computed here. No create/edit/delete — this is a selection sheet,
/// not promotion management.
Future<void> showPromotionPicker(BuildContext context) {
  final client = context.read<PosApiClient>();
  final cart = context.read<CartController>();
  final saleId = cart.sale?.id;
  if (saleId == null) return Future<void>.value();
  final service = ApiPromotionService(client);

  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider<CartController>.value(
      value: cart,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: SheetSafeArea(
          child: _PromotionPicker(service: service, saleId: saleId),
        ),
      ),
    ),
  );
}

class _PromotionPicker extends StatefulWidget {
  const _PromotionPicker({required this.service, required this.saleId});
  final PromotionService service;
  final int saleId;

  @override
  State<_PromotionPicker> createState() => _PromotionPickerState();
}

class _PromotionPickerState extends State<_PromotionPicker> {
  late Future<List<AppliedPromotion>> _future;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    _future = widget.service.listEligibleForSale(widget.saleId);
  }

  void _reload() {
    setState(() => _future = widget.service.listEligibleForSale(widget.saleId));
  }

  Future<void> _apply(AppliedPromotion p) async {
    if (_applying) return;
    setState(() => _applying = true);
    final ok = await context.read<CartController>().applyPromotion(p.id);
    if (!mounted) return;
    setState(() => _applying = false);
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Eligible Promotions',
                  style: Theme.of(context).textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
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
          child: FutureBuilder<List<AppliedPromotion>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                final e = snapshot.error;
                final message = e is ApiException
                    ? describeApiError(e)
                    : 'Something went wrong.';
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(message, textAlign: TextAlign.center),
                        const SizedBox(height: PosTokens.s12),
                        FilledButton(
                          onPressed: _reload,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                );
              }
              final items = snapshot.data ?? const [];
              if (items.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No promotions are eligible for this sale right now.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                itemCount: items.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (_, i) => _PromotionRow(
                  promotion: items[i],
                  enabled: !_applying,
                  onTap: () => _apply(items[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PromotionRow extends StatelessWidget {
  const _PromotionRow({
    required this.promotion,
    required this.enabled,
    required this.onTap,
  });
  final AppliedPromotion promotion;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(PosTokens.rCard),
        border: Border.all(color: t.border),
        boxShadow: t.cardShadow,
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(PosTokens.rCard),
        onTap: enabled ? onTap : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      promotion.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Saves ${formatMoney(promotion.discountAmount)}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: t.success,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}
