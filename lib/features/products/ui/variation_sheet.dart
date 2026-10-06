import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/ui/quantity_stepper.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/quantity.dart';
import '../../cart/state/cart_controller.dart';
import '../../cart/ui/quantity_dialog.dart';
import '../models/product_group.dart';
import '../models/product_item.dart';
import 'product_card.dart';

/// Lets the cashier pick a variation and a whole-number quantity, then adds
/// it to the cart. The variation's numeric `id` is what is sent to the API.
/// Price/tax text is shown exactly as returned by the server.
Future<void> showVariationSheet(BuildContext context, ProductGroup group) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => ChangeNotifierProvider.value(
      value: context.read<CartController>(),
      child: VariationSheet(group: group),
    ),
  );
}

class VariationSheet extends StatefulWidget {
  const VariationSheet({super.key, required this.group});
  final ProductGroup group;

  @override
  State<VariationSheet> createState() => _VariationSheetState();
}

class _VariationSheetState extends State<VariationSheet> {
  late ProductItem _selected = widget.group.first;
  int _qty = 1;

  String? _label(ProductItem v) {
    final parts = [
      v.variationName,
      v.unitType,
    ].where((x) => x != null && x.trim().isNotEmpty);
    return parts.isEmpty ? null : parts.join(' · ');
  }

  Future<void> _add() async {
    final cart = context.read<CartController>();
    // Phase 12B: a variation sold by weight asks for the weight (the existing
    // quantity dialog in weight mode); pieces use the stepper as before.
    num quantity = _qty;
    if (_selected.isWeight) {
      final w = await showQuantityDialog(
        context,
        initial: 1,
        itemName: widget.group.name,
        weight: true,
      );
      if (w == null || !mounted) return;
      quantity = w;
    }
    final ok = await cart.addItem(
      _selected.id,
      quantity,
      label: _label(_selected),
      imageUrl: _selected.imageUrl ?? widget.group.imageUrl,
      sellingMode: _selected.sellingMode,
    );
    if (ok && mounted) {
      final name = widget.group.name;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Added ${formatQuantity(quantity, weight: _selected.isWeight)} × $name to the cart',
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final theme = Theme.of(context);
    final p = _selected.pricing;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Semantics(
              header: true,
              child: Text(widget.group.name, style: theme.textTheme.titleLarge),
            ),
            const SizedBox(height: 8),
            for (final v in widget.group.variations)
              _VariationTile(
                item: v,
                selected: v.id == _selected.id,
                onTap: cart.isMutating
                    ? null
                    : () => setState(() => _selected = v),
              ),
            const Divider(height: 24),
            Row(
              children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: formatMoney(p.sellPrice),
                          style: theme.textTheme.headlineSmall,
                        ),
                        TextSpan(
                          text: '  ${taxLabel(p)}',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ],
                    ),
                  ),
                ),
                QuantityStepper(
                  value: _qty,
                  min: CartController.minQuantity,
                  max: CartController.maxQuantity,
                  enabled: !cart.isMutating,
                  onChanged: (v) => setState(() => _qty = v),
                ),
              ],
            ),
            if (cart.error != null) ...[
              const SizedBox(height: 12),
              Semantics(
                liveRegion: true,
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    describeApiError(cart.error!),
                    style: TextStyle(color: theme.colorScheme.onErrorContainer),
                  ),
                ),
              ),
            ],
            if (_selected.notSellableMessage != null) ...[
              const SizedBox(height: 12),
              Text(
                _selected.notSellableMessage!,
                key: const Key('variation-not-sellable'),
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: cart.isMutating || !_selected.isPosSellable
                  ? null
                  : _add,
              icon: cart.isMutating
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_shopping_cart),
              label: const Text('Add to cart'),
            ),
          ],
        ),
      ),
    );
  }
}

class _VariationTile extends StatelessWidget {
  const _VariationTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });
  final ProductItem item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final title =
        (item.variationName == null || item.variationName!.trim().isEmpty)
        ? 'Default'
        : item.variationName!;
    final details = [
      if (item.unitType != null && item.unitType!.trim().isNotEmpty)
        item.unitType!,
      if (item.currentStock != null)
        (item.currentStock! <= 0
            ? 'Out of stock'
            : 'Stock: ${formatQty(item.currentStock)}'),
    ].join(' · ');
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      button: true,
      label:
          '$title, price ${formatMoney(item.pricing.sellPrice)}${details.isEmpty ? '' : ', $details'}',
      child: ListTile(
        minTileHeight: 56,
        selected: selected,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Colors.transparent,
          ),
        ),
        leading: Icon(
          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        ),
        title: Text(title),
        subtitle: details.isEmpty ? null : Text(details),
        trailing: Text(
          formatMoney(item.pricing.sellPrice),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        onTap: onTap,
      ),
    );
  }
}
