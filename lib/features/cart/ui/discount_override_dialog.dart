import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../models/discount_override.dart';
import '../state/cart_controller.dart';

/// Cart -> Discount -> enter type/amount -> validate -> confirm -> update
/// sale -> refresh authoritative totals. EVERY manual discount here is an
/// override (`discounts.override`, backend-enforced) — there is no "normal
/// discount" tier to distinguish from. Mirrors [showPromotionPicker]'s
/// shape (a sheet reusing the existing CartController), not a new screen.
Future<void> showDiscountOverrideDialog(
  BuildContext context, {
  DiscountOverride? current,
}) async {
  final cart = context.read<CartController>();
  final request = await showDialog<_DiscountRequest>(
    context: context,
    builder: (_) => ChangeNotifierProvider<CartController>.value(
      value: cart,
      child: _DiscountForm(current: current),
    ),
  );
  if (request == null || !context.mounted) return;

  final confirmed = await _confirmDiscount(context, request);
  if (confirmed != true || !context.mounted) return;

  final ok = await cart.applyDiscountOverride(
    discountType: request.type,
    discountValue: request.value,
    reason: request.reason,
  );
  if (!context.mounted) return;
  if (!ok) {
    final err = cart.error;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            err != null ? describeApiError(err) : 'The discount could not be applied.',
          ),
        ),
      );
    cart.clearError();
  }
}

class _DiscountRequest {
  const _DiscountRequest({required this.type, required this.value, this.reason});
  final String type;
  final String value;
  final String? reason;
}

Future<bool?> _confirmDiscount(BuildContext context, _DiscountRequest r) {
  final label = r.type == 'percentage' ? '${r.value}%' : formatMoney(double.tryParse(r.value));
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm discount'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Discount', label),
          _KeyValue('Reason', (r.reason == null || r.reason!.isEmpty) ? '—' : r.reason!),
          const SizedBox(height: PosTokens.s12),
          Text(
            'This overrides the normal discount rules and applies to the whole sale.',
            style: Theme.of(ctx).textTheme.bodySmall
                ?.copyWith(color: Theme.of(ctx).colorScheme.error),
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
          child: const Text('Apply'),
        ),
      ],
    ),
  );
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
          Text(value, style: style),
        ],
      ),
    );
  }
}

class _DiscountForm extends StatefulWidget {
  const _DiscountForm({this.current});
  final DiscountOverride? current;

  @override
  State<_DiscountForm> createState() => _DiscountFormState();
}

class _DiscountFormState extends State<_DiscountForm> {
  late String _type = widget.current?.discountType ?? 'percentage';
  late final _value = TextEditingController(
    text: widget.current == null ? '' : _trim(widget.current!.discountValue),
  );
  late final _reason = TextEditingController(text: widget.current?.reason ?? '');
  String? _error;

  static String _trim(double v) {
    var s = v.toStringAsFixed(2);
    if (s.endsWith('0')) s = s.substring(0, s.length - 1);
    if (s.endsWith('.0') || s.endsWith('.')) s = s.substring(0, s.length - 1);
    return s;
  }

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _value.text.trim();
    if (_type == 'percentage') {
      if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(raw)) {
        setState(() => _error = 'Enter a percentage with at most 2 decimal places');
        return;
      }
      final v = double.parse(raw);
      if (v <= 0 || v > 100) {
        setState(() => _error = 'Enter a percentage greater than 0 and at most 100');
        return;
      }
    } else {
      if (!RegExp(r'^\d+(\.\d{1,3})?$').hasMatch(raw)) {
        setState(() => _error = 'Enter an amount with at most 3 decimal places');
        return;
      }
      if (double.parse(raw) <= 0) {
        setState(() => _error = 'Enter an amount greater than 0');
        return;
      }
    }
    Navigator.of(context).pop(
      _DiscountRequest(
        type: _type,
        value: raw,
        reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Discount'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'percentage', label: Text('Percentage')),
                ButtonSegment(value: 'flat', label: Text('Amount')),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() {
                _type = s.first;
                _error = null;
              }),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _value,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: _type == 'percentage' ? 'Percentage *' : 'Amount *',
                suffixText: _type == 'percentage' ? '%' : null,
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
              decoration: const InputDecoration(labelText: 'Reason'),
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
