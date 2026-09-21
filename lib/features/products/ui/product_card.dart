import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/product_image.dart';
import '../../../core/utils/format.dart';
import '../models/product_group.dart';
import '../models/product_item.dart';

/// Server-supplied tax label. Purely a display of `pricing.tax_mode` /
/// `tax_percent`; the client does no tax arithmetic.
String taxLabel(ProductPricing p) {
  switch (p.taxMode) {
    case 'inclusive':
      return 'incl. tax';
    case 'exclusive':
      final pct = p.taxPercent;
      return (pct == null || pct == 0) ? 'no tax' : '+ ${formatQty(pct)}% tax';
    case 'none':
      return 'no tax';
    default:
      return '';
  }
}

String priceText(ProductGroup g) {
  final lo = g.minPrice;
  final hi = g.maxPrice;
  if (lo == null) return '—';
  if (hi == null || lo == hi) return formatMoney(lo);
  return 'from ${formatMoney(lo)}';
}

/// Variation / unit line under the product name.
String _subtitle(ProductGroup g) {
  if (g.hasMultipleVariations) return '${g.variations.length} variations';
  final first = g.first;
  return [
    first.variationName,
    first.unitType,
  ].where((s) => s != null && s.trim().isNotEmpty).join(' · ');
}

/// Server stock figure (informational; the server decides at completion).
class _StockLine extends StatelessWidget {
  const _StockLine({required this.stock});
  final double stock;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final out = stock <= 0;
    final color = out ? t.warning : t.success;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            out ? 'Out of stock' : 'Stock: ${formatQty(stock)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: out ? t.warning : null),
          ),
        ),
      ],
    );
  }
}

class _PriceText extends StatelessWidget {
  const _PriceText({required this.group});
  final ProductGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tax = group.hasMultipleVariations
        ? ''
        : taxLabel(group.first.pricing);
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: priceText(group),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          if (tax.isNotEmpty)
            TextSpan(text: '  $tax', style: theme.textTheme.bodySmall),
        ],
      ),
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    );
  }
}

class _AddButton extends StatelessWidget {
  const _AddButton({required this.multi, required this.onPressed});
  final bool multi;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: t.success,
        foregroundColor: t.onSuccess,
        minimumSize: const Size(72, 48),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(multi ? Icons.tune : Icons.add, size: 18),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              multi ? 'Select' : 'Add',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

String _semanticsLabel(ProductGroup g) {
  final tax = g.hasMultipleVariations ? '' : taxLabel(g.first.pricing);
  return '${g.name}, ${_subtitle(g)}, price ${priceText(g)} $tax'.trim();
}

/// Grid card: image, name, variation, price, availability and a green Add.
class ProductCard extends StatelessWidget {
  const ProductCard({
    super.key,
    required this.group,
    required this.onTap,
    this.busy = false,
  });

  final ProductGroup group;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    final multi = group.hasMultipleVariations;
    final subtitle = _subtitle(group);
    final stock = multi ? null : group.first.currentStock;

    return Semantics(
      button: true,
      label: _semanticsLabel(group),
      child: Container(
        decoration: t.card(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onTap,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: ProductImage(url: group.imageUrl)),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      group.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    if (subtitle.isNotEmpty)
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall,
                      ),
                    const SizedBox(height: 4),
                    _PriceText(group: group),
                    if (stock != null) _StockLine(stock: stock),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: _AddButton(multi: multi, onPressed: busy ? null : onTap),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// List-mode row for the same product.
class ProductListTile extends StatelessWidget {
  const ProductListTile({
    super.key,
    required this.group,
    required this.onTap,
    this.busy = false,
  });

  final ProductGroup group;
  final VoidCallback onTap;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    final multi = group.hasMultipleVariations;
    final subtitle = _subtitle(group);
    final stock = multi ? null : group.first.currentStock;

    return Semantics(
      button: true,
      label: _semanticsLabel(group),
      child: Container(
        decoration: t.card(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 88),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  SizedBox(
                    width: 68,
                    height: 68,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(PosTokens.rSmall),
                      child: ProductImage(url: group.imageUrl),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                        if (subtitle.isNotEmpty)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        _PriceText(group: group),
                        if (stock != null) _StockLine(stock: stock),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _AddButton(multi: multi, onPressed: busy ? null : onTap),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
