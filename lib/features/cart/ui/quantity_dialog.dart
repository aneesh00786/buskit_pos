import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/cart_controller.dart';

/// Asks for an exact quantity. Client-side validation only checks it is a
/// whole number in the range the backend accepts; the server still decides.
Future<int?> showQuantityDialog(
  BuildContext context, {
  required int initial,
  required String itemName,
}) {
  return showDialog<int>(
    context: context,
    builder: (_) => _QuantityDialog(initial: initial, itemName: itemName),
  );
}

class _QuantityDialog extends StatefulWidget {
  const _QuantityDialog({required this.initial, required this.itemName});
  final int initial;
  final String itemName;

  @override
  State<_QuantityDialog> createState() => _QuantityDialogState();
}

class _QuantityDialogState extends State<_QuantityDialog> {
  late final TextEditingController _c = TextEditingController(
    text: '${widget.initial}',
  );
  String? _error;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _submit() {
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
      title: const Text('Set quantity'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.itemName, maxLines: 2, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 12),
          TextField(
            controller: _c,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'Quantity',
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
