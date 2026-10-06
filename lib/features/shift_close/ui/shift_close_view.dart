import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../data/shift_close_service.dart';
import '../models/shift_summary.dart';
import '../state/shift_close_controller.dart';

/// Opens Shift Close (dialog on wide screens, sheet on phones). When the
/// shift is closed and the cashier taps Done, [onClosed] runs after the
/// screen is dismissed — the caller signs the staff member out, so the app
/// never carries on as if the shift were still open.
Future<void> showShiftClose(
  BuildContext context, {
  required bool cartHasItems,
  required void Function(ShiftSummary result) onClosed,
  ShiftCloseService? service, // tests only; production uses the API
  int unsyncedOfflineSales = 0,
}) async {
  final controller = ShiftCloseController(
    service ?? ApiShiftCloseService(context.read<PosApiClient>()),
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<ShiftCloseController>.value(
    value: controller,
    child: ShiftCloseView(
      cartHasItems: cartHasItems,
      unsyncedOfflineSales: unsyncedOfflineSales,
    ),
  );

  if (size.width >= 900) {
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 560,
            maxHeight: size.height * 0.92,
          ),
          child: content(),
        ),
      ),
    );
  } else {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      isDismissible: false,
      enableDrag: false,
      builder: (_) => SizedBox(height: size.height * 0.94, child: content()),
    );
  }
  final result = controller.result;
  controller.dispose();
  if (result != null) onClosed(result);
}

/// Payment method key -> label. Unknown methods show as sent by the server.
String paymentMethodLabel(String method) => switch (method) {
  'cash' => 'Cash',
  'card' => 'Card',
  'other' => 'Other',
  'wallet' => 'Loyalty wallet',
  _ => method,
};

class ShiftCloseView extends StatefulWidget {
  const ShiftCloseView({
    super.key,
    this.cartHasItems = false,
    this.unsyncedOfflineSales = 0,
  });

  final bool cartHasItems;

  /// Sales saved on this device while offline and not yet on the server.
  /// Closing the shift first means they can only be synced through a
  /// manager resolution afterwards, so the cashier is warned.
  final int unsyncedOfflineSales;

  @override
  State<ShiftCloseView> createState() => _ShiftCloseViewState();
}

class _ShiftCloseViewState extends State<ShiftCloseView> {
  final _counted = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<ShiftCloseController>().load();
    });
  }

  @override
  void dispose() {
    _counted.dispose();
    super.dispose();
  }

  Future<void> _confirmAndClose() async {
    final c = context.read<ShiftCloseController>();
    final s = c.summary;
    final counted = c.countedMilli;
    final variance = c.varianceMilli;
    if (!c.canSubmit || s == null || counted == null || variance == null) {
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close this shift?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Line('Expected cash', formatMoney(s.cash.expected)),
            _Line('Counted cash', formatMilli(counted)),
            _Line('Variance', _signedMilli(variance), emphasise: true),
            const SizedBox(height: PosTokens.s12),
            Text(
              'Shift #${s.shiftId} will be closed and you will be signed '
              'out. This cannot be undone.',
            ),
            if (widget.cartHasItems) ...[
              const SizedBox(height: PosTokens.s8),
              Text(
                'The sale in the cart has not been completed and will be '
                'left on this closed shift.',
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ],
            if (widget.unsyncedOfflineSales > 0) ...[
              const SizedBox(height: PosTokens.s8),
              Text(
                '${widget.unsyncedOfflineSales} offline '
                '${widget.unsyncedOfflineSales == 1 ? 'sale has' : 'sales have'} '
                'not synced yet. Sync them first (Sales history → Sync now); '
                'after the shift closes a manager will have to resolve them.',
                key: const Key('shift-close-unsynced-warning'),
                style: TextStyle(color: Theme.of(ctx).colorScheme.error),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const Key('shift-close-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Close shift'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) await c.close();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ShiftCloseController>();
    final theme = Theme.of(context);
    final closing = c.isClosing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text('Shift close', style: theme.textTheme.titleLarge),
              ),
              if (c.status != ShiftCloseStatus.closed)
                IconButton(
                  tooltip: 'Back',
                  onPressed: closing ? null : () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
        Expanded(child: _body(context, c)),
      ],
    );
  }

  Widget _body(BuildContext context, ShiftCloseController c) {
    switch (c.status) {
      case ShiftCloseStatus.loading:
        return const LoadingView(label: 'Loading shift summary');
      case ShiftCloseStatus.noOpenShift:
        return const EmptyView(
          title: 'No open shift',
          message: 'There is no open shift on this register to close.',
          icon: Icons.lock_clock,
        );
      case ShiftCloseStatus.error:
        return ErrorView(
          message: c.error?.message ?? 'Something went wrong.',
          onRetry: c.load,
        );
      case ShiftCloseStatus.closed:
        return _ClosedResult(result: c.result!);
      case ShiftCloseStatus.ready:
      case ShiftCloseStatus.closing:
        return _SummaryForm(
          controller: c,
          counted: _counted,
          onClose: _confirmAndClose,
        );
    }
  }
}

class _SummaryForm extends StatelessWidget {
  const _SummaryForm({
    required this.controller,
    required this.counted,
    required this.onClose,
  });

  final ShiftCloseController controller;
  final TextEditingController counted;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final s = c.summary!;
    final session = context.watch<SessionController>();
    final noPermission = session.isDenied('shifts.close');
    final variance = c.varianceMilli;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _ShiftHeader(summary: s),
        _Section(
          title: 'Sales',
          children: [
            _Line('Sales (${s.salesCount})', formatMoney(s.salesTotal)),
            _Line('Refunds (${s.refundsCount})', '−${formatMoney(s.refundsTotal)}'),
            if (s.voidsCount > 0)
              _Line('Voided (${s.voidsCount})', formatMoney(s.voidsTotal)),
          ],
        ),
        _Section(
          title: 'Payments',
          children: s.payments.isEmpty
              ? [const _Line('No payments yet', '—')]
              : [
                  for (final p in s.payments)
                    _Line(
                      '${paymentMethodLabel(p.method)} (${p.count})',
                      formatMoney(p.amount),
                    ),
                ],
        ),
        _Section(
          title: 'Cash',
          children: [
            _Line('Opening cash', formatMoney(s.cash.opening)),
            _Line('Cash sales', formatMoney(s.cash.cashSales)),
            _Line('Cash refunds', '−${formatMoney(s.cash.cashRefunds)}'),
            _Line('Cash in', formatMoney(s.cash.deposits)),
            _Line('Cash out', '−${formatMoney(s.cash.withdrawals)}'),
            const Divider(),
            _Line(
              'Expected cash',
              formatMoney(s.cash.expected),
              emphasise: true,
              valueKey: const Key('shift-expected-cash'),
            ),
          ],
        ),
        _Section(
          title: 'Counted cash',
          children: [
            TextField(
              key: const Key('shift-counted-cash'),
              controller: counted,
              enabled: !c.isClosing,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: InputDecoration(
                labelText: 'Cash counted in the drawer',
                errorText: c.countedText.isNotEmpty && !c.countedIsValid
                    ? 'Enter an amount with up to 3 decimals.'
                    : null,
              ),
              onChanged: c.setCounted,
            ),
            const SizedBox(height: PosTokens.s8),
            _Line(
              'Variance',
              variance == null ? '—' : _signedMilli(variance),
              emphasise: true,
              valueKey: const Key('shift-variance'),
            ),
          ],
        ),
        if (c.closeError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: PosTokens.s12),
            child: Text(
              c.closeError!.message,
              key: const Key('shift-close-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!s.closableByCurrentStaff)
          const Padding(
            padding: EdgeInsets.only(bottom: PosTokens.s12),
            child: Text(
              'Only the cashier who opened this shift can close it.',
              key: Key('shift-not-closable'),
            ),
          )
        else if (noPermission)
          const Padding(
            padding: EdgeInsets.only(bottom: PosTokens.s12),
            child: Text(
              'You do not have permission to close the shift. Ask a manager.',
            ),
          ),
        FilledButton.icon(
          key: const Key('shift-close-submit'),
          onPressed: c.canSubmit && !noPermission ? onClose : null,
          icon: c.isClosing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_clock),
          label: Text(c.isClosing ? 'Closing…' : 'Close shift'),
        ),
      ],
    );
  }
}

class _ShiftHeader extends StatelessWidget {
  const _ShiftHeader({required this.summary});
  final ShiftSummary summary;

  @override
  Widget build(BuildContext context) {
    final s = summary;
    return _Section(
      title: 'Shift #${s.shiftId}',
      children: [
        _Line('Register', s.registerLabel),
        if (s.openedBy != null) _Line('Opened by', s.openedBy!),
        if (s.openedAt != null) _Line('Opened', formatTimestamp(s.openedAt!)),
      ],
    );
  }
}

class _ClosedResult extends StatelessWidget {
  const _ClosedResult({required this.result});
  final ShiftSummary result;

  @override
  Widget build(BuildContext context) {
    final r = result;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: theme.colorScheme.primary),
            const SizedBox(width: PosTokens.s8),
            Expanded(
              child: Text(
                'Shift #${r.shiftId} closed',
                key: const Key('shift-closed-title'),
                style: theme.textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: PosTokens.s12),
        _Section(
          title: 'Final figures',
          children: [
            if (r.closedAt != null) _Line('Closed', formatTimestamp(r.closedAt!)),
            _Line('Sales (${r.salesCount})', formatMoney(r.salesTotal)),
            _Line('Expected cash', formatMoney(r.cash.expected)),
            _Line('Counted cash', formatMoney(r.cash.counted)),
            _Line(
              'Variance',
              r.cash.variance == null
                  ? '—'
                  : _signedMilli(milliFromDouble(r.cash.variance!)),
              emphasise: true,
              valueKey: const Key('shift-final-variance'),
            ),
          ],
        ),
        const Text('You will be signed out so the next shift can be opened.'),
        const SizedBox(height: PosTokens.s16),
        FilledButton(
          key: const Key('shift-closed-done'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          ...children,
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.emphasise = false, this.valueKey});
  final String label;
  final String value;
  final bool emphasise;
  final Key? valueKey;

  @override
  Widget build(BuildContext context) {
    final style = emphasise
        ? Theme.of(context).textTheme.titleSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, key: valueKey, style: style),
        ],
      ),
    );
  }
}

/// `+5.00` / `−7.50` / `0.00` for a milli amount.
String _signedMilli(int milli) {
  if (milli == 0) return formatMilli(0);
  return milli > 0 ? '+${formatMilli(milli)}' : '−${formatMilli(-milli)}';
}
