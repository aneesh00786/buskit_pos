import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/quantity.dart';
import '../../scale/ui/scale_weight_panel.dart';
import '../state/cart_controller.dart';

/// Asks for an exact quantity. Client-side validation only checks it is a
/// whole number in the range the backend accepts; the server still decides.
/// Phase 12B: with [weight] it takes a weight instead — a positive decimal
/// with at most 3 places (0.250, 1.25, 2.500) — refused, never rounded, when
/// it has more. Returns an int for whole numbers, else the exact decimal.
/// Phase 18A: with [weight] and [useScale], a configured scale ([ScaleScope])
/// can fill the weight field with a stable reading; the cashier still
/// confirms, and manual entry is unchanged.
Future<num?> showQuantityDialog(
  BuildContext context, {
  required num initial,
  required String itemName,
  bool weight = false,
  bool useScale = false,
}) {
  return showDialog<num>(
    context: context,
    builder: (_) => _QuantityDialog(
      initial: initial,
      itemName: itemName,
      weight: weight,
      useScale: useScale,
    ),
  );
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({
    required this.initial,
    required this.itemName,
    this.weight = false,
    this.useScale = false,
  });
  final num initial;
  final String itemName;
  final bool weight;
  final bool useScale;

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

  /// Phase 18A: the scale panel, only for a WEIGHT item when a scale is
  /// configured. It fills the field; it never submits.
  Widget? _scalePanel(BuildContext context) {
    final scale = ScaleScope.maybeOf(context);
    if (scale == null) return null;
    return ScaleWeightPanel(
      controller: scale,
      onUseWeight: (text) => setState(() {
        _c.text = text;
        _c.selection = TextSelection.collapsed(offset: text.length);
        _error = null;
      }),
    );
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
          if (widget.weight && widget.useScale) ?_scalePanel(context),
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
