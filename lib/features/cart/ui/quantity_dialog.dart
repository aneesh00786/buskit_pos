import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/quantity.dart';
import '../state/cart_controller.dart';

/// Asks for an exact quantity. Client-side validation only checks it is a
/// whole number in the range the backend accepts; the server still decides.
/// Phase 12B: with [weight] it takes a weight instead — a positive decimal
/// with at most 3 places (0.250, 1.25, 2.500) — refused, never rounded, when
/// it has more. Returns an int for whole numbers, else the exact decimal.
Future<num?> showQuantityDialog(
  BuildContext context, {
  required num initial,
  required String itemName,
  bool weight = false,
}) {
  return showDialog<num>(
    context: context,
    builder: (_) =>
        _QuantityDialog(initial: initial, itemName: itemName, weight: weight),
  );
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({
    required this.initial,
    required this.itemName,
    this.weight = false,
  });
  final num initial;
  final String itemName;
  final bool weight;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController _c = TextEditingController(
    text: formatQuantity(widget.initial, weight: widget.weight),
  );
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
    if (widget.weight) {
      final problem = quantityError('WEIGHT', _c.text.trim());
      if (problem != null) {
        setState(() => _error = problem);
        return;
      }
      Navigator.of(context)
          .pop(quantityFromMilli(quantityMilliOf(_c.text.trim())!));
      return;
    }
    final v = int.tryParse(_c.text.trim());
    if (v == null ||
        v < CartController.minQuantity ||
        v > CartController.maxQuantity) {
      setState(
        () => _error =
            'Enter a whole number from ${CartController.minQuantity} to ${CartController.maxQuantity}',
      );
      return;
    }
    Navigator.of(context).pop(v);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.weight ? 'Set weight' : 'Set quantity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.itemName, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: widget.weight
                ? const TextInputType.numberWithOptions(decimal: true)
                : TextInputType.number,
            // Weight: digits and one decimal point (the 3-place limit is
            // checked on submit so an over-precise entry is refused, not cut).
            inputFormatters: [
              widget.weight
                  ? TextInputFormatter.withFunction(
                      (oldValue, newValue) =>
                          RegExp(r'^\d*\.?\d*$').hasMatch(newValue.text)
                          ? newValue
                          : oldValue,
                    )
                  : FilteringTextInputFormatter.digitsOnly,
            ],
            decoration: InputDecoration(
              labelText: widget.weight ? 'Weight' : 'Quantity',
              helperText: widget.weight ? 'Up to 3 decimal places' : null,
              errorText: _error,
            ),
            onChanged: (_) => setState(() => _error = null),
            onSubmitted: (_) => _submit(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Update')),
      ],
    );
  }
}
