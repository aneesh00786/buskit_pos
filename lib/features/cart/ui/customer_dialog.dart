import 'package:flutter/material.dart';

/// Result of the customer dialog: `guest == true` means guest checkout,
/// otherwise [customerId] holds the ID typed by the cashier.
class CustomerChoice {
  const CustomerChoice.guest() : customerId = null;
  const CustomerChoice.customer(String this.customerId);
  final String? customerId;
  bool get isGuest => customerId == null;
}

/// Asks who the sale is for. The backend accepts a customer ID only when the
/// sale is CREATED and validates it then (an unknown ID is rejected on the
/// first item), and there is no customer search — so this is a guest/ID choice
/// made before the first item, not a lookup.
Future<CustomerChoice?> showCustomerDialog(
  BuildContext context, {
  String? current,
}) {
  return showDialog<CustomerChoice>(
    context: context,
    builder: (_) => _CustomerDialog(current: current),
  );
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.current});
  final String? current;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  late bool _guest = widget.current == null;
  late final TextEditingController _id = TextEditingController(
    text: widget.current ?? '',
  );
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    super.dispose();
  }

  void _save() {
    if (_guest) {
      Navigator.of(context).pop(const CustomerChoice.guest());
      return;
    }
    final v = _id.text.trim();
    if (v.isEmpty || v.length > 255) {
      setState(() => _error = 'Enter a customer ID (1–255 characters).');
      return;
    }
    Navigator.of(context).pop(CustomerChoice.customer(v));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Customer'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(
                  value: true,
                  label: Text('Guest checkout'),
                  icon: Icon(Icons.person_outline),
                ),
                ButtonSegment(
                  value: false,
                  label: Text('Customer ID'),
                  icon: Icon(Icons.badge_outlined),
                ),
              ],
              selected: {_guest},
              onSelectionChanged: (s) => setState(() {
                _guest = s.first;
                _error = null;
              }),
            ),
            if (!_guest) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _id,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Customer ID',
                  errorText: _error,
                ),
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 8),
              Text(
                'The server checks this ID when the first item is added to the sale.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
