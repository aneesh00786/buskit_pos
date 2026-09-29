import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../models/customer.dart';
import '../state/customer_list_controller.dart';

/// Create/edit form for a customer. Only the fields the backend actually
/// accepts (fullname, mobileno, email) — no address/business/tax fields,
/// since POS's customer API doesn't read or write them.
///
/// On a duplicate-mobile/email conflict (409), offers to select the existing
/// customer instead of just failing, using the `existing_customer_id` the
/// backend returns.
Future<Customer?> showCustomerForm(BuildContext context, {Customer? edit}) {
  return showDialog<Customer?>(
    context: context,
    builder: (_) => ChangeNotifierProvider<CustomerListController>.value(
      value: context.read<CustomerListController>(),
      child: _CustomerForm(edit: edit),
    ),
  );
}

class _CustomerForm extends StatefulWidget {
  const _CustomerForm({this.edit});
  final Customer? edit;

  @override
  State<_CustomerForm> createState() => _CustomerFormState();
}

class _CustomerFormState extends State<_CustomerForm> {
  final _formKey = GlobalKey<FormState>();
  late final _fullname = TextEditingController(text: widget.edit?.fullname);
  late final _mobileno = TextEditingController(text: widget.edit?.mobileno);
  late final _email = TextEditingController(text: widget.edit?.email);
  String? _duplicateExistingId;
  String? _duplicateMessage;

  bool get _isEdit => widget.edit != null;

  @override
  void dispose() {
    _fullname.dispose();
    _mobileno.dispose();
    _email.dispose();
    super.dispose();
  }

  String? _validateFullname(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Name is required.';
    if (t.length > 250) return 'Name must be at most 250 characters.';
    return null;
  }

  String? _validateMobile(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return 'Phone is required.';
    if (!RegExp(r'^[0-9+\-\s]{4,20}$').hasMatch(t)) {
      return 'Enter a valid phone number.';
    }
    return null;
  }

  String? _validateEmail(String? v) {
    final t = v?.trim() ?? '';
    if (t.isEmpty) return null;
    final ok = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(t);
    return ok ? null : 'Enter a valid email address.';
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _duplicateExistingId = null;
      _duplicateMessage = null;
    });
    final controller = context.read<CustomerListController>();
    final email = _email.text.trim();
    Customer? result;
    if (_isEdit) {
      final ok = await controller.updateCustomer(
        widget.edit!.customerId,
        fullname: _fullname.text.trim(),
        mobileno: _mobileno.text.trim(),
        email: email.isEmpty ? null : email,
      );
      if (ok) {
        result = controller.items.firstWhere(
          (c) => c.customerId == widget.edit!.customerId,
          orElse: () => widget.edit!,
        );
      }
    } else {
      result = await controller.createCustomer(
        fullname: _fullname.text.trim(),
        mobileno: _mobileno.text.trim(),
        email: email.isEmpty ? null : email,
      );
    }
    if (!mounted) return;
    if (result != null) {
      Navigator.of(context).pop(result);
      return;
    }
    final e = controller.mutationError;
    final isDuplicate =
        e != null &&
        (e.errorCode == PosErrorCodes.duplicateMobile ||
            e.errorCode == PosErrorCodes.duplicateEmail);
    if (isDuplicate) {
      setState(() {
        _duplicateExistingId = asExistingCustomerId(e);
        _duplicateMessage = describeApiError(e);
      });
    }
  }

  void _useExisting() {
    final id = _duplicateExistingId;
    if (id == null) return;
    context.read<CustomerListController>().clearMutationError();
    Navigator.of(context).pop();
    context.read<CustomerListController>().selectCustomer(id);
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<CustomerListController>();
    final e = controller.mutationError;
    final generalError =
        e != null &&
            e.errorCode != PosErrorCodes.duplicateMobile &&
            e.errorCode != PosErrorCodes.duplicateEmail
        ? describeApiError(e)
        : null;

    return AlertDialog(
      title: Text(_isEdit ? 'Edit customer' : 'New customer'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _fullname,
                autofocus: true,
                enabled: !controller.isMutating,
                decoration: const InputDecoration(labelText: 'Name *'),
                validator: _validateFullname,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: PosTokens.s12),
              TextFormField(
                controller: _mobileno,
                enabled: !controller.isMutating,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone *'),
                validator: _validateMobile,
                textInputAction: TextInputAction.next,
              ),
              const SizedBox(height: PosTokens.s12),
              TextFormField(
                controller: _email,
                enabled: !controller.isMutating,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
                validator: _validateEmail,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
              ),
              if (_duplicateMessage != null) ...[
                const SizedBox(height: PosTokens.s12),
                Text(
                  _duplicateMessage!,
                  style: TextStyle(color: PosTokens.of(context).danger),
                ),
                if (_duplicateExistingId != null) ...[
                  const SizedBox(height: PosTokens.s8),
                  OutlinedButton(
                    onPressed: _useExisting,
                    child: const Text('Use this existing customer'),
                  ),
                ],
              ] else if (generalError != null) ...[
                const SizedBox(height: PosTokens.s12),
                Text(
                  generalError,
                  style: TextStyle(color: PosTokens.of(context).danger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: controller.isMutating
              ? null
              : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: controller.isMutating ? null : _submit,
          child: controller.isMutating
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEdit ? 'Save' : 'Save Customer'),
        ),
      ],
    );
  }
}

/// Reads `data.existing_customer_id` off a duplicate-mobile/email conflict.
String? asExistingCustomerId(ApiException e) {
  final v = e.dataMap?['existing_customer_id'];
  return v is String ? v : null;
}
