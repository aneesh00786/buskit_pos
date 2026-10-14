import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../data/line_pricing_service.dart';
import '../models/cart_sale.dart';
import '../models/line_pricing.dart';
import '../state/cart_controller.dart';

/// Line discount and per-sale price override for one draft line (backend
/// migration 055). What is offered comes from the server's discount policy
/// for the signed-in staff member; the server still checks every request
/// (permission, limit, line cap) and computes every amount — the cart is
/// always shown as the server returned it. Online only.
Future<void> showLinePricingDialog(
  BuildContext context, {
  required CartController cart,
  required LinePricingService service,
  required int lineId,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        LinePricingDialog(cart: cart, service: service, lineId: lineId),
  );
}

// Exact text checks (no floating point): what the server accepts.
final _percentText = RegExp(r'^\d{1,3}(\.\d{1,2})?$');
final _moneyText = RegExp(r'^\d{1,7}(\.\d{1,3})?$');

/// Null when [text] is a percentage the server can accept, else why not.
String? percentProblem(String text) {
  final t = text.trim();
  if (!_percentText.hasMatch(t)) {
    return 'Enter a percentage with at most 2 decimals.';
  }
  final v = double.parse(t);
  if (v <= 0 || v > 100) return 'Enter a percentage above 0 and at most 100.';
  return null;
}

/// Null when [text] is an amount the server can accept, else why not.
String? amountProblem(String text) {
  final t = text.trim();
  if (!_moneyText.hasMatch(t)) {
    return 'Enter an amount with at most 3 decimals.';
  }
  if (double.parse(t) <= 0) return 'Enter an amount above 0.';
  return null;
}

/// Exact thousandths of a validated amount / percentage text.
int _milli(String text) {
  final parts = text.trim().split('.');
  return int.parse(parts[0]) * 1000 +
      int.parse((parts.length > 1 ? parts[1] : '').padRight(3, '0'));
}

class LinePricingDialog extends StatefulWidget {
  const LinePricingDialog({
    super.key,
    required this.cart,
    required this.service,
    required this.lineId,
  });
  final CartController cart;
  final LinePricingService service;
  final int lineId;

  @override
  State<LinePricingDialog> createState() => _LinePricingDialogState();
}

class _LinePricingDialogState extends State<LinePricingDialog> {
  late Future<DiscountPolicy> _policy = widget.service.loadPolicy();
  String _type = 'percentage';
  final _value = TextEditingController();
  final _reason = TextEditingController();
  final _price = TextEditingController();
  final _priceReason = TextEditingController();
  String? _discountError;
  String? _priceError;
  String? _serverError;

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    _price.dispose();
    _priceReason.dispose();
    super.dispose();
  }

  CartController get cart => widget.cart;

  CartLine? get _line {
    final sale = cart.sale;
    if (sale == null) return null;
    for (final l in sale.items) {
      if (l.id == widget.lineId) return l;
    }
    return null;
  }

  Future<void> _send(
    Future<CartSale> Function(CartSale sale) request,
    String done,
  ) async {
    setState(() => _serverError = null);
    final ok = await cart.changeLinePricing(widget.lineId, request);
    if (!mounted) return;
    if (ok) {
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).pop();
      messenger?.showSnackBar(SnackBar(content: Text(done)));
      return;
    }
    final e = cart.error;
    setState(() {
      _serverError = e?.message ?? 'Nothing was changed.';
      // Not allowed (any more): ask the server again what this staff member may do.
      if (e?.kind == ApiErrorKind.forbidden) {
        _policy = widget.service.loadPolicy();
      }
    });
  }

  Future<bool> _confirm(String title, String message) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('line-pricing-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  void _applyDiscount(CartLine line) {
    final v = _value.text.trim();
    final problem = _type == 'percentage'
        ? percentProblem(v)
        : amountProblem(v);
    final reason = _reason.text.trim();
    setState(
      () => _discountError =
          problem ?? (reason.isEmpty ? 'A reason is required.' : null),
    );
    if (_discountError != null) return;
    _send(
      (sale) => widget.service.setDiscount(
        saleId: sale.id,
        itemId: line.id,
        type: _type,
        value: v,
        reason: reason,
        expectedVersion: sale.version,
      ),
      'Line discount applied.',
    );
  }

  Future<void> _removeDiscount(CartLine line) async {
    if (!await _confirm(
      'Remove line discount?',
      'The line goes back to its price without this discount.',
    )) {
      return;
    }
    await _send(
      (sale) => widget.service.removeDiscount(
        saleId: sale.id,
        itemId: line.id,
        expectedVersion: sale.version,
      ),
      'Line discount removed.',
    );
  }

  void _applyPrice(CartLine line) {
    final v = _price.text.trim();
    final reason = _priceReason.text.trim();
    setState(
      () => _priceError =
          amountProblem(v) ?? (reason.isEmpty ? 'A reason is required.' : null),
    );
    if (_priceError != null) return;
    _send(
      (sale) => widget.service.setPrice(
        saleId: sale.id,
        itemId: line.id,
        unitPrice: v,
        reason: reason,
        expectedVersion: sale.version,
      ),
      'Price changed for this sale.',
    );
  }

  Future<void> _removePrice(CartLine line) async {
    if (!await _confirm(
      'Remove price change?',
      'The line goes back to its normal price.',
    )) {
      return;
    }
    await _send(
      (sale) => widget.service.removePrice(
        saleId: sale.id,
        itemId: line.id,
        expectedVersion: sale.version,
      ),
      'Normal price restored.',
    );
  }

  /// Indicative only — the server sets the real amount (and caps it at the line).
  String? _estimate(CartLine line) {
    final v = _value.text.trim();
    final unit = line.unitPrice;
    if (unit == null ||
        (_type == 'percentage' ? percentProblem(v) : amountProblem(v)) != null) {
      return null;
    }
    final grossMilli =
        ((unit * 1000).round() * line.quantityMilli + 500) ~/ 1000;
    final d = _type == 'percentage'
        ? (grossMilli * (_milli(v) ~/ 10) + 5000) ~/ 10000
        : _milli(v);
    final capped = d > grossMilli ? grossMilli : d;
    return 'About ${formatMoney(capped / 1000)} off ${formatMoney(grossMilli / 1000)} before tax — the server calculates the final amount.';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: cart,
      builder: (context, _) {
        final line = _line;
        final busy = cart.isMutating;
        return AlertDialog(
          key: const Key('line-pricing-dialog'),
          title: Text(line?.productName ?? 'Line'),
          content: SizedBox(
            width: 460,
            child: SingleChildScrollView(
              child: line == null
                  ? const Text(
                      'This line is no longer in the cart.',
                      key: Key('line-pricing-gone'),
                    )
                  : _body(context, theme, line, busy),
            ),
          ),
          actions: [
            TextButton(
              key: const Key('line-pricing-close'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    ThemeData theme,
    CartLine line,
    bool busy,
  ) {
    final over = line.priceOverride;
    final disc = line.lineDiscount;
    final header = <Widget>[
      Text(
        '${line.quantityText} × ${formatMoney(line.unitPrice)}  =  ${formatMoney(line.lineTotal)}',
        style: theme.textTheme.bodyMedium,
      ),
      if (over != null)
        Text(
          'Price changed for this sale: ${formatMoney(over.originalUnitPrice)} → ${formatMoney(over.unitPrice)}${over.reason == null ? '' : ' (${over.reason})'}',
          key: const Key('line-pricing-current-override'),
        ),
      if (disc != null)
        Text(
          'Line discount: ${disc.isPercentage ? '${formatQty(disc.value)}%' : formatMoney(disc.value)}'
          '${disc.amount == null ? '' : ' (−${formatMoney(disc.amount)})'}${disc.reason == null ? '' : ' — ${disc.reason}'}',
          key: const Key('line-pricing-current-discount'),
        ),
      if (_serverError != null)
        Padding(
          padding: const EdgeInsets.only(top: PosTokens.s8),
          child: Text(
            _serverError!,
            key: const Key('line-pricing-server-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
        ),
    ];
    if (cart.offline?.isOffline() == true || cart.isLocalSale) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...header,
          const SizedBox(height: PosTokens.s12),
          const Text(
            CartController.linePricingOfflineMessage,
            key: Key('line-pricing-offline'),
          ),
        ],
      );
    }
    if (cart.linePricingOutcomeUnknown) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ...header,
          const SizedBox(height: PosTokens.s12),
          const Text(
            CartController.linePricingUnknownMessage,
            key: Key('line-pricing-unknown'),
          ),
          const SizedBox(height: PosTokens.s8),
          OutlinedButton.icon(
            key: const Key('line-pricing-reload'),
            onPressed: busy || cart.isRefreshing ? null : () => cart.refresh(),
            icon: const Icon(Icons.refresh),
            label: const Text('Reload cart'),
          ),
        ],
      );
    }
    return FutureBuilder<DiscountPolicy>(
      future: _policy,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ...header,
              const Padding(
                padding: EdgeInsets.all(PosTokens.s16),
                child: CircularProgressIndicator(
                  key: Key('line-pricing-loading'),
                ),
              ),
            ],
          );
        }
        if (snap.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              ...header,
              const SizedBox(height: PosTokens.s12),
              const Text(
                'Your discount permissions could not be loaded, so discounts and price changes are unavailable.',
                key: Key('line-pricing-policy-error'),
              ),
              TextButton(
                key: const Key('line-pricing-policy-retry'),
                onPressed: () => setState(() {
                  _policy = widget.service.loadPolicy();
                }),
                child: const Text('Try again'),
              ),
            ],
          );
        }
        final policy = snap.data!;
        final canDiscount = policy.canDiscount;
        final canPrice = policy.canOverridePrice;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            ...header,
            if (!canDiscount && !canPrice)
              const Padding(
                padding: EdgeInsets.only(top: PosTokens.s12),
                child: Text(
                  'You are not allowed to discount this line or change its price.',
                  key: Key('line-pricing-none'),
                ),
              ),
            if (canDiscount) ...[
              const Divider(height: PosTokens.s24),
              Text('Line discount', style: theme.textTheme.titleSmall),
              Text(
                policy.lineDiscountAuthority == 'discounts.override'
                    ? 'Up to 100% of the line.'
                    : 'Your limit: ${formatQty(policy.lineDiscountMaxPercent)}% of the line (a fixed amount counts as its share of the line).',
                key: const Key('line-discount-limit'),
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: PosTokens.s8),
              SegmentedButton<String>(
                key: const Key('line-discount-type'),
                segments: const [
                  ButtonSegment(value: 'percentage', label: Text('%')),
                  ButtonSegment(value: 'flat', label: Text('Fixed amount')),
                ],
                selected: {_type},
                onSelectionChanged: busy
                    ? null
                    : (s) => setState(() => _type = s.first),
              ),
              TextField(
                key: const Key('line-discount-value'),
                controller: _value,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _type == 'percentage'
                      ? 'Percent'
                      : 'Amount for the whole line',
                ),
                onChanged: (_) => setState(() {}),
              ),
              TextField(
                key: const Key('line-discount-reason'),
                controller: _reason,
                enabled: !busy,
                maxLength: 255,
                decoration: const InputDecoration(
                  labelText: 'Reason (required)',
                ),
              ),
              if (_estimate(line) != null)
                Text(
                  _estimate(line)!,
                  key: const Key('line-discount-estimate'),
                  style: theme.textTheme.bodySmall,
                ),
              if (_discountError != null)
                Text(
                  _discountError!,
                  key: const Key('line-discount-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const SizedBox(height: PosTokens.s8),
              Wrap(
                spacing: PosTokens.s8,
                children: [
                  FilledButton(
                    key: const Key('line-discount-apply'),
                    onPressed: busy ? null : () => _applyDiscount(line),
                    child: Text(
                      line.lineDiscount == null
                          ? 'Apply discount'
                          : 'Replace discount',
                    ),
                  ),
                  if (line.lineDiscount != null)
                    OutlinedButton(
                      key: const Key('line-discount-remove'),
                      onPressed: busy ? null : () => _removeDiscount(line),
                      child: const Text('Remove discount'),
                    ),
                ],
              ),
            ],
            if (canPrice) ...[
              const Divider(height: PosTokens.s24),
              Text('Price for this sale', style: theme.textTheme.titleSmall),
              Text(
                'Current unit price ${formatMoney(line.unitPrice)}. Applies to this sale only — the catalogue price is not changed.',
                key: const Key('line-price-note'),
                style: theme.textTheme.bodySmall,
              ),
              TextField(
                key: const Key('line-price-value'),
                controller: _price,
                enabled: !busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(labelText: 'New unit price'),
              ),
              TextField(
                key: const Key('line-price-reason'),
                controller: _priceReason,
                enabled: !busy,
                maxLength: 255,
                decoration: const InputDecoration(
                  labelText: 'Reason (required)',
                ),
              ),
              if (_priceError != null)
                Text(
                  _priceError!,
                  key: const Key('line-price-error'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const SizedBox(height: PosTokens.s8),
              Wrap(
                spacing: PosTokens.s8,
                children: [
                  FilledButton(
                    key: const Key('line-price-apply'),
                    onPressed: busy ? null : () => _applyPrice(line),
                    child: const Text('Change price'),
                  ),
                  if (line.priceOverride != null)
                    OutlinedButton(
                      key: const Key('line-price-remove'),
                      onPressed: busy ? null : () => _removePrice(line),
                      child: const Text('Restore normal price'),
                    ),
                ],
              ),
            ],
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: PosTokens.s8),
                child: LinearProgressIndicator(key: Key('line-pricing-busy')),
              ),
          ],
        );
      },
    );
  }
}

/// Short descriptions of a line's discount / price change, for the cart tile.
List<String> linePricingLabels(CartLine line) => [
  if (line.priceOverride != null)
    'Price for this sale ${formatMoney(line.priceOverride!.unitPrice)} (was ${formatMoney(line.priceOverride!.originalUnitPrice)})',
  if (line.lineDiscount != null)
    'Line discount ${line.lineDiscount!.isPercentage ? '${formatQty(line.lineDiscount!.value)}%' : formatMoney(line.lineDiscount!.value)}'
        '${line.lineDiscount!.amount == null ? '' : ' −${formatMoney(line.lineDiscount!.amount)}'}',
];
