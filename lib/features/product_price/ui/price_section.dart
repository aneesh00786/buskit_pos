import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../products/models/product_item.dart';
import '../state/product_price_controller.dart';

/// "Selling price (POS)" card for one product: the price POS charges, the
/// catalogue price when a POS-only override is active, the Change price /
/// Use catalogue price actions and the change history. Actions and history
/// are hidden only when the loaded permission context positively lacks
/// `products.price_change` (SessionController.isDenied) — a missing/failed
/// context leaves them visible and the backend decides.
class ProductPriceSection extends StatefulWidget {
  const ProductPriceSection({super.key, required this.product});
  final ProductItem product;

  @override
  State<ProductPriceSection> createState() => _ProductPriceSectionState();
}

class _ProductPriceSectionState extends State<ProductPriceSection> {
  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void didUpdateWidget(covariant ProductPriceSection old) {
    super.didUpdateWidget(old);
    if (old.product.id != widget.product.id) _loadHistory();
  }

  void _loadHistory() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.read<SessionController>().isDenied('products.price_change'))
        return;
      context.read<ProductPriceController>().loadHistory(widget.product.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    final c = context.watch<ProductPriceController>();
    final canChange = !session.isDenied('products.price_change');
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final p = widget.product.pricing;

    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: t.card(outlined: false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Selling price (POS)', style: theme.textTheme.bodySmall),
          Row(
            children: [
              Text(
                formatMoney(p.sellPrice),
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (p.hasPosOverride) ...[
                const SizedBox(width: PosTokens.s8),
                Chip(
                  label: const Text('POS price'),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
          if (p.hasPosOverride)
            Text(
              'Catalogue price ${formatMoney(p.cataloguePrice)} (unchanged for web store and other channels)',
              style: theme.textTheme.bodySmall,
            ),
          if (canChange) ...[
            const SizedBox(height: PosTokens.s12),
            Wrap(
              spacing: PosTokens.s12,
              runSpacing: PosTokens.s8,
              children: [
                FilledButton.icon(
                  onPressed: c.isBusy ? null : () => _change(context),
                  icon: c.isBusy
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sell_outlined),
                  label: Text(c.isBusy ? 'Saving…' : 'Change price'),
                ),
                if (p.hasPosOverride)
                  OutlinedButton(
                    onPressed: c.isBusy ? null : () => _reset(context),
                    child: const Text('Use catalogue price'),
                  ),
              ],
            ),
            const SizedBox(height: PosTokens.s12),
            Text('Price history', style: theme.textTheme.titleSmall),
            _History(controller: c),
          ],
        ],
      ),
    );
  }

  Future<void> _change(BuildContext context) async {
    final c = context.read<ProductPriceController>();
    final product = widget.product;
    final current = product.pricing.sellPrice ?? 0;
    final request = await showDialog<_PriceRequest>(
      context: context,
      builder: (_) => _PriceForm(currentPrice: current),
    );
    if (request == null || !context.mounted) return;

    final confirmed = await _confirm(
      context,
      title: 'Confirm price change',
      productName: _label(product),
      oldPrice: current,
      newPrice: double.parse(request.price),
      reason: request.reason,
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await c.changePrice(
      productId: product.id,
      expectedVersion: product.pricing.priceVersion,
      price: request.price,
      reason: request.reason,
    );
    if (!context.mounted) return;
    _feedback(
      context,
      c,
      ok,
      success: 'Price updated to ${formatMoney(c.lastResult?.sellPrice)}',
    );
  }

  Future<void> _reset(BuildContext context) async {
    final c = context.read<ProductPriceController>();
    final product = widget.product;
    final confirmed = await _confirm(
      context,
      title: 'Use catalogue price?',
      productName: _label(product),
      oldPrice: product.pricing.sellPrice ?? 0,
      newPrice: product.pricing.cataloguePrice ?? 0,
    );
    if (confirmed != true || !context.mounted) return;
    final ok = await c.resetPrice(
      productId: product.id,
      expectedVersion: product.pricing.priceVersion,
    );
    if (!context.mounted) return;
    _feedback(
      context,
      c,
      ok,
      success:
          'POS now uses the catalogue price ${formatMoney(c.lastResult?.sellPrice)}',
    );
  }

  void _feedback(
    BuildContext context,
    ProductPriceController c,
    bool ok, {
    required String success,
  }) {
    final err = c.error;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            ok
                ? success
                : (err != null
                      ? describeApiError(err)
                      : 'The price could not be changed.'),
          ),
        ),
      );
    if (!ok) c.clearError();
  }
}

String _label(ProductItem p) =>
    (p.variationName == null ||
        p.variationName!.isEmpty ||
        p.variationName == 'Default')
    ? p.productName
    : '${p.productName} · ${p.variationName}';

Future<bool?> _confirm(
  BuildContext context, {
  required String title,
  required String productName,
  required double oldPrice,
  required double newPrice,
  String? reason,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Product', productName),
          _KeyValue('Current price', formatMoney(oldPrice)),
          _KeyValue('New price', formatMoney(newPrice)),
          if (reason != null && reason.isNotEmpty) _KeyValue('Reason', reason),
          const SizedBox(height: PosTokens.s12),
          Text(
            'Applies to POS only, including open carts. Completed sales and the web store price are not changed.',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );
}

class _History extends StatelessWidget {
  const _History({required this.controller});
  final ProductPriceController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    switch (c.historyStatus) {
      case PriceHistoryStatus.idle:
      case PriceHistoryStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: PosTokens.s8),
          child: LinearProgressIndicator(),
        );
      case PriceHistoryStatus.error:
        return Text(describeApiError(c.historyError!));
      case PriceHistoryStatus.loaded:
        if (c.history.isEmpty) return const Text('No price changes yet.');
        return Column(
          children: [
            for (final h in c.history)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '${formatMoney(h.previousPrice)} → ${formatMoney(h.newPrice)}'
                  '${h.action == 'reset' ? ' (catalogue)' : ''}',
                ),
                subtitle: Text(
                  [
                    if (h.reason != null && h.reason!.isNotEmpty) h.reason!,
                    if (h.salesmanId != null) h.salesmanId!,
                    if (h.createdAt != null) formatTimestamp(h.createdAt!),
                  ].join(' · '),
                ),
              ),
          ],
        );
    }
  }
}

class _PriceRequest {
  const _PriceRequest(this.price, this.reason);
  final String price;
  final String? reason;
}

/// New price (> 0, at most 3 decimals, different from the current one) and
/// an optional reason. Client checks are for fast feedback only; the server
/// re-validates everything.
class _PriceForm extends StatefulWidget {
  const _PriceForm({required this.currentPrice});
  final double currentPrice;

  @override
  State<_PriceForm> createState() => _PriceFormState();
}

class _PriceFormState extends State<_PriceForm> {
  final _price = TextEditingController();
  final _reason = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _price.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _price.text.trim();
    final value = RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(raw)
        ? double.tryParse(raw)
        : null;
    String? error;
    if (value == null || value <= 0) {
      error = 'Enter a price greater than 0 (up to 3 decimals)';
    } else if (value > 9999999.999) {
      error = 'Price is too large';
    } else if ((value * 1000).round() == (widget.currentPrice * 1000).round()) {
      error = 'That is already the current price';
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    final reason = _reason.text.trim();
    Navigator.of(context)
        .pop(_PriceRequest(raw, reason.isEmpty ? null : reason));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change price'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _KeyValue('Current price', formatMoney(widget.currentPrice)),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _price,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'New price *',
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _reason,
              maxLength: 255,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: PosTokens.s8),
          Flexible(
            child: Text(value, style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}
