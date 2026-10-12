import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/money.dart';
import '../data/payment_terminal_service.dart';
import '../models/terminal_payment.dart';
import '../state/terminal_payment_controller.dart';

/// Runs one card-terminal payment. Resolves to the CAPTURED attempt when the
/// cashier continues after approval, or null when it ends any other way.
Future<PaymentAttempt?> showTerminalPayment(
  BuildContext context, {
  required PaymentTerminalService service,
  required int saleId,
  required PaymentProviderInfo provider,
  required int amountMilli,
}) {
  return showDialog<PaymentAttempt>(
    context: context,
    barrierDismissible: false,
    builder: (_) => TerminalPaymentDialog(
      // Phase 18B.3: wait as long as the terminal keeps the payment open.
      controller: TerminalPaymentController(
        service,
        saleId: saleId,
        provider: provider.name,
        amountMilli: amountMilli,
        maxWait: provider.terminalWaitWindow,
      ),
      provider: provider,
    ),
  );
}

class TerminalPaymentDialog extends StatefulWidget {
  const TerminalPaymentDialog({
    super.key,
    required this.controller,
    required this.provider,
  });

  /// Owned by the dialog (disposed with it).
  final TerminalPaymentController controller;
  final PaymentProviderInfo provider;

  @override
  State<TerminalPaymentDialog> createState() => _TerminalPaymentDialogState();
}

class _TerminalPaymentDialogState extends State<TerminalPaymentDialog> {
  @override
  void initState() {
    super.initState();
    widget.controller.start();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        // Phase 18B.1: abandoned by a manager is NOT a confirmed cancellation.
        // Phase 18B.15: a recorded-but-unattached reference has its own state.
        final recorded = c.isReferenceRecordedUnattached;
        final view = c.isAbandoned
            ? _PhaseView.abandoned
            : recorded
            ? _PhaseView.referenceRecorded
            : c.isOverdue && c.phase == TerminalPhase.unknown
            ? _PhaseView.overdue
            : _PhaseView.of(c.phase);
        final scheme = Theme.of(context).colorScheme;
        final minutes =
            widget.provider.autoCancelMinutes ??
            PaymentProviderInfo.defaultAutoCancelMinutes;
        final waitingDetail = c.phase == TerminalPhase.waitingForCard
            ? '${c.attempt?.instruction ?? view.detail} The terminal cancels it automatically after $minutes minutes if it is not completed.'
            : null;
        final detail = recorded
            ? TerminalPaymentController.referenceRecordedMessage
            : (c.message ?? waitingDetail ?? view.detail);
        return AlertDialog(
          key: Key('terminal-phase-${c.phase.name}'),
          title: Text('${widget.provider.label} card payment'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (view.busy)
                const SizedBox(
                  width: 48,
                  height: 48,
                  child: CircularProgressIndicator(),
                )
              else
                Icon(
                  view.icon,
                  size: 48,
                  color: view.error
                      ? scheme.error
                      : (c.phase == TerminalPhase.approved
                            ? PosTokens.of(context).success
                            : null),
                ),
              const SizedBox(height: PosTokens.s12),
              Semantics(
                liveRegion: true,
                child: Text(
                  view.title,
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
              ),
              const SizedBox(height: PosTokens.s8),
              Text(
                formatMilli(c.amountMilli),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              if (widget.provider.terminalName != null)
                Text(
                  widget.provider.terminalName!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (detail != null) ...[
                const SizedBox(height: PosTokens.s8),
                Text(detail, textAlign: TextAlign.center),
              ],
            ],
          ),
          actions: [
            if (c.canCheckAgain)
              TextButton(
                onPressed: c.checkAgain,
                child: const Text('Check again'),
              ),
            if (c.canCancel && widget.provider.cancel)
              TextButton(
                onPressed: c.cancel,
                child: const Text('Cancel payment'),
              ),
            if (c.canAbandon)
              TextButton(
                key: const Key('terminal-abandon'),
                onPressed: () => _confirmAbandon(context, c),
                child: const Text('Abandon payment…'),
              ),
            if (c.phase == TerminalPhase.approved)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(c.attempt),
                child: const Text('Complete sale'),
              )
            else if (c.isFinal || c.phase == TerminalPhase.unknown)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
          ],
        );
      },
    );
  }
}

/// Phase 18B.1 — asks a manager for the reason, after showing what
/// abandoning means. Nothing is sent unless they confirm.
Future<void> _confirmAbandon(
  BuildContext context,
  TerminalPaymentController c,
) async {
  final reason = await showDialog<String>(
    context: context,
    builder: (_) => const _AbandonReasonDialog(),
  );
  if (reason != null) await c.abandon(reason);
}

class _AbandonReasonDialog extends StatefulWidget {
  const _AbandonReasonDialog();

  @override
  State<_AbandonReasonDialog> createState() => _AbandonReasonDialogState();
}

class _AbandonReasonDialogState extends State<_AbandonReasonDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ok = _reason.text.trim().length >= 5;
    return AlertDialog(
      key: const Key('abandon-dialog'),
      title: const Text('Abandon unconfirmed payment?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'The terminal never confirmed this payment. Abandoning it lets you take another payment for this sale, '
            'but it does NOT prove that no money was taken.',
          ),
          const SizedBox(height: PosTokens.s8),
          const Text(
            'Check the terminal and the Pine Labs settlement afterwards, and refund the customer if a charge appears. '
            'Manager permission is required.',
          ),
          const SizedBox(height: PosTokens.s12),
          TextField(
            key: const Key('abandon-reason'),
            controller: _reason,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: 'Reason',
              helperText: 'At least 5 characters',
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Keep waiting'),
        ),
        FilledButton(
          key: const Key('abandon-confirm'),
          onPressed: ok
              ? () => Navigator.of(context).pop(_reason.text.trim())
              : null,
          child: const Text('Abandon payment'),
        ),
      ],
    );
  }
}

class _PhaseView {
  const _PhaseView(
    this.title, {
    this.icon = Icons.credit_card,
    this.busy = false,
    this.error = false,
    this.detail,
  });
  final String title;
  final IconData icon;
  final bool busy;
  final bool error;
  final String? detail;

  static const abandoned = _PhaseView(
    'Payment abandoned',
    icon: Icons.report_problem_outlined,
    error: true,
  );

  /// Phase 18B.15: the provider reference is recorded but not attached yet.
  static const referenceRecorded = _PhaseView(
    'Terminal reference recorded',
    icon: Icons.link,
    error: true,
  );

  /// Phase 18B.3: past the terminal's auto-cancel window, still unconfirmed.
  static const overdue = _PhaseView(
    'Waiting longer than expected',
    icon: Icons.hourglass_bottom,
    error: true,
  );

  static _PhaseView of(TerminalPhase p) => switch (p) {
    TerminalPhase.connecting => const _PhaseView(
      'Connecting to terminal…',
      busy: true,
    ),
    TerminalPhase.waitingForCard => const _PhaseView(
      'Waiting for card',
      icon: Icons.contactless,
      detail: 'Ask the customer to tap, insert or swipe their card on the terminal.',
    ),
    TerminalPhase.processing => const _PhaseView('Processing…', busy: true),
    TerminalPhase.cancelling => const _PhaseView('Cancelling…', busy: true),
    TerminalPhase.approved => const _PhaseView(
      'Approved',
      icon: Icons.check_circle,
    ),
    TerminalPhase.declined => const _PhaseView(
      'Declined',
      icon: Icons.cancel,
      error: true,
      detail: 'No payment was taken. Try again or use another payment method.',
    ),
    TerminalPhase.cancelled => const _PhaseView(
      'Cancelled',
      icon: Icons.block,
      detail: 'The terminal payment was cancelled.',
    ),
    TerminalPhase.unknown => const _PhaseView(
      'Payment status unknown',
      icon: Icons.help_outline,
      error: true,
      detail: 'Do not take another payment until the status is confirmed.',
    ),
    TerminalPhase.expired => const _PhaseView(
      'Expired',
      icon: Icons.timer_off,
      detail: 'The payment request expired without payment.',
    ),
    TerminalPhase.unavailable => const _PhaseView(
      'Terminal unavailable',
      icon: Icons.portable_wifi_off,
      error: true,
    ),
  };
}
