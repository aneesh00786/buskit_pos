import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../cart/models/cart_sale.dart';
import '../../checkout/models/payment.dart';
import '../models/partial_refund.dart';
import '../state/sales_history_controller.dart';

/// Phase 17.8 partial refunds: item/quantity selection, the server-computed
/// preview + confirmation, the result, the per-sale refund history and the
/// partial/full badge. Every amount shown comes from the server — the POS
/// never calculates a refund total itself.

String _methodLabel(String wire) => TenderMethod.fromWire(wire)?.label ?? wire;

String _itemName(Map<int, String> names, CartLine line) =>
    names[line.productVariationId] ?? 'Item ${line.productVariationId}';

class RefundStatusBadge extends StatelessWidget {
  const RefundStatusBadge({super.key, required this.status});
  final SaleRefundStatus status;

  @override
  Widget build(BuildContext context) {
    final label = status.label;
    if (label == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    final full = status == SaleRefundStatus.full;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: (full ? scheme.error : scheme.tertiary).withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: full ? scheme.error : scheme.tertiary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// What the selection dialog hands back: the request and the server's
/// preview of it.
class PartialRefundRequest {
  const PartialRefundRequest({
    required this.lines,
    required this.preview,
    this.refundMethod,
    this.reason,
  });
  final List<RefundRequestLine> lines;
  final RefundPreview preview;
  final String? refundMethod;
  final String? reason;
}

/// Item + quantity selection. "Review refund" asks the server for the
/// preview and closes with it; a preview failure stays in the dialog.
Future<PartialRefundRequest?> showRefundItemsDialog(
  BuildContext context, {
  required CompletedSale sale,
  required Map<int, String> names,
  required SalesHistoryController controller,
}) {
  return showDialog<PartialRefundRequest>(
    context: context,
    builder: (_) => ChangeNotifierProvider<SalesHistoryController>.value(
      value: controller,
      child: _RefundItemsDialog(sale: sale, names: names),
    ),
  );
}

class _RefundItemsDialog extends StatefulWidget {
  const _RefundItemsDialog({required this.sale, required this.names});
  final CompletedSale sale;
  final Map<int, String> names;

  @override
  State<_RefundItemsDialog> createState() => _RefundItemsDialogState();
}

class _RefundItemsDialogState extends State<_RefundItemsDialog> {
  final Map<int, int> _qty = {};
  final Map<int, int> _damaged = {};
  final _reason = TextEditingController();
  late final List<String> _methods;
  String? _method;

  @override
  void initState() {
    super.initState();
    // D3: only the methods the sale was actually paid with.
    _methods = widget.sale.payments.map((p) => p.method).toSet().toList();
    _method = _methods.isNotEmpty ? _methods.first : null;
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  List<RefundRequestLine> get _lines => [
    for (final line in widget.sale.items)
      if ((_qty[line.id] ?? 0) > 0)
        RefundRequestLine(
          saleItemId: line.id,
          quantity: _qty[line.id]!,
          damagedQuantity: _damaged[line.id] ?? 0,
        ),
  ];

  void _setQty(int itemId, int value, int max) {
    final q = value.clamp(0, max);
    setState(() {
      _qty[itemId] = q;
      if ((_damaged[itemId] ?? 0) > q) _damaged[itemId] = q;
    });
    context.read<SalesHistoryController>().clearPreviewError();
  }

  void _selectAllRemaining() {
    setState(() {
      for (final line in widget.sale.items) {
        _qty[line.id] = widget.sale.refundableQuantity(line);
      }
    });
    context.read<SalesHistoryController>().clearPreviewError();
  }

  Future<void> _review() async {
    final h = context.read<SalesHistoryController>();
    final lines = _lines;
    if (lines.isEmpty) return;
    final reason = _reason.text.trim().isEmpty ? null : _reason.text.trim();
    final preview = await h.previewRefund(widget.sale.id, lines, refundMethod: _method);
    if (!mounted || preview == null) return;
    Navigator.of(context).pop(
      PartialRefundRequest(lines: lines, preview: preview, refundMethod: _method, reason: reason),
    );
  }

  @override
  Widget build(BuildContext context) {
    final h = context.watch<SalesHistoryController>();
    final theme = Theme.of(context);
    final refundable = widget.sale.items.where((l) => widget.sale.refundableQuantity(l) > 0).toList();
    final hasSelection = _lines.isNotEmpty;

    return AlertDialog(
      title: const Text('Refund items'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: refundable.isEmpty ? null : _selectAllRemaining,
                child: const Text('Select all remaining'),
              ),
            ),
            for (final line in refundable)
              _LineSelector(
                key: ValueKey('refund-line-${line.id}'),
                itemId: line.id,
                name: _itemName(widget.names, line),
                sold: line.quantity,
                refunded: widget.sale.refundedQuantity(line),
                refundable: widget.sale.refundableQuantity(line),
                quantity: _qty[line.id] ?? 0,
                damaged: _damaged[line.id] ?? 0,
                onQuantity: (v) => _setQty(line.id, v, widget.sale.refundableQuantity(line)),
                onDamaged: (v) {
                  setState(() => _damaged[line.id] = v.clamp(0, _qty[line.id] ?? 0));
                  h.clearPreviewError();
                },
              ),
            if (_methods.length > 1) ...[
              const SizedBox(height: PosTokens.s12),
              Text('Refund to', style: theme.textTheme.titleSmall),
              const SizedBox(height: PosTokens.s4),
              SegmentedButton<String>(
                segments: [
                  for (final m in _methods) ButtonSegment(value: m, label: Text(_methodLabel(m))),
                ],
                selected: {?_method},
                onSelectionChanged: (s) {
                  setState(() => _method = s.first);
                  h.clearPreviewError();
                },
              ),
              Text(
                'Any amount above what this method can take goes back to the sale\'s other payment methods.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: PosTokens.s12),
            TextField(
              key: const Key('refund-reason'),
              controller: _reason,
              maxLength: 255,
              decoration: const InputDecoration(labelText: 'Reason (optional)'),
            ),
            if (h.previewError != null)
              Padding(
                padding: const EdgeInsets.only(top: PosTokens.s8),
                child: Text(
                  describeApiError(h.previewError!),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          onPressed: hasSelection && !h.isPreviewing ? _review : null,
          child: Text(h.isPreviewing ? 'Calculating…' : 'Review refund'),
        ),
      ],
    );
  }
}

class _LineSelector extends StatelessWidget {
  const _LineSelector({
    super.key,
    required this.itemId,
    required this.name,
    required this.sold,
    required this.refunded,
    required this.refundable,
    required this.quantity,
    required this.damaged,
    required this.onQuantity,
    required this.onDamaged,
  });

  final int itemId;
  final String name;
  final int sold;
  final int refunded;
  final int refundable;
  final int quantity;
  final int damaged;
  final ValueChanged<int> onQuantity;
  final ValueChanged<int> onDamaged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: PosTokens.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, maxLines: 2, overflow: TextOverflow.ellipsis),
                    Text(
                      'Sold $sold · ${refunded > 0 ? 'refunded $refunded · ' : ''}refundable $refundable',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              _Stepper(
                keyPrefix: 'refund-qty',
                itemId: itemId,
                value: quantity,
                max: refundable,
                onChanged: onQuantity,
                label: 'Refund quantity for $name',
              ),
            ],
          ),
          if (quantity > 0)
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Damaged (not restocked)',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                _Stepper(
                  keyPrefix: 'refund-damaged',
                  itemId: itemId,
                  value: damaged,
                  max: quantity,
                  onChanged: onDamaged,
                  label: 'Damaged quantity for $name',
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.keyPrefix,
    required this.itemId,
    required this.value,
    required this.max,
    required this.onChanged,
    required this.label,
  });

  final String keyPrefix;
  final int itemId;
  final int value;
  final int max;
  final ValueChanged<int> onChanged;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      value: '$value',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            key: Key('$keyPrefix-dec-$itemId'),
            tooltip: 'Decrease',
            onPressed: value > 0 ? () => onChanged(value - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          SizedBox(
            width: 28,
            child: Text('$value', key: Key('$keyPrefix-value-$itemId'), textAlign: TextAlign.center),
          ),
          IconButton(
            key: Key('$keyPrefix-inc-$itemId'),
            tooltip: 'Increase',
            onPressed: value < max ? () => onChanged(value + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
    );
  }
}

/// The server's preview, shown for confirmation before anything is written.
Future<bool?> confirmPartialRefund(
  BuildContext context, {
  required CompletedSale sale,
  required Map<int, String> names,
  required PartialRefundRequest request,
}) {
  final preview = request.preview;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm refund'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(sale.displayNumber, style: Theme.of(ctx).textTheme.titleSmall),
            const SizedBox(height: PosTokens.s8),
            _AmountsBreakdown(sale: sale, names: names, amounts: preview),
            if (request.reason != null) _KV('Reason', request.reason!),
            const SizedBox(height: PosTokens.s12),
            Text(
              preview.fullyRefundedAfter
                  ? 'This refunds everything left on the sale. This cannot be undone.'
                  : 'This cannot be undone.',
              style: Theme.of(ctx).textTheme.bodySmall?.copyWith(color: Theme.of(ctx).colorScheme.error),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: const Text('Confirm refund'),
        ),
      ],
    ),
  );
}

/// Shown once, right after a successful partial refund (server figures).
Future<void> showPartialRefundResult(
  BuildContext context, {
  required CompletedSale sale,
  required Map<int, String> names,
  required PartialRefund refund,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.check_circle_outline, color: Theme.of(ctx).colorScheme.primary, size: 32),
      title: const Text('Refund successful'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _KV('Transaction', sale.displayNumber),
            _KV('Reference', 'Refund #${refund.id}'),
            if (refund.refundedAt != null) _KV('Date/time', formatTimestamp(refund.refundedAt!)),
            const Divider(),
            _AmountsBreakdown(sale: sale, names: names, amounts: refund),
          ],
        ),
      ),
      actions: [
        FilledButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Done')),
      ],
    ),
  );
}

class _AmountsBreakdown extends StatelessWidget {
  const _AmountsBreakdown({required this.sale, required this.names, required this.amounts});
  final CompletedSale sale;
  final Map<int, String> names;
  final RefundAmounts amounts;

  @override
  Widget build(BuildContext context) {
    final byId = {for (final l in sale.items) l.id: l};
    final loyalty = amounts.loyalty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final l in amounts.items)
          _KV(
            '${byId[l.saleItemId] != null ? _itemName(names, byId[l.saleItemId]!) : 'Item ${l.saleItemId}'} × ${l.quantity}'
            '${l.damagedQuantity > 0 ? ' (${l.damagedQuantity} damaged)' : ''}',
            formatMoney(l.refundAmount),
          ),
        const Divider(),
        if (amounts.subtotalAmount != null) _KV('Subtotal', formatMoney(amounts.subtotalAmount)),
        if ((amounts.discountAmount ?? 0) != 0) _KV('Discount', '-${formatMoney(amounts.discountAmount)}'),
        if (amounts.taxAmount != null) _KV('Tax', formatMoney(amounts.taxAmount)),
        _KV('Refund total', formatMoney(amounts.refundAmount), bold: true),
        for (final p in amounts.payouts) _KV('Refund to ${_methodLabel(p.method)}', formatMoney(p.amount)),
        if (amounts.walletAmount > 0) _KV('Back to wallet', formatMoney(amounts.walletAmount)),
        if (!loyalty.isEmpty) ...[
          if (loyalty.pointsEarnedReversed != 0) _KV('Points earned reversed', '${loyalty.pointsEarnedReversed}'),
          if (loyalty.pointsRedeemedReturned != 0) _KV('Points returned', '${loyalty.pointsRedeemedReturned}'),
          if (loyalty.cashbackReversed != 0) _KV('Cashback reversed', formatMoney(loyalty.cashbackReversed)),
        ],
      ],
    );
  }
}

/// Previous partial refunds for a sale, oldest first.
class PartialRefundHistory extends StatelessWidget {
  const PartialRefundHistory({super.key, required this.sale, required this.names});
  final CompletedSale sale;
  final Map<int, String> names;

  @override
  Widget build(BuildContext context) {
    if (sale.refunds.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Refund history', style: theme.textTheme.titleSmall),
        for (final r in sale.refunds)
          ExpansionTile(
            key: ValueKey('refund-history-${r.id}'),
            tilePadding: EdgeInsets.zero,
            title: Text('Refund #${r.id} · ${formatMoney(r.refundAmount)}'),
            subtitle: Text(
              [
                '${r.unitCount} item${r.unitCount == 1 ? '' : 's'}',
                if (r.refundedBy != null) 'by ${r.refundedBy}',
                if (r.refundedAt != null) formatTimestamp(r.refundedAt!),
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
            childrenPadding: const EdgeInsets.only(bottom: PosTokens.s8),
            children: [
              _AmountsBreakdown(sale: sale, names: names, amounts: r),
              if (r.reason != null) _KV('Reason', r.reason!),
            ],
          ),
        if (sale.refundedTotal != null) _KV('Refunded so far', formatMoney(sale.refundedTotal), bold: true),
        if (sale.refundableTotal != null && sale.refundStatus != SaleRefundStatus.full)
          _KV('Still refundable', formatMoney(sale.refundableTotal)),
      ],
    );
  }
}

class _KV extends StatelessWidget {
  const _KV(this.label, this.value, {this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: PosTokens.s8),
          Text(value, style: style),
        ],
      ),
    );
  }
}
