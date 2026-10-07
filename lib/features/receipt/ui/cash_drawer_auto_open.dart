import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/cash_drawer_service.dart';
import '../state/receipt_services.dart';

/// Phase 14A — opens the cash drawer ONCE after a COMPLETED sale that took
/// cash. Placed only on the "sale complete" screens, so it can never run
/// before the payment is confirmed, for a failed or cancelled payment, or
/// just because the pay screen is open. The drawer service remembers the
/// sale, so rebuilds and completion retries never pulse twice.
///
/// The sale is already complete whatever happens here: a drawer failure is
/// shown as a warning, never as a failed sale.
class CashDrawerAutoOpen extends StatefulWidget {
  const CashDrawerAutoOpen({
    super.key,
    required this.saleKey,
    required this.tookCash,
  });

  /// `sale:<server id>` or `local:<offline id>`.
  final String saleKey;

  /// The completed sale includes a cash tender.
  final bool tookCash;

  @override
  State<CashDrawerAutoOpen> createState() => _CashDrawerAutoOpenState();
}

class _CashDrawerAutoOpenState extends State<CashDrawerAutoOpen> {
  DrawerOpenResult? _result;

  @override
  void initState() {
    super.initState();
    if (!widget.tookCash) return;
    final drawer = _drawer(context);
    if (drawer == null) return;
    drawer.openForCashSale(widget.saleKey).then((r) {
      if (mounted) setState(() => _result = r);
    });
  }

  static CashDrawerService? _drawer(BuildContext context) {
    try {
      return context.read<ReceiptServices>().drawer;
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    if (r == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return switch (r.status) {
      DrawerOpenStatus.opened => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'Cash drawer opened.',
          key: const Key('cash-drawer-opened'),
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
      DrawerOpenStatus.failed => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          'The sale is complete. ${r.message ?? CashDrawerService.failedMessage}',
          key: const Key('cash-drawer-failed'),
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      ),
      // No drawer set up / already opened for this sale: nothing to say.
      _ => const SizedBox.shrink(),
    };
  }
}
