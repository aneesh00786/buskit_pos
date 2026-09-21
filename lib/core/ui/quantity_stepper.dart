import 'package:flutter/material.dart';

/// − / quantity / + control with 48dp touch targets. When [onTapValue] is
/// given the number itself is tappable (used to type an exact quantity).
class QuantityStepper extends StatelessWidget {
  const QuantityStepper({
    super.key,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
    this.enabled = true,
    this.onTapValue,
  });

  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  final bool enabled;
  final VoidCallback? onTapValue;

  @override
  Widget build(BuildContext context) {
    final valueText = Text(
      '$value',
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleLarge,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          tooltip: 'Decrease quantity',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: enabled && value > min ? () => onChanged(value - 1) : null,
          icon: const Icon(Icons.remove),
        ),
        Semantics(
          label: 'Quantity $value',
          button: onTapValue != null,
          child: InkWell(
            onTap: enabled ? onTapValue : null,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              child: Center(child: valueText),
            ),
          ),
        ),
        IconButton.outlined(
          tooltip: 'Increase quantity',
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          onPressed: enabled && value < max ? () => onChanged(value + 1) : null,
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}
