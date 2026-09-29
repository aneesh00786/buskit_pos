import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/storage/token_store.dart';
import '../state/session_controller.dart';
// TESTING ONLY (see lib/features/auth/dev/dev_credentials.dart) — delete this
// import and every dev-gated block below before a production build.
import '../dev/dev_credentials.dart';
import '../dev/dev_login_helper.dart';

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

  // ---- TESTING ONLY below (see lib/features/auth/dev/) ----
  bool _devBusy = false;
  String? _devMessage;
  DevCredentialsStore? _devStore;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _devAutofill());
    }
  }

  DevLoginHelper _devHelper() {
    _devStore ??= DevCredentialsStore(SecureTokenStore());
    return DevLoginHelper(context.read<PosApiClient>(), _devStore!);
  }

  /// Local-storage only, deliberately — no network call, so this can never
  /// interfere with a widget test's mock backend (kDebugMode is also true
  /// under `flutter test`). Live validation only happens on an explicit tap
  /// of "Dev: generate a new test device" below.
  Future<void> _devAutofill() async {
    if (!mounted) return;
    final saved = await (_devStore ??= DevCredentialsStore(
      SecureTokenStore(),
    )).load();
    if (!mounted || saved == null) return;
    setState(() {
      _id.text = saved.deviceIdentifier;
      _secret.text = saved.deviceSecret;
      _devMessage = 'Autofilled from the saved test device.';
    });
  }

  Future<void> _devRegenerate() async {
    setState(() {
      _devBusy = true;
      _devMessage = null;
    });
    final helper = _devHelper();
    final saved = await (_devStore ??= DevCredentialsStore(
      SecureTokenStore(),
    )).load();
    final fresh = saved == null ? null : await helper.regenerate(saved);
    if (!mounted) return;
    setState(() {
      _devBusy = false;
      if (fresh != null) {
        _id.text = fresh.deviceIdentifier;
        _secret.text = fresh.deviceSecret;
        _devMessage = 'Generated a new test device: ${fresh.deviceIdentifier}';
      } else {
        _devMessage = saved == null
            ? 'No saved test device to regenerate from — sign in manually once first.'
            : 'The saved test device could not be refreshed (it may have been deleted) — sign in manually once to save a new one.';
      }
    });
  }
  // ---- end testing-only ----

  Future<void> _submit(SessionController s) async {
    final id = _id.text;
    final secret = _secret.text;
    final ok = await s.loginDevice(id, secret);
    // TESTING ONLY — remembers a manually-entered device as the autofill seed.
    if (ok && kDebugMode) {
      await (_devStore ??= DevCredentialsStore(
        SecureTokenStore(),
      )).rememberDevice(id.trim(), secret);
    }
  }

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
          onSubmitted: (_) => canSubmit ? _submit(s) : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canSubmit ? () => _submit(s) : null,
          child: s.busy
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
        // TESTING ONLY — remove this block before a production build.
        if (kDebugMode) ...[
          const SizedBox(height: 12),
          const Divider(),
          TextButton.icon(
            onPressed: _devBusy ? null : _devRegenerate,
            icon: _devBusy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.bolt_outlined),
            label: const Text('Dev: generate a new test device'),
          ),
          if (_devMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _devMessage!,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
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
  void initState() {
    super.initState();
    // TESTING ONLY (see lib/features/auth/dev/) — read-only, no network call:
    // DeviceLoginPage already ensured the saved staff id/PIN work by the time
    // this screen shows.
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _devAutofill());
    }
  }

  Future<void> _devAutofill() async {
    final saved = await DevCredentialsStore(SecureTokenStore()).load();
    if (!mounted || saved == null) return;
    setState(() {
      _id.text = saved.staffId;
      _pin.text = saved.pin;
    });
  }

  Future<void> _submit(SessionController s) async {
    final id = _id.text;
    final pin = _pin.text;
    final ok = await s.loginStaff(id, pin);
    // TESTING ONLY — remembers a manually-entered staff id/PIN as the autofill seed.
    if (ok && kDebugMode) {
      await DevCredentialsStore(SecureTokenStore())
          .rememberStaff(id.trim(), pin);
    }
  }

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
          onSubmitted: (_) => canSubmit ? _submit(s) : null,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: canSubmit ? () => _submit(s) : null,
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
