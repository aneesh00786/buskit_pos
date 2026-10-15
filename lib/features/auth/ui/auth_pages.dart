import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/storage/token_store.dart';
import '../../../core/theme/pos_tokens.dart';
import '../state/session_controller.dart';
// TESTING ONLY (see lib/features/auth/dev/dev_credentials.dart) — delete this
// import and every dev-gated block below before a production build.
import '../dev/dev_credentials.dart';

/// Shared responsive rule for the sign-in screens (device activation and
/// cashier sign-in). Wide windows: branding panel on the left, the form
/// centred in the right panel at no more than [formMaxWidth]. Below
/// [splitMinWidth]: one scrolling column with a compact brand header and
/// [stackedGutter] side margins.
abstract final class AuthLayout {
  static const double formMaxWidth = 420;
  static const double splitMinWidth = 840;
  static const double splitGutter = 32;
  static const double stackedGutter = 24;

  /// The branding panel takes ~40% of the window, kept between 320 and 520
  /// so neither it nor the form panel gets squeezed.
  static double brandPanelWidth(double windowWidth) =>
      (windowWidth * 0.4).clamp(320.0, 520.0);

  static const String illustrationAsset = 'assets/images/img_left.png';
  static const double illustrationAspectRatio = 1536 / 1024;

  /// Below this height the illustration is left out rather than shrunk.
  static const double illustrationMinHeight = 96;

  /// Split panel: share of the panel's content width / height it may use.
  static const double illustrationPanelWidthFactor = 0.8;
  static const double illustrationPanelHeightFactor = 0.42;

  /// Vertical space the panel's mark, heading, subtitle and gaps need.
  static const double brandPanelTextHeight = 220;

  /// Stacked layout: shown only when the screen is at least this tall and
  /// the keyboard is closed, never pushing the form off-screen.
  static const double stackedIllustrationMinHeight = 720;
  static const double stackedIllustrationMaxWidth = 360;
  static const double stackedIllustrationHeightFactor = 0.25;

  /// Largest aspect-correct size within [maxWidth] x [maxHeight]; null when
  /// that would be smaller than [illustrationMinHeight].
  static Size? illustrationSize(double maxWidth, double maxHeight) {
    final width = math.min(maxWidth, maxHeight * illustrationAspectRatio);
    final height = width / illustrationAspectRatio;
    if (height < illustrationMinHeight) return null;
    return Size(width, height);
  }

  /// Illustration size inside the split layout's branding panel, given the
  /// panel's content area (inside its padding).
  static Size? panelIllustrationSize(
    double contentWidth,
    double contentHeight,
  ) => illustrationSize(
    contentWidth * illustrationPanelWidthFactor,
    math.min(
      contentHeight * illustrationPanelHeightFactor,
      contentHeight - brandPanelTextHeight,
    ),
  );

  /// Illustration size in the stacked layout, or null to leave it out.
  static Size? stackedIllustrationSize(
    double width,
    double height, {
    required bool keyboardOpen,
  }) {
    if (keyboardOpen || height < stackedIllustrationMinHeight) return null;
    return illustrationSize(
      math.min(width - 2 * stackedGutter, stackedIllustrationMaxWidth),
      height * stackedIllustrationHeightFactor,
    );
  }
}

class _AuthScaffold extends StatelessWidget {
  const _AuthScaffold({
    required this.title,
    required this.subtitle,
    required this.children,
    this.branded = false,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;

  /// Uses the responsive split / stacked layout ([AuthLayout]). Off for the
  /// other screens that share this scaffold, which keep their layout.
  final bool branded;

  Widget _form(BuildContext context, SessionController session) {
    return ConstrainedBox(
      key: const Key('auth-form'),
      constraints: const BoxConstraints(maxWidth: AuthLayout.formMaxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
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
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ],
          if (session.notice != null) ...[
            const SizedBox(height: 16),
            Text(session.notice!),
          ],
        ],
      ),
    );
  }

  Widget _branded(BuildContext context, SessionController session) {
    // Read outside the Scaffold: inside its body the keyboard inset has
    // already been consumed (the body is resized instead).
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= AuthLayout.splitMinWidth) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: AuthLayout.brandPanelWidth(constraints.maxWidth),
                  child: const _BrandPanel(),
                ),
                Expanded(
                  child: SafeArea(
                    left: false,
                    child: LayoutBuilder(
                      builder: (context, panel) => SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AuthLayout.splitGutter,
                          vertical: 24,
                        ),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: (panel.maxHeight - 48).clamp(
                              0.0,
                              double.infinity,
                            ),
                          ),
                          child: Center(child: _form(context, session)),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }
          final illustration = AuthLayout.stackedIllustrationSize(
            constraints.maxWidth,
            constraints.maxHeight,
            keyboardOpen: keyboardOpen,
          );
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const _BrandHeader(),
                  if (illustration != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Center(
                        child: _BrandIllustration(size: illustration),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AuthLayout.stackedGutter,
                      24,
                      AuthLayout.stackedGutter,
                      24,
                    ),
                    child: Center(child: _form(context, session)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    if (branded) return _branded(context, session);
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

/// Same mark and name as the POS sidebar (no separate logo asset exists).
class _BrandMark extends StatelessWidget {
  const _BrandMark({required this.size});
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      child: Icon(Icons.storefront, color: Colors.white, size: size * 0.55),
    );
  }
}

BoxDecoration _brandGradient(BuildContext context) => BoxDecoration(
  gradient: LinearGradient(
    colors: PosTokens.of(context).heroGradient,
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  ),
);

/// The POS illustration (assets/images/img_left.png) at an exact,
/// aspect-correct [size] worked out by [AuthLayout]. Its dark background is
/// shown as a rounded card on the brand gradient; the file is used as is.
/// Decorative, so hidden from screen readers; if it cannot be loaded the
/// space stays empty and the gradient shows through.
class _BrandIllustration extends StatelessWidget {
  const _BrandIllustration({required this.size});
  final Size size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: const Key('auth-illustration'),
      width: size.width,
      height: size.height,
      child: Image.asset(
        AuthLayout.illustrationAsset,
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
          if (frame == null && !wasSynchronouslyLoaded) return child;
          return DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x40000000),
                  blurRadius: 24,
                  offset: Offset(0, 8),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: child,
            ),
          );
        },
        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
      ),
    );
  }
}

/// Left-hand panel of the wide (split) layout.
class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  static const double _padding = 40;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const Key('auth-brand-panel'),
      decoration: _brandGradient(context),
      child: SafeArea(
        right: false,
        // Centred when it fits; scrolls instead of overflowing in a very
        // short window (e.g. with an on-screen keyboard open). The
        // illustration is left out when the panel is too small for it.
        child: LayoutBuilder(
          builder: (context, panel) {
            final illustration = AuthLayout.panelIllustrationSize(
              panel.maxWidth - 2 * _padding,
              panel.maxHeight - 2 * _padding,
            );
            return Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(_padding),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const _BrandMark(size: 64),
                    const SizedBox(height: 24),
                    Text(
                      'ThriveWoo POS',
                      textAlign: TextAlign.center,
                      style: text.headlineMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (illustration != null) ...[
                      const SizedBox(height: 28),
                      _BrandIllustration(size: illustration),
                      const SizedBox(height: 28),
                    ] else
                      const SizedBox(height: 8),
                    Text(
                      'Point of sale',
                      textAlign: TextAlign.center,
                      style: text.titleMedium?.copyWith(
                        color: Colors.white.withValues(alpha: 0.85),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

/// Compact brand strip at the top of the narrow (stacked) layout.
class _BrandHeader extends StatelessWidget {
  const _BrandHeader();

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return DecoratedBox(
      key: const Key('auth-brand-header'),
      decoration: _brandGradient(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AuthLayout.stackedGutter,
          vertical: 20,
        ),
        child: Row(
          children: [
            const _BrandMark(size: 40),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ThriveWoo POS',
                    style: text.titleMedium?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    'Point of sale',
                    style: text.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
  String? _devMessage;
  DevCredentialsStore? _devStore;

  @override
  void initState() {
    super.initState();
    if (kDebugMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _devAutofill());
    }
  }

  /// Local-storage only, deliberately — no network call, so this can never
  /// interfere with a widget test's mock backend (kDebugMode is also true
  /// under `flutter test`).
  Future<void> _devAutofill() async {
    if (!mounted) return;
    final store = (_devStore ??= DevCredentialsStore(SecureTokenStore()));
    final saved = await store.load();
    if (!mounted) return;
    if (saved != null) {
      final isLegacy = saved.deviceIdentifier == 'E2E-TILL-1';
      final id = isLegacy
          ? DevCredentials.defaultDeviceIdentifier
          : saved.deviceIdentifier;
      final secret = isLegacy
          ? DevCredentials.defaultDeviceSecret
          : saved.deviceSecret;
      if (isLegacy) {
        await store.rememberDevice(id, secret);
      }
      setState(() {
        _id.text = id;
        _secret.text = secret;
        _devMessage = 'Autofilled from the saved test device.';
      });
      return;
    }
    if (DevCredentials.defaultDeviceIdentifier.isNotEmpty &&
        DevCredentials.defaultDeviceSecret.isNotEmpty) {
      setState(() {
        _id.text = DevCredentials.defaultDeviceIdentifier;
        _secret.text = DevCredentials.defaultDeviceSecret;
        _devMessage = 'Autofilled from default test device.';
      });
    }
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
      branded: true,
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
        if (kDebugMode && _devMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _devMessage!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
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
    final store = DevCredentialsStore(SecureTokenStore());
    final saved = await store.load();
    if (!mounted) return;
    if (saved != null) {
      final isLegacy = saved.staffId == 'E2E-SEN';
      final id = isLegacy ? DevCredentials.defaultStaffId : saved.staffId;
      final pin = isLegacy ? DevCredentials.defaultPin : saved.pin;
      if (isLegacy) {
        await store.rememberStaff(id, pin);
      }
      setState(() {
        _id.text = id;
        _pin.text = pin;
      });
      return;
    }
    if (DevCredentials.defaultStaffId.isNotEmpty &&
        DevCredentials.defaultPin.isNotEmpty) {
      setState(() {
        _id.text = DevCredentials.defaultStaffId;
        _pin.text = DevCredentials.defaultPin;
      });
    }
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
      branded: true,
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
