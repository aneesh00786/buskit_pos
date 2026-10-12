import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/server_time.dart';
import '../../auth/state/session_controller.dart';
import '../models/cash_movement.dart';
import '../state/cash_movement_controller.dart';

/// "Cash Management" — current shift info, its cash movements (deposits and
/// withdrawals, newest-first) and the Cash Withdrawal / Cash Deposit actions. Lives inside Settings (the only existing
/// real, non-placeholder screen reachable from the sidebar) rather than a
/// new top-level section — see the Phase 17.3 review for why no dedicated
/// shift screen exists to extend instead.
class CashManagementSection extends StatefulWidget {
  const CashManagementSection({super.key});

  @override
  State<CashManagementSection> createState() => _CashManagementSectionState();
}

class _CashManagementSectionState extends State<CashManagementSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<CashMovementController>().load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final c = context.watch<CashMovementController>();

    return Container(
      padding: const EdgeInsets.all(PosTokens.s16),
      decoration: t.card(outlined: false),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.payments_outlined,
                size: 18,
                color: theme.colorScheme.outline,
              ),
              const SizedBox(width: PosTokens.s8),
              Text('Cash Management', style: theme.textTheme.titleSmall),
            ],
          ),
          const SizedBox(height: PosTokens.s8),
          _Body(
            controller: c,
            // Each action hides only when the loaded context positively lacks
            // its own permission (SessionController.isDenied semantics).
            canWithdraw: !context.watch<SessionController>().isDenied(
              'payments.cash_withdrawal',
            ),
            canDeposit: !context.watch<SessionController>().isDenied(
              'payments.cash_deposit',
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.controller,
    required this.canWithdraw,
    required this.canDeposit,
  });
  final CashMovementController controller;
  final bool canWithdraw;
  final bool canDeposit;

  @override
  Widget build(BuildContext context) {
    switch (controller.status) {
      case CashMovementListStatus.idle:
      case CashMovementListStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: PosTokens.s16),
          child: LoadingView(label: 'Loading shift info'),
        );
      case CashMovementListStatus.error:
        final e = controller.error!;
        return ErrorView(
          message: describeApiError(e),
          onRetry: e.isRetryable ? controller.retry : null,
        );
      case CashMovementListStatus.loaded:
        final shift = controller.shift;
        if (shift == null) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text('No open shift on this register.'),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ShiftInfo(shift: shift),
            const SizedBox(height: PosTokens.s12),
            Wrap(
              spacing: PosTokens.s8,
              runSpacing: PosTokens.s8,
              children: [
                if (canWithdraw)
                  FilledButton.icon(
                    onPressed: controller.isBusy
                        ? null
                        : () => _startWithdrawal(context, controller),
                    icon: controller.isWithdrawing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.remove_circle_outline),
                    label: Text(
                      controller.isWithdrawing
                          ? 'Processing withdrawal…'
                          : 'Cash Withdrawal',
                    ),
                  ),
                if (canDeposit)
                  FilledButton.tonalIcon(
                    onPressed: controller.isBusy
                        ? null
                        : () => _startDeposit(context, controller),
                    icon: controller.isDepositing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.add_circle_outline),
                    label: Text(
                      controller.isDepositing
                          ? 'Processing deposit…'
                          : 'Cash Deposit',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: PosTokens.s12),
            if (controller.movements.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('No cash movements on this shift yet.'),
              )
            else
              Column(
                children: [
                  for (final m in controller.movements) _MovementRow(m: m),
                ],
              ),
          ],
        );
    }
  }

  Future<void> _startWithdrawal(
    BuildContext context,
    CashMovementController c,
  ) async {
    final request = await showCashWithdrawalDialog(context);
    if (request == null || !context.mounted) return;

    final confirmed = await confirmCashWithdrawal(
      context,
      amount: request.amount,
      reason: request.reason,
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await c.withdraw(amount: request.amount, reason: request.reason);
    if (!context.mounted) return;

    if (ok) {
      final movement = c.lastWithdrawal;
      if (movement != null) {
        await showCashWithdrawalResult(context, movement: movement);
      }
      c.clearLastWithdrawal();
      return;
    }

    final err = c.withdrawError;
    final message = err != null
        ? describeApiError(err)
        : 'The withdrawal could not be completed.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    c.clearWithdrawError();
  }

  Future<void> _startDeposit(
    BuildContext context,
    CashMovementController c,
  ) async {
    final request = await showCashDepositDialog(context);
    if (request == null || !context.mounted) return;

    final confirmed = await confirmCashDeposit(
      context,
      amount: request.amount,
      reason: request.reason,
    );
    if (confirmed != true || !context.mounted) return;

    final ok = await c.deposit(amount: request.amount, reason: request.reason);
    if (!context.mounted) return;

    if (ok) {
      final movement = c.lastDeposit;
      if (movement != null) {
        await showCashDepositResult(context, movement: movement);
      }
      c.clearLastDeposit();
      return;
    }

    final err = c.depositError;
    final message = err != null
        ? describeApiError(err)
        : 'The deposit could not be completed.';
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
    c.clearDepositError();
  }
}

class _ShiftInfo extends StatelessWidget {
  const _ShiftInfo({required this.shift});
  final CurrentShiftSummary shift;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shift #${shift.id} · ${shift.status}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        Text(
          'Opening amount ${formatMoney(shift.openingAmount)}'
          '${shift.openedAt != null ? ' · opened ${formatTimestamp(shift.openedAt!)}' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _MovementRow extends StatelessWidget {
  const _MovementRow({required this.m});
  final CashMovement m;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Deposits add to the drawer (+), withdrawals remove from it (−).
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        m.isDeposit ? Icons.add_circle_outline : Icons.remove_circle_outline,
        color: m.isDeposit
            ? theme.colorScheme.primary
            : theme.colorScheme.error,
      ),
      title: Text('${m.isDeposit ? '+' : '−'} ${formatMoney(m.amount)}'),
      subtitle: Text(
        [
          m.isDeposit ? 'Deposit' : 'Withdrawal',
          if (m.reason != null && m.reason!.isNotEmpty) m.reason!,
          if (m.createdAt != null) formatTimestamp(m.createdAt!),
        ].join(' · '),
      ),
    );
  }
}

class CashWithdrawalRequest {
  const CashWithdrawalRequest({required this.amount, this.reason});
  final String amount;
  final String? reason;
}

/// Amount + reason entry — client-side parsing only mirrors the backend's
/// own precision rule (see core/utils/money.dart's parseMilli), it never
/// substitutes for server-side validation.
Future<CashWithdrawalRequest?> showCashWithdrawalDialog(BuildContext context) {
  return showDialog<CashWithdrawalRequest>(
    context: context,
    builder: (ctx) => const _CashWithdrawalForm(title: 'Cash Withdrawal'),
  );
}

/// Cash In entry — the same amount + optional reason form and the same
/// client-side precision rule as the withdrawal form.
Future<CashWithdrawalRequest?> showCashDepositDialog(BuildContext context) {
  return showDialog<CashWithdrawalRequest>(
    context: context,
    builder: (ctx) => const _CashWithdrawalForm(title: 'Cash Deposit'),
  );
}

class _CashWithdrawalForm extends StatefulWidget {
  const _CashWithdrawalForm({required this.title});
  final String title;

  @override
  State<_CashWithdrawalForm> createState() => _CashWithdrawalFormState();
}

class _CashWithdrawalFormState extends State<_CashWithdrawalForm> {
  final _amount = TextEditingController();
  final _reason = TextEditingController();
  String? _amountError;

  @override
  void dispose() {
    _amount.dispose();
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    final raw = _amount.text.trim();
    final milli = parseMilli(raw);
    if (milli == null || milli <= 0) {
      setState(() => _amountError = 'Enter an amount greater than 0');
      return;
    }
    Navigator.of(context).pop(
      CashWithdrawalRequest(
        amount: raw,
        reason: _reason.text.trim().isEmpty ? null : _reason.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      scrollable: true,
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _amount,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: 'Amount *',
                errorText: _amountError,
              ),
              onChanged: (_) {
                if (_amountError != null) setState(() => _amountError = null);
              },
            ),
            const SizedBox(height: PosTokens.s12),
            TextField(
              controller: _reason,
              maxLength: 255,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Continue')),
      ],
    );
  }
}

/// "Withdraw `amount` from this register?" — the final confirmation before
/// submitting, same destructive-confirmation shape as [confirmVoid]/
/// confirmRefund (cart_panel.dart / sales_history_view.dart).
Future<bool?> confirmCashWithdrawal(
  BuildContext context, {
  required String amount,
  String? reason,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm cash withdrawal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Amount', formatMoney(double.tryParse(amount))),
          _KeyValue(
            'Reason',
            (reason == null || reason.isEmpty) ? '—' : reason,
          ),
          const SizedBox(height: PosTokens.s12),
          Text(
            'This withdraws cash from this register\'s current shift. '
            'This cannot be undone.',
            style: Theme.of(ctx).textTheme.bodySmall
                ?.copyWith(color: Theme.of(ctx).colorScheme.error),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(ctx).colorScheme.error,
            foregroundColor: Theme.of(ctx).colorScheme.onError,
          ),
          child: const Text('Withdraw'),
        ),
      ],
    ),
  );
}

/// Shown once, right after a successful withdrawal.
Future<void> showCashWithdrawalResult(
  BuildContext context, {
  required CashMovement movement,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        Icons.check_circle_outline,
        color: Theme.of(ctx).colorScheme.primary,
        size: 32,
      ),
      title: const Text('Withdrawal successful'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Amount', formatMoney(movement.amount)),
          _KeyValue(
            'Reason',
            (movement.reason == null || movement.reason!.isEmpty)
                ? '—'
                : movement.reason!,
          ),
          _KeyValue('Reference', '#${movement.id}'),
          if (movement.createdAt != null)
            _KeyValue('Date/time', formatTimestamp(movement.createdAt!)),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

/// "Deposit `amount` into this register?" — the final confirmation before
/// submitting. Not styled as destructive (it adds cash), but still states
/// that the record is permanent.
Future<bool?> confirmCashDeposit(
  BuildContext context, {
  required String amount,
  String? reason,
}) {
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Confirm cash deposit'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Amount', formatMoney(double.tryParse(amount))),
          _KeyValue(
            'Reason',
            (reason == null || reason.isEmpty) ? '—' : reason,
          ),
          const SizedBox(height: PosTokens.s12),
          Text(
            'This adds cash to this register\'s current shift. '
            'This cannot be undone.',
            style: Theme.of(ctx).textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: const Text('Deposit'),
        ),
      ],
    ),
  );
}

/// Shown once, right after a successful deposit.
Future<void> showCashDepositResult(
  BuildContext context, {
  required CashMovement movement,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(
        Icons.check_circle_outline,
        color: Theme.of(ctx).colorScheme.primary,
        size: 32,
      ),
      title: const Text('Deposit successful'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _KeyValue('Amount', formatMoney(movement.amount)),
          _KeyValue(
            'Reason',
            (movement.reason == null || movement.reason!.isEmpty)
                ? '—'
                : movement.reason!,
          ),
          _KeyValue('Reference', '#${movement.id}'),
          if (movement.createdAt != null)
            _KeyValue('Date/time', formatTimestamp(movement.createdAt!)),
        ],
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Done'),
        ),
      ],
    ),
  );
}

class _KeyValue extends StatelessWidget {
  const _KeyValue(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: PosTokens.s8),
          Text(value, style: style),
        ],
      ),
    );
  }
}

/// Permission-gated wrapper — hidden entirely only when the loaded context
/// positively lacks BOTH payments.cash_withdrawal and payments.cash_deposit
/// (the backend's history endpoint accepts either; Phase 17.7). With one of
/// them, the section shows and only the other action's button is hidden. A
/// missing/failed context leaves everything visible, deferring to the
/// backend's own 403 — same semantics as Refund/Cancel
/// (SessionController.isDenied).
class CashManagementGate extends StatelessWidget {
  const CashManagementGate({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();
    if (session.isDenied('payments.cash_withdrawal') &&
        session.isDenied('payments.cash_deposit')) {
      return const SizedBox.shrink();
    }
    return const CashManagementSection();
  }
}
