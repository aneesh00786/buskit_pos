import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../../cart/state/cart_controller.dart';
import '../../receipt/models/receipt_formatter.dart';
import '../../receipt/state/receipt_services.dart';
import '../../receipt/ui/receipt_actions.dart';
import '../models/payment.dart';
import '../state/payment_plan.dart';

/// Opens the payment screen for the open sale: a dialog on tablets, a tall
/// bottom sheet on phones. It cannot be dismissed by tapping outside (that
/// could hide a completed sale or an in-flight payment); use its buttons.
Future<void> showPay(BuildContext context) {
  final cart = context.read<CartController>();
  cart.acknowledgeCompletion(); // a fresh checkout never re-shows an old receipt
  cart.clearError();
  final size = MediaQuery.sizeOf(context);
  final session = context.read<SessionController>();
  final receipts = context.read<ReceiptServices>();
  Widget content() => MultiProvider(
    providers: [
      ChangeNotifierProvider<CartController>.value(value: cart),
      ChangeNotifierProvider<SessionController>.value(value: session),
      Provider<ReceiptServices>.value(value: receipts),
    ],
    child: const PayModal(),
  );

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: size.height * 0.92,
          ),
          child: content(),
        ),
      ),
    );
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    isDismissible: false,
    enableDrag: false,
    useSafeArea: true,
    builder: (_) => SizedBox(height: size.height * 0.95, child: content()),
  );
}

/// Wording for checkout failures, with product names where the server sent ids.
String describeCheckoutError(ApiException e, Map<int, String> names) {
  String nameOf(Object? id) => names[asInt(id)] ?? 'an item';
  switch (e.errorCode) {
    case PosErrorCodes.insufficientStock:
      final shortages = asList(e.dataMap?['shortages'])
          .map(asMap)
          .whereType<Map<String, dynamic>>();
      final parts = [
        for (final s in shortages)
          '${nameOf(s['item_id'])} (${formatQty(asDouble(s['requested']))} requested, ${formatQty(asDouble(s['available']))} available)',
      ];
      if (parts.isNotEmpty) {
        return 'Not enough stock: ${parts.join('; ')}. Adjust the cart and try again.';
      }
      return 'Not enough stock to complete this sale.';
    case PosErrorCodes.weightUnitNotSupported:
      final ids = asList(e.dataMap?['weight_unit_item_ids']);
      final list = ids.isEmpty ? '' : ' (${ids.map(nameOf).join(', ')})';
      return 'This sale has products sold by weight or volume$list, which cannot be sold at the POS yet. '
          'Remove them from the cart and try again.';
  }
  return describeApiError(e);
}

class PayModal extends StatefulWidget {
  const PayModal({super.key});

  @override
  State<PayModal> createState() => _PayModalState();
}

class _PayModalState extends State<PayModal> {
  PayMode _mode = PayMode.cash;
  TenderMethod _secondary = TenderMethod.card;
  final _tendered = TextEditingController();
  final _cashApplied = TextEditingController();
  final _cashReceived = TextEditingController();
  final _reference = TextEditingController();

  @override
  void dispose() {
    _tendered.dispose();
    _cashApplied.dispose();
    _cashReceived.dispose();
    _reference.dispose();
    super.dispose();
  }

  int _totalMilli(CartController cart) =>
      milliFromDouble(cart.sale?.totals.grandTotal ?? 0);

  PaymentPlan _plan(CartController cart) {
    final total = _totalMilli(cart);
    switch (_mode) {
      case PayMode.cash:
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          cashReceivedMilli: parseMilli(_tendered.text),
        );
      case PayMode.card:
      case PayMode.other:
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          reference: _reference.text,
        );
      case PayMode.split:
        final applied = parseMilli(_cashApplied.text);
        final receivedText = _cashReceived.text.trim();
        return PaymentPlan(
          totalMilli: total,
          mode: _mode,
          cashAppliedMilli: applied,
          cashReceivedMilli: receivedText.isEmpty
              ? applied
              : parseMilli(receivedText),
          secondary: _secondary,
          reference: _reference.text,
        );
    }
  }

  Future<void> _complete(CartController cart) async {
    final plan = _plan(cart);
    if (!plan.isValid) return;
    await cart.completeSale(plan.payments);
  }

  @override
  Widget build(BuildContext context) {
    final cart = context.watch<CartController>();
    final done = cart.completedSale;
    if (done != null) {
      return _SuccessView(
        sale: done,
        names: cart.completedNames,
        variants: cart.completedVariants,
      );
    }

    final sale = cart.sale;
    if (sale == null) {
      // The sale disappeared (voided elsewhere, session reset): nothing to pay.
      return _Shell(
        title: 'Take payment',
        onClose: () => Navigator.of(context).pop(),
        child: const Center(child: Text('There is no open sale.')),
      );
    }

    final plan = _plan(cart);
    final total = _totalMilli(cart);
    final busy = cart.isMutating;
    final failure =
        (cart.error != null && cart.errorOperation == CartOperation.complete)
        ? cart.error
        : null;
    final names = {
      for (final l in sale.items)
        l.id: l.productName ?? 'Item ${l.productVariationId}',
    };
    final retrying =
        cart.hasPendingCompletion && failure != null && failure.isRetryable;

    return _Shell(
      title: 'Take payment',
      onClose: busy ? null : () => Navigator.of(context).pop(),
      footer: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Always visible next to the button (the form above can scroll).
          if (plan.problem != null && _touched)
            Padding(
              padding: const EdgeInsets.only(bottom: PosTokens.s8),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  plan.problem!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: busy ? null : () => Navigator.of(context).pop(),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                  ),
                  child: const Text('Cancel'),
                ),
              ),
              const SizedBox(width: PosTokens.s12),
              Expanded(
                flex: 2,
                child: FilledButton(
                  onPressed: (!busy && plan.isValid)
                      ? () => _complete(cart)
                      : null,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(52),
                    backgroundColor: PosTokens.of(context).success,
                    foregroundColor: PosTokens.of(context).onSuccess,
                  ),
                  child: busy
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(retrying ? 'Retry payment' : 'Complete Sale'),
                ),
              ),
            ],
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.all(PosTokens.s16),
        children: [
          _AmountDue(totalMilli: total),
          const SizedBox(height: PosTokens.s12),
          if (failure != null) ...[
            _Failure(
              message: describeCheckoutError(failure, names),
              retrying: retrying,
            ),
            const SizedBox(height: PosTokens.s12),
          ],
          _ModePicker(
            mode: _mode,
            enabled: !busy,
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(height: PosTokens.s16),
          ..._modeBody(total, plan, busy),
        ],
      ),
    );
  }

  bool get _touched =>
      _tendered.text.isNotEmpty ||
      _cashApplied.text.isNotEmpty ||
      _cashReceived.text.isNotEmpty;

  List<Widget> _modeBody(int total, PaymentPlan plan, bool busy) {
    switch (_mode) {
      case PayMode.cash:
        return [
          _MoneyField(
            controller: _tendered,
            label: 'Amount tendered',
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s8),
          _QuickCash(
            dueMilli: total,
            enabled: !busy,
            onPick: (m) => setState(() => _tendered.text = formatMilli(m)),
          ),
          const SizedBox(height: PosTokens.s12),
          _ChangeRow(plan: plan, hasInput: _tendered.text.isNotEmpty),
        ];
      case PayMode.card:
      case PayMode.other:
        return [
          _RecordedOnlyNote(mode: _mode),
          const SizedBox(height: PosTokens.s12),
          _ReferenceField(
            controller: _reference,
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
        ];
      case PayMode.split:
        return [
          Text('Cash portion', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: PosTokens.s8),
          _MoneyField(
            controller: _cashApplied,
            label: 'Cash amount',
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s8),
          _MoneyField(
            controller: _cashReceived,
            label: 'Cash received (optional, if more than the amount)',
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s8),
          _QuickCash(
            dueMilli: plan.cashAppliedMilli ?? 0,
            enabled: !busy && plan.cashAppliedMilli != null,
            onPick: (m) => setState(() => _cashReceived.text = formatMilli(m)),
          ),
          const SizedBox(height: PosTokens.s16),
          Text(
            'Remaining balance',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: PosTokens.s8),
          SegmentedButton<TenderMethod>(
            segments: const [
              ButtonSegment(
                value: TenderMethod.card,
                label: Text('Card'),
                icon: Icon(Icons.credit_card),
              ),
              ButtonSegment(
                value: TenderMethod.other,
                label: Text('Other'),
                icon: Icon(Icons.more_horiz),
              ),
            ],
            selected: {_secondary},
            onSelectionChanged: busy
                ? null
                : (s) => setState(() => _secondary = s.first),
          ),
          const SizedBox(height: PosTokens.s8),
          _KeyValue(
            label: '${_secondary.label} pays',
            value: plan.cashAppliedMilli == null || plan.remainderMilli <= 0
                ? '—'
                : formatMilli(plan.remainderMilli),
            bold: true,
          ),
          const SizedBox(height: PosTokens.s8),
          const _RecordedOnlyNote(mode: PayMode.card),
          const SizedBox(height: PosTokens.s8),
          _ReferenceField(
            controller: _reference,
            enabled: !busy,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: PosTokens.s12),
          _ChangeRow(plan: plan, hasInput: _cashApplied.text.isNotEmpty),
        ];
    }
  }
}

class _Shell extends StatelessWidget {
  const _Shell({
    required this.title,
    required this.child,
    this.footer,
    this.onClose,
  });
  final String title;
  final Widget child;
  final Widget? footer;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            PosTokens.s16,
            PosTokens.s8,
            PosTokens.s8,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                onPressed: onClose,
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        const Divider(),
        Expanded(child: child),
        if (footer != null) ...[
          const Divider(),
          Padding(padding: const EdgeInsets.all(PosTokens.s16), child: footer),
        ],
      ],
    );
  }
}

class _AmountDue extends StatelessWidget {
  const _AmountDue({required this.totalMilli});
  final int totalMilli;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: 'Amount due ${formatMilli(totalMilli)}',
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: t.heroGradient,
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(PosTokens.rCard),
        ),
        // Wraps (rather than clipping the amount) when text is very large.
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: PosTokens.s8,
          children: [
            Text(
              'Amount due',
              style: text.titleMedium?.copyWith(color: Colors.white),
            ),
            Text(
              formatMilli(totalMilli),
              style: text.headlineMedium?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModePicker extends StatelessWidget {
  const _ModePicker({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });
  final PayMode mode;
  final bool enabled;
  final ValueChanged<PayMode> onChanged;

  @override
  Widget build(BuildContext context) {
    const labels = {
      PayMode.cash: 'Cash',
      PayMode.card: 'Card',
      PayMode.other: 'Other',
      PayMode.split: 'Split',
    };
    return Wrap(
      spacing: PosTokens.s8,
      runSpacing: PosTokens.s8,
      children: [
        for (final m in PayMode.values)
          ChoiceChip(
            label: Text(labels[m]!),
            selected: mode == m,
            showCheckmark: false,
            onSelected: enabled ? (_) => onChanged(m) : null,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          ),
      ],
    );
  }
}

class _MoneyField extends StatelessWidget {
  const _MoneyField({
    required this.controller,
    required this.label,
    required this.onChanged,
    this.enabled = true,
  });
  final TextEditingController controller;
  final String label;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,3}')),
      ],
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => onChanged(),
    );
  }
}

class _ReferenceField extends StatelessWidget {
  const _ReferenceField({
    required this.controller,
    required this.onChanged,
    this.enabled = true,
  });
  final TextEditingController controller;
  final VoidCallback onChanged;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      maxLength: PaymentPlan.maxReferenceLength,
      decoration: const InputDecoration(
        labelText: 'Reference (optional)',
        counterText: '',
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

class _QuickCash extends StatelessWidget {
  const _QuickCash({
    required this.dueMilli,
    required this.onPick,
    this.enabled = true,
  });
  final int dueMilli;
  final ValueChanged<int> onPick;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final amounts = PaymentPlan.quickCash(dueMilli);
    return Wrap(
      spacing: PosTokens.s8,
      runSpacing: PosTokens.s8,
      children: [
        OutlinedButton(
          onPressed: enabled ? () => onPick(dueMilli) : null,
          style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
          child: const Text('Exact'),
        ),
        for (final a in amounts)
          OutlinedButton(
            onPressed: enabled ? () => onPick(a) : null,
            style: OutlinedButton.styleFrom(minimumSize: const Size(64, 48)),
            child: Text(formatMilli(a).replaceAll(RegExp(r'\.00$'), '')),
          ),
      ],
    );
  }
}

class _ChangeRow extends StatelessWidget {
  const _ChangeRow({required this.plan, required this.hasInput});
  final PaymentPlan plan;
  final bool hasInput;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = PosTokens.of(context);
    final short = plan.shortByMilli;
    final showShort = hasInput && short > 0;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                showShort ? 'Short by' : 'Change due',
                style: theme.textTheme.titleMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: PosTokens.s8),
            Flexible(
              child: Text(
                showShort
                    ? formatMilli(short)
                    : formatMilli(plan.changeDueMilli),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: showShort ? theme.colorScheme.error : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordedOnlyNote extends StatelessWidget {
  const _RecordedOnlyNote({required this.mode});
  final PayMode mode;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Icon(Icons.info_outline, size: 18),
        const SizedBox(width: PosTokens.s8),
        Expanded(
          child: Text(
            'Recorded only — no card terminal is connected. Take the payment on your terminal, '
            'then enter its reference below.',
            style: text.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue({
    required this.label,
    required this.value,
    this.bold = false,
  });
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.message, required this.retrying});
  final String message;
  final bool retrying;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(PosTokens.s12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: TextStyle(color: scheme.onErrorContainer)),
            if (retrying)
              Padding(
                padding: const EdgeInsets.only(top: PosTokens.s8),
                child: Text(
                  'It is safe to retry: the same request key is sent again, so the customer is never charged twice.',
                  style: TextStyle(
                    color: scheme.onErrorContainer,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- success

class _SuccessView extends StatelessWidget {
  const _SuccessView({
    required this.sale,
    required this.names,
    required this.variants,
  });
  final CompletedSale sale;
  final Map<int, String> names;
  final Map<int, String> variants;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final when = sale.completedAt;
    final change = sale.changeDue;
    final session = context.read<SessionController>();

    return _Shell(
      title: 'Sale complete',
      onClose: () => _newSale(context),
      footer: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            onPressed: () => _newSale(context),
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('New Sale'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: t.success,
              foregroundColor: t.onSuccess,
            ),
          ),
          const SizedBox(height: PosTokens.s8),
          ReceiptActions(
            receipt: ReceiptFormatter.build(
              sale: sale,
              names: names,
              variants: variants,
              staffId: session.salesmanId,
              deviceId: session.deviceIdentifier,
            ),
          ),
        ],
      ),
      child: ListView(
        padding: const EdgeInsets.all(PosTokens.s16),
        children: [
          Center(child: Icon(Icons.check_circle, size: 56, color: t.success)),
          const SizedBox(height: PosTokens.s8),
          Center(
            child: Text('Payment received', style: theme.textTheme.titleLarge),
          ),
          const SizedBox(height: PosTokens.s16),
          _KeyValue(label: 'Order', value: sale.displayNumber, bold: true),
          if (when != null)
            _KeyValue(label: 'Date / time', value: formatTimestamp(when)),
          if (sale.customerId != null)
            _KeyValue(label: 'Customer', value: sale.customerId!)
          else
            const _KeyValue(label: 'Customer', value: 'Guest checkout'),
          const Divider(height: PosTokens.s24),
          Text('Items', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final line in sale.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          names[line.id] ?? 'Item ${line.productVariationId}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${line.quantity} × ${formatMoney(line.unitPrice)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PosTokens.s8),
                  Text(formatMoney(line.lineTotal)),
                ],
              ),
            ),
          const Divider(height: PosTokens.s24),
          _KeyValue(
            label: 'Subtotal',
            value: formatMoney(sale.totals.subtotal),
          ),
          _KeyValue(label: 'Tax', value: formatMoney(sale.totals.taxTotal)),
          if (sale.totals.discountTotal != null &&
              sale.totals.discountTotal != 0)
            _KeyValue(
              label: 'Discount',
              value: formatMoney(sale.totals.discountTotal),
            ),
          _KeyValue(
            label: 'Total',
            value: formatMoney(sale.totals.grandTotal),
            bold: true,
          ),
          const Divider(height: PosTokens.s24),
          Text('Payment', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final p in sale.payments) ...[
            _KeyValue(
              label: _methodLabel(p.method),
              value: formatMoney(p.amount),
            ),
            if (p.tendered != null)
              _KeyValue(label: '  Tendered', value: formatMoney(p.tendered)),
            if ((p.changeDue ?? 0) > 0)
              _KeyValue(label: '  Change', value: formatMoney(p.changeDue)),
          ],
          if (change > 0) ...[
            const SizedBox(height: PosTokens.s8),
            Semantics(
              liveRegion: true,
              child: Container(
                padding: const EdgeInsets.all(PosTokens.s12),
                decoration: BoxDecoration(
                  color: t.surfaceMuted,
                  borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Change due', style: theme.textTheme.titleMedium),
                    Text(
                      formatMoney(change),
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _methodLabel(String wire) =>
      TenderMethod.fromWire(wire)?.label ?? wire;

  void _newSale(BuildContext context) {
    context.read<CartController>().acknowledgeCompletion();
    Navigator.of(context).pop();
  }
}
