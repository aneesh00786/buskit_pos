import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../cash_movements/data/cash_movement_service.dart';
import '../../cash_movements/state/cash_movement_controller.dart';
import '../../cash_movements/ui/cash_withdrawal_view.dart';
import '../../receipt/models/receipt.dart';
import '../../receipt/ui/receipt_actions.dart' show PrinterSetupDialog;
import '../data/settings_service.dart';
import '../models/pos_device.dart';
import '../models/pos_store.dart';
import '../state/settings_controller.dart';

/// Store info, registers and devices for this company (all already-existing
/// backend endpoints — see the plan), plus the existing printer/receipt
/// setup and app version. No staff/PIN management and no tax settings —
/// neither has a backend endpoint yet.
Future<void> showSettings(BuildContext context) {
  final client = context.read<PosApiClient>();
  final controller = SettingsController(ApiSettingsService(client));
  final cashController = CashMovementController(ApiCashMovementService(client));
  final size = MediaQuery.sizeOf(context);
  Widget content() => MultiProvider(
    providers: [
      ChangeNotifierProvider<SettingsController>.value(value: controller),
      ChangeNotifierProvider<CashMovementController>.value(value: cashController),
    ],
    child: const SettingsView(),
  );
  void disposeAll() {
    controller.dispose();
    cashController.dispose();
  }

  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 700,
            maxHeight: size.height * 0.9,
          ),
          child: content(),
        ),
      ),
    ).whenComplete(disposeAll);
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => SizedBox(height: size.height * 0.92, child: content()),
  ).whenComplete(disposeAll);
}

const _samplePrintReceipt = ReceiptData(
  title: 'ThriveWoo POS',
  orderNumber: 'TEST-PRINT',
  customerLabel: 'Test print',
  lines: [],
  subtotal: '0.00',
  tax: '0.00',
  total: '0.00',
  payments: [],
);

class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<SettingsController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<SettingsController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(
                    'Settings',
                    style: Theme.of(context).textTheme.headlineSmall
                        ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 4,
          child: c.status == SettingsStatus.loading
              ? const LinearProgressIndicator()
              : null,
        ),
        Expanded(child: _Body(controller: c)),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case SettingsStatus.idle:
      case SettingsStatus.loading:
        return const LoadingView(label: 'Loading settings');
      case SettingsStatus.error:
        final e = controller.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: (e.isRetryable || e.kind == ApiErrorKind.unknown)
              ? controller.retry
              : null,
        );
      case SettingsStatus.loaded:
        if (controller.stores.isEmpty) {
          return const EmptyView(
            title: 'No store found',
            message: 'This company has no store set up yet.',
            icon: Icons.storefront_outlined,
          );
        }
        return ListView(
          padding: const EdgeInsets.all(PosTokens.s16),
          children: [
            if (controller.stores.length > 1)
              _StoreSwitcher(controller: controller),
            _StoreSection(controller: controller),
            const SizedBox(height: PosTokens.s16),
            _RegistersSection(controller: controller),
            const SizedBox(height: PosTokens.s16),
            _DevicesSection(controller: controller),
            const SizedBox(height: PosTokens.s16),
            const CashManagementGate(),
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: 'Printer & Receipt',
              icon: Icons.print_outlined,
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.settings_ethernet),
                  title: const Text('Printer setup'),
                  subtitle: const Text(
                    'Configure the receipt printer address and paper width.',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        const PrinterSetupDialog(receipt: _samplePrintReceipt),
                  ),
                ),
              ),
            ),
            const SizedBox(height: PosTokens.s16),
            _SectionCard(
              title: 'About',
              icon: Icons.info_outline,
              child: _KeyValue('App version', AppConfig.appVersion),
            ),
          ],
        );
    }
  }
}

class _StoreSwitcher extends StatelessWidget {
  const _StoreSwitcher({required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s12),
      child: DropdownButtonFormField<int>(
        initialValue: controller.selectedStore?.id,
        decoration: const InputDecoration(labelText: 'Store'),
        items: [
          for (final s in controller.stores)
            DropdownMenuItem(value: s.id, child: Text(s.storeName)),
        ],
        onChanged: (id) {
          final store = controller.stores.firstWhere((s) => s.id == id);
          controller.selectStore(store);
        },
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.child,
  });
  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: t.card(outlined: false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.outline),
              const SizedBox(width: PosTokens.s8),
              Text(title, style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: PosTokens.s8),
          child,
        ],
      ),
    );
  }
}

class _StoreSection extends StatelessWidget {
  const _StoreSection({required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    final store = controller.selectedStore;
    if (store == null) return const SizedBox.shrink();
    return _SectionCard(
      title: 'Store',
      icon: Icons.storefront_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _KeyValue('Name', store.storeName),
          _KeyValue('Code', store.storeCode),
          _KeyValue(
            'Address',
            [store.address, store.town, store.state, store.zip, store.country]
                .where((s) => s != null && s.isNotEmpty)
                .join(', ')
                .let((s) => s.isEmpty ? '—' : s),
          ),
          _KeyValue('Timezone', store.timezone),
          _KeyValue('Currency', store.currency),
          const SizedBox(height: PosTokens.s8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showEditStoreDialog(context, controller, store),
              icon: const Icon(Icons.edit_outlined),
              label: const Text('Edit Store'),
            ),
          ),
        ],
      ),
    );
  }
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}

Future<void> _showEditStoreDialog(
  BuildContext context,
  SettingsController controller,
  PosStore store,
) {
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<SettingsController>.value(
      value: controller,
      child: _EditStoreDialog(store: store),
    ),
  );
}

class _EditStoreDialog extends StatefulWidget {
  const _EditStoreDialog({required this.store});
  final PosStore store;

  @override
  State<_EditStoreDialog> createState() => _EditStoreDialogState();
}

class _EditStoreDialogState extends State<_EditStoreDialog> {
  late final _name = TextEditingController(text: widget.store.storeName);
  late final _address = TextEditingController(text: widget.store.address);
  late final _town = TextEditingController(text: widget.store.town);
  late final _state = TextEditingController(text: widget.store.state);
  late final _zip = TextEditingController(text: widget.store.zip);
  late final _country = TextEditingController(text: widget.store.country);

  @override
  void dispose() {
    _name.dispose();
    _address.dispose();
    _town.dispose();
    _state.dispose();
    _zip.dispose();
    _country.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final controller = context.read<SettingsController>();
    final ok = await controller.updateStore({
      'store_name': name,
      'address': _address.text.trim(),
      'town': _town.text.trim(),
      'state': _state.text.trim(),
      'zip': _zip.text.trim(),
      'country': _country.text.trim(),
    });
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<SettingsController>();
    final e = controller.mutationError;
    return AlertDialog(
      title: const Text('Edit store'),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Store name *'),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address'),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _town,
              decoration: const InputDecoration(labelText: 'Town'),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _state,
              decoration: const InputDecoration(labelText: 'State'),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _zip,
              decoration: const InputDecoration(labelText: 'Zip'),
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _country,
              decoration: const InputDecoration(labelText: 'Country'),
            ),
            if (e != null) ...[
              const SizedBox(height: PosTokens.s12),
              Text(
                describeApiError(e),
                style: TextStyle(color: PosTokens.of(context).danger),
              ),
            ],
          ],
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
          onPressed: controller.isMutating ? null : _save,
          child: controller.isMutating
              ? const SizedBox(
                  height: 18,
                  width: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
    );
  }
}

class _RegistersSection extends StatelessWidget {
  const _RegistersSection({required this.controller});
  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Registers',
      icon: Icons.point_of_sale_outlined,
      child: controller.registers.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No registers set up yet.'),
            )
          : Column(
              children: [
                for (final r in controller.registers)
                  _StatusRow(
                    title: r.registerName,
                    subtitle: r.registerCode,
                    active: r.isActive,
                    onToggle: () => controller.setRegisterStatus(
                      r.id,
                      r.isActive ? 'inactive' : 'active',
                    ),
                  ),
              ],
            ),
    );
  }
}

class _DevicesSection extends StatelessWidget {
  const _DevicesSection({required this.controller});
  final SettingsController controller;

  Future<void> _confirmRevoke(BuildContext context, PosDevice d) async {
    final controller = context.read<SettingsController>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Revoke this device?'),
        content: Text(
          '"${d.deviceName ?? d.deviceIdentifier}" will no longer be able to sign in. '
          'This cannot be undone from here — a new device secret would be needed to reconnect it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await controller.setDeviceStatus(d.id, 'revoked');
    }
  }

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Devices',
      icon: Icons.tablet_mac_outlined,
      child: controller.devices.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('No devices registered yet.'),
            )
          : Column(
              children: [
                for (final d in controller.devices)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(d.deviceName ?? d.deviceIdentifier),
                    subtitle: Text('${d.deviceIdentifier} · ${d.status}'),
                    trailing: d.isRevoked
                        ? null
                        : TextButton(
                            onPressed: () => _confirmRevoke(context, d),
                            child: const Text('Revoke'),
                          ),
                  ),
              ],
            ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({
    required this.title,
    required this.subtitle,
    required this.active,
    required this.onToggle,
  });
  final String title;
  final String subtitle;
  final bool active;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Switch(value: active, onChanged: (_) => onToggle()),
    );
  }
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }
}
