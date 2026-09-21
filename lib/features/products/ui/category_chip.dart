import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';

/// Pill-shaped category filter with a clear active state.
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onSelected,
  });

  final String label;
  final bool selected;
  final VoidCallback onSelected;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = PosTokens.of(context);
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onSelected(),
      selectedColor: scheme.primary,
      backgroundColor: t.surface,
      labelStyle: TextStyle(
        color: selected ? scheme.onPrimary : scheme.onSurface,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      side: BorderSide(color: selected ? scheme.primary : t.border),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
      materialTapTargetSize: MaterialTapTargetSize.padded,
    );
  }
}
