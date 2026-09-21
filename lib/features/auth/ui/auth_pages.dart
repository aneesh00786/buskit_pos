import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../state/session_controller.dart';

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: Theme.of(context).textTheme.bodyMedium),
                  const SizedBox(height: 24),
                  ...children,
                  if (session.error != null) ...[
                    const SizedBox(height: 16),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        describeApiError(session.error!),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                  if (session.notice != null) ...[
                    const SizedBox(height: 16),
                    Text(session.notice!),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DeviceLoginPage extends StatefulWidget {
  const DeviceLoginPage({super.key});
  @override
  State<DeviceLoginPage> createState() => _DeviceLoginPageState();
}

class _DeviceLoginPageState extends State<DeviceLoginPage> {
  final _id = TextEditingController();
  final _secret = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _secret.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SessionController>();
    final canSubmit =
        !s.busy && _id.text.trim().isNotEmpty && _secret.text.isNotEmpty;
    return _AuthScaffold(
      title: 'Register this device',
      subtitle: 'Enter the device credentials issued by your administrator.',
      children: [
        TextField(
          controller: _id,
          decoration: const InputDecoration(labelText: 'Device identifier'),
          textInputAction: TextInputAction.next,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _secret,
          decoration: const InputDecoration(labelText: 'Device secret'),
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) =>
              canSubmit ? s.loginDevice(_id.text, _secret.text) : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canSubmit
              ? () => s.loginDevice(_id.text, _secret.text)
              : null,
          child: s.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }
}

class StaffLoginPage extends StatefulWidget {
  const StaffLoginPage({super.key});
  @override
  State<StaffLoginPage> createState() => _StaffLoginPageState();
}

class _StaffLoginPageState extends State<StaffLoginPage> {
  final _id = TextEditingController();
  final _pin = TextEditingController();

  @override
  void dispose() {
    _id.dispose();
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SessionController>();
    final canSubmit =
        !s.busy && _id.text.trim().isNotEmpty && _pin.text.isNotEmpty;
    return _AuthScaffold(
      title: 'Cashier sign-in',
      subtitle: s.deviceIdentifier == null
          ? 'Enter your staff ID and PIN.'
          : 'Device ${s.deviceIdentifier}',
      children: [
        TextField(
          controller: _id,
          decoration: const InputDecoration(labelText: 'Staff ID'),
          textInputAction: TextInputAction.next,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pin,
          decoration: const InputDecoration(labelText: 'PIN'),
          obscureText: true,
          keyboardType: TextInputType.number,
          enableSuggestions: false,
          autocorrect: false,
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) =>
              canSubmit ? s.loginStaff(_id.text, _pin.text) : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canSubmit ? () => s.loginStaff(_id.text, _pin.text) : null,
          child: s.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Sign in'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: s.busy ? null : s.changeDevice,
          child: const Text('Use a different device'),
        ),
      ],
    );
  }
}

class ShiftOpenPage extends StatefulWidget {
  const ShiftOpenPage({super.key});
  @override
  State<ShiftOpenPage> createState() => _ShiftOpenPageState();
}

class _ShiftOpenPageState extends State<ShiftOpenPage> {
  final _amount = TextEditingController(text: '0');

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  double? get _value {
    final v = double.tryParse(_amount.text.trim());
    return (v == null || v < 0) ? null : v;
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<SessionController>();
    final canSubmit = !s.busy && _value != null;
    return _AuthScaffold(
      title: 'Open shift',
      subtitle:
          'Signed in as ${s.salesmanId ?? ''}. Enter the cash in the drawer.',
      children: [
        TextField(
          controller: _amount,
          decoration: const InputDecoration(labelText: 'Opening cash amount'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => canSubmit ? s.openShift(_value!) : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canSubmit ? () => s.openShift(_value!) : null,
          child: s.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Open shift'),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: s.busy ? null : s.logoutStaff,
          child: const Text('Sign out'),
        ),
      ],
    );
  }
}
