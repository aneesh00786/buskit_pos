import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../customers/data/customer_service.dart';
import '../../customers/models/customer.dart';
import '../../customers/state/customer_list_controller.dart';
import '../../customers/ui/customer_form.dart';
import '../../customers/ui/customers_view.dart' show CustomerAvatar;

/// Result of the customer dialog: `guest == true` means guest checkout,
/// otherwise [customerId] holds the customer picked from search (or the one
/// just created). The backend still validates this id when the sale is
/// created — a search hit is a strong signal but not a guarantee (it could
/// be deleted or moved between the search and the first item being added).
class CustomerChoice {
  const CustomerChoice.guest() : customerId = null, label = null;
  const CustomerChoice.customer(String this.customerId, {this.label});
  final String? customerId;
  final String? label;
  bool get isGuest => customerId == null;
}

/// Asks who the sale is for: guest checkout, or an existing customer found by
/// searching the same POS-scoped customer directory the Customers screen
/// uses, with a shortcut to create a new one on the spot (auto-selected).
Future<CustomerChoice?> showCustomerDialog(
  BuildContext context, {
  String? current,
}) {
  final client = context.read<PosApiClient>();
  final controller = CustomerListController(ApiCustomerService(client));
  return showDialog<CustomerChoice>(
    context: context,
    builder: (_) => ChangeNotifierProvider<CustomerListController>.value(
      value: controller,
      child: _CustomerDialog(current: current),
    ),
  ).whenComplete(controller.dispose);
}

class _CustomerDialog extends StatefulWidget {
  const _CustomerDialog({this.current});
  final String? current;

  @override
  State<_CustomerDialog> createState() => _CustomerDialogState();
}

class _CustomerDialogState extends State<_CustomerDialog> {
  late bool _guest = widget.current == null;
  String? _selectedId;
  String? _selectedLabel;
  bool _loadStarted = false;

  @override
  void initState() {
    super.initState();
    _selectedId = widget.current;
    if (!_guest) _ensureLoaded();
  }

  void _ensureLoaded() {
    if (_loadStarted) return;
    _loadStarted = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CustomerListController>().loadInitial();
    });
  }

  void _select(Customer c) {
    setState(() {
      _selectedId = c.customerId;
      _selectedLabel = c.fullname;
    });
  }

  Future<void> _createNew() async {
    final created = await showCustomerForm(context);
    if (created != null && mounted) {
      setState(() {
        _selectedId = created.customerId;
        _selectedLabel = created.fullname;
      });
    }
  }

  void _save() {
    if (_guest) {
      Navigator.of(context).pop(const CustomerChoice.guest());
      return;
    }
    final id = _selectedId;
    if (id == null) return;
    Navigator.of(context).pop(CustomerChoice.customer(id, label: _selectedLabel));
  }

  @override
  Widget build(BuildContext context) {
    final canSave = _guest || _selectedId != null;
    return AlertDialog(
      title: const Text('Customer'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
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
                  label: Text('Search'),
                  icon: Icon(Icons.search),
                ),
              ],
              selected: {_guest},
              onSelectionChanged: (s) {
                setState(() => _guest = s.first);
                if (!_guest) _ensureLoaded();
              },
            ),
            if (!_guest) ...[
              const SizedBox(height: PosTokens.s12),
              _CustomerPicker(
                selectedId: _selectedId,
                selectedLabel: _selectedLabel,
                onSelect: _select,
                onCreateNew: _createNew,
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
        FilledButton(
          onPressed: canSave ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _CustomerPicker extends StatefulWidget {
  const _CustomerPicker({
    required this.selectedId,
    required this.selectedLabel,
    required this.onSelect,
    required this.onCreateNew,
  });
  final String? selectedId;
  final String? selectedLabel;
  final ValueChanged<Customer> onSelect;
  final VoidCallback onCreateNew;

  @override
  State<_CustomerPicker> createState() => _CustomerPickerState();
}

class _CustomerPickerState extends State<_CustomerPicker> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<CustomerListController>();
    final t = PosTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.selectedId != null)
          Padding(
            padding: const EdgeInsets.only(bottom: PosTokens.s8),
            child: Row(
              children: [
                Icon(Icons.check_circle, size: 16, color: t.success),
                const SizedBox(width: PosTokens.s8),
                Expanded(
                  child: Text(
                    'Selected: ${widget.selectedLabel ?? widget.selectedId}',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        TextField(
          controller: _search,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            isDense: true,
            filled: true,
            fillColor: t.surfaceMuted,
            contentPadding: const EdgeInsets.symmetric(
              vertical: 12,
              horizontal: 12,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(PosTokens.rPill),
              borderSide: BorderSide.none,
            ),
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search customers by name or phone',
          ),
          onChanged: (v) => c.onQueryChanged(v),
          onSubmitted: (v) => c.submitQuery(v),
        ),
        const SizedBox(height: PosTokens.s8),
        SizedBox(
          height: 260,
          child: _ResultsList(
            controller: c,
            selectedId: widget.selectedId,
            onSelect: widget.onSelect,
          ),
        ),
        const SizedBox(height: PosTokens.s4),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: widget.onCreateNew,
            icon: const Icon(Icons.person_add_alt_outlined),
            label: const Text('+ New Customer'),
          ),
        ),
      ],
    );
  }
}

class _ResultsList extends StatelessWidget {
  const _ResultsList({
    required this.controller,
    required this.selectedId,
    required this.onSelect,
  });
  final CustomerListController controller;
  final String? selectedId;
  final ValueChanged<Customer> onSelect;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case CustomerListStatus.idle:
      case CustomerListStatus.loading:
        return const LoadingView(label: 'Loading customers');
      case CustomerListStatus.error:
        final e = controller.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: controller.retry,
        );
      case CustomerListStatus.empty:
        return EmptyView(
          title: controller.query.isEmpty
              ? 'No customers yet'
              : 'No customers found',
          message: controller.query.isEmpty
              ? 'Use + New Customer below to add one.'
              : 'Try a different search.',
          icon: Icons.people_outline,
        );
      case CustomerListStatus.loaded:
        return ListView.builder(
          itemCount: controller.items.length,
          itemBuilder: (_, i) {
            final customer = controller.items[i];
            final selected = customer.customerId == selectedId;
            return ListTile(
              dense: true,
              selected: selected,
              selectedTileColor: PosTokens.of(context).surfaceMuted,
              leading: CustomerAvatar(customer: customer, size: 36, fontSize: 14),
              title: Text(
                customer.fullname,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                [
                  if (customer.mobileno != null &&
                      customer.mobileno!.isNotEmpty)
                    customer.mobileno!,
                  customer.customerId,
                ].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: selected
                  ? Icon(Icons.check, color: PosTokens.of(context).success)
                  : null,
              onTap: () => onSelect(customer),
            );
          },
        );
    }
  }
}
