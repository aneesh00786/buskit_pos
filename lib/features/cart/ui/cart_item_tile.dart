import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/product_image.dart';
import '../../../core/ui/quantity_stepper.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/quantity.dart';
import '../models/cart_sale.dart';
import '../state/cart_controller.dart';
import 'quantity_dialog.dart';

/// One line of the current sale: thumbnail, name, variation, quantity stepper,
/// unit price, tax and the line total. Every figure is what the server
/// returned; nothing is calculated here.
class CartItemTile extends StatelessWidget {
  const CartItemTile({
    super.key,
    required this.line,
    required this.label,
    required this.imageUrl,
    required this.enabled,
    required this.inFlight,
  });

  final CartLine line;
  final String? label;
  final String? imageUrl;
  final bool enabled;
  final bool inFlight;

  String get _name => line.productName ?? 'Item ${line.productVariationId}';

  String? get _taxText {
    if (line.isUnavailable || line.taxAmount == null) return null;
    final pct = (line.taxPercent == null || line.taxPercent == 0)
        ? ''
        : ' (${formatQty(line.taxPercent)}%)';
    if (line.taxIncluded == true) {
      return 'incl. tax ${formatMoney(line.taxAmount)}$pct';
    }
    return (line.taxAmount ?? 0) > 0
        ? '+ tax ${formatMoney(line.taxAmount)}$pct'
        : 'no tax';
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final cart = context.read<CartController>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove item?'),
        content: Text('Remove $_name from the cart?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok == true) await cart.removeItem(line.id);
  }

  Future<void> _editQuantity(BuildContext context) async {
    final cart = context.read<CartController>();
    final q = await showQuantityDialog(
      context,
      initial: line.quantity,
      itemName: _name,
      weight: line.isWeight,
    );
    if (q != null) await cart.updateQuantity(line.id, q);
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.read<CartController>();
    final theme = Theme.of(context);
    final tax = _taxText;
    final discount = line.discountAmount;
    final details = <String>[
      if (label != null && label!.isNotEmpty) label!,
      if (line.isUnavailable)
        'No longer available'
      else
        '${line.quantityText} × ${formatMoney(line.unitPrice)}',
      ?tax,
      if (discount != null && discount != 0)
        'Discount ${formatMoney(discount)}',
    ];

    return Semantics(
      container: true,
      label:
          '$_name, ${line.isWeight ? 'weight' : 'quantity'} ${line.quantityText}, line total ${formatMoney(line.lineTotal)}',
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: PosTokens.s8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 52,
                  height: 52,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(PosTokens.rSmall),
                    child: ProductImage(url: imageUrl),
                  ),
                ),
                const SizedBox(width: PosTokens.s12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                      for (final d in details)
                        Text(
                          d,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: PosTokens.s8),
                inFlight
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        formatMoney(line.lineTotal),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
              ],
            ),
            const SizedBox(height: PosTokens.s4),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // Phase 12B: a weighed line is set by typing its weight
                // (the existing quantity dialog in weight mode); pieces keep
                // the +/- stepper exactly as before.
                if (line.isWeight)
                  OutlinedButton.icon(
                    key: Key('weight-${line.id}'),
                    onPressed: enabled && !line.isUnavailable
                        ? () => _editQuantity(context)
                        : null,
                    icon: const Icon(Icons.scale_outlined, size: 18),
                    label: Text(line.quantityText),
                  )
                else
                  QuantityStepper(
                    value: line.quantityMilli ~/ quantityUnit,
                    min: CartController.minQuantity,
                    max: CartController.maxQuantity,
                    enabled: enabled && !line.isUnavailable,
                    onChanged: (q) => cart.updateQuantity(line.id, q),
                    onTapValue: () => _editQuantity(context),
                  ),
                IconButton(
                  tooltip: 'Remove $_name',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: enabled ? () => _confirmRemove(context) : null,
                  icon: Icon(
                    Icons.delete_outline,
                    color: enabled ? theme.colorScheme.error : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
