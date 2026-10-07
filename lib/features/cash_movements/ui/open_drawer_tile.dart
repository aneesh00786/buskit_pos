import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/pos_api_client.dart';
import '../../auth/state/session_controller.dart';
import '../../receipt/state/receipt_services.dart';
import '../data/no_sale_service.dart';
import '../state/no_sale_action.dart';

/// Phase 14A — "Open cash drawer (no sale)". Shown unless the signed-in
/// staff member is known NOT to hold `payments.cash_drawer` (the server
/// enforces it either way). Confirms first; disabled while running.
class OpenDrawerTile extends StatefulWidget {
  const OpenDrawerTile({super.key, this.action});

  /// Injected in tests; built from the app's services otherwise.
  final NoSaleAction? action;

  @override
  State<OpenDrawerTile> createState() => _OpenDrawerTileState();
}

class _OpenDrawerTileState extends State<OpenDrawerTile> {
  bool _busy = false;

  NoSaleAction? _action() {
    if (widget.action != null) return widget.action;
    final drawer = context.read<ReceiptServices>().drawer;
    if (drawer == null) return null;
    return NoSaleAction(
      service: ApiNoSaleService(context.read<PosApiClient>()),
      drawer: drawer,
    );
  }

  Future<void> _run() async {
    if (_busy) return;
    final action = _action();
    if (action == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Open the cash drawer?'),
        content: const Text(
          'This opens the drawer without a sale and is recorded with your name, '
          'this device and the time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('no-sale-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Open drawer'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    final r = await action.run();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(r.message, key: const Key('no-sale-result'))),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (context.watch<SessionController>().isDenied('payments.cash_drawer')) {
      return const SizedBox.shrink();
    }
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        key: const Key('open-drawer-no-sale'),
        enabled: !_busy,
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.point_of_sale_outlined),
        title: const Text('Open cash drawer (no sale)'),
        subtitle: const Text(
          'Opens the drawer without a sale. It is recorded.',
        ),
        trailing: _busy
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.chevron_right),
        onTap: _busy ? null : _run,
      ),
    );
  }
}
