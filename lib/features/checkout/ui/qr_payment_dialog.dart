import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/money.dart';
import '../data/payment_terminal_service.dart';
import '../models/terminal_payment.dart';
import '../state/terminal_payment_controller.dart';

/// Runs one UPI / QR payment. Resolves to the CAPTURED attempt as soon as the
/// server confirms payment ("Payment received" -> straight on to completing
/// the sale), or null when the cashier closes it without payment.
Future<PaymentAttempt?> showQrPayment(
  BuildContext context, {
  required PaymentTerminalService service,
  required int saleId,
  required PaymentProviderInfo provider,
  required int amountMilli,
  String currencyLabel = 'INR',
}) {
  return showDialog<PaymentAttempt>(
    context: context,
    barrierDismissible: false,
    builder: (_) => QrPaymentDialog(
      createController: () => TerminalPaymentController(service, saleId: saleId, provider: provider.name, amountMilli: amountMilli, method: 'QR'),
      provider: provider,
      currencyLabel: currencyLabel,
    ),
  );
}

class QrPaymentDialog extends StatefulWidget {
  const QrPaymentDialog({super.key, required this.createController, required this.provider, this.currencyLabel = 'INR', this.autoContinueDelay = const Duration(milliseconds: 900)});

  /// Each call is a NEW payment request (new idempotency key) — used for the
  /// first QR and for "New QR" after a failed / expired / cancelled one.
  final TerminalPaymentController Function() createController;
  final PaymentProviderInfo provider;
  final String currencyLabel;

  /// How long "Payment received" stays visible before continuing.
  final Duration autoContinueDelay;

  @override
  State<QrPaymentDialog> createState() => _QrPaymentDialogState();
}

class _QrPaymentDialogState extends State<QrPaymentDialog> {
  late TerminalPaymentController _c;
  Timer? _clock;
  bool _continued = false;

  @override
  void initState() {
    super.initState();
    _begin();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  void _begin() {
    _c = widget.createController()..addListener(_onChange);
    _c.start();
  }

  void _retry() {
    _c
      ..removeListener(_onChange)
      ..dispose();
    setState(_begin);
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
    if (_c.phase == TerminalPhase.approved && !_continued) {
      _continued = true;
      final attempt = _c.attempt;
      Future<void>.delayed(widget.autoContinueDelay, () {
        if (mounted) Navigator.of(context).pop(attempt);
      });
    }
  }

  // Countdown display; at the provider's expiry ask the SERVER (it decides).
  void _tick() {
    if (!mounted) return;
    final exp = _c.attempt?.expiresAt;
    if (exp != null && _c.attempt!.status.isOpen && !DateTime.now().toUtc().isBefore(exp) && _c.phase == TerminalPhase.waitingForCard) {
      _c.refreshNow();
    }
    setState(() {});
  }

  @override
  void dispose() {
    _clock?.cancel();
    _c
      ..removeListener(_onChange)
      ..dispose();
    super.dispose();
  }

  String? _remaining() {
    final exp = _c.attempt?.expiresAt;
    if (exp == null || !(_c.attempt?.status.isOpen ?? false)) return null;
    final left = exp.difference(DateTime.now().toUtc());
    if (left.isNegative) return 'Expiring…';
    final m = left.inMinutes;
    final s = left.inSeconds % 60;
    return 'Expires in $m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final view = _QrPhaseView.of(_c.phase);
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final image = _c.attempt?.qrImageUrl;
    final showQr = image != null && (_c.phase == TerminalPhase.waitingForCard || _c.phase == TerminalPhase.processing);
    final remaining = _remaining();
    return AlertDialog(
      key: Key('qr-phase-${_c.phase.name}'),
      title: Text('UPI QR · ${widget.provider.label}'),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Amount: ${widget.currencyLabel == 'INR' ? '₹' : '${widget.currencyLabel} '}${formatMilli(_c.amountMilli)}', style: text.headlineSmall),
            const SizedBox(height: PosTokens.s12),
            if (showQr)
              Container(
                key: const Key('qr-image'),
                color: Colors.white,
                padding: const EdgeInsets.all(PosTokens.s8),
                child: Image.network(
                  image,
                  width: 260,
                  height: 260,
                  fit: BoxFit.contain,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 260,
                    height: 120,
                    child: Center(child: Text('The QR could not be loaded. Check the payment status or cancel.', textAlign: TextAlign.center)),
                  ),
                ),
              )
            else if (view.busy)
              const SizedBox(width: 48, height: 48, child: CircularProgressIndicator())
            else
              Icon(view.icon, size: 48, color: view.error ? scheme.error : (_c.phase == TerminalPhase.approved ? PosTokens.of(context).success : null)),
            const SizedBox(height: PosTokens.s12),
            Semantics(liveRegion: true, child: Text(view.title, style: text.titleMedium, textAlign: TextAlign.center)),
            if (remaining != null) Text(remaining, key: const Key('qr-countdown'), style: text.bodySmall),
            if ((_c.message ?? view.detail) != null) ...[
              const SizedBox(height: PosTokens.s8),
              Text(_c.message ?? view.detail!, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
      actions: [
        if (_c.attempt != null && _c.attempt!.status.isOpen)
          TextButton(onPressed: _c.phase == TerminalPhase.processing ? null : _c.checkAgain, child: const Text('Check payment status')),
        if (_c.canCheckAgain && _c.attempt == null) TextButton(onPressed: _c.checkAgain, child: const Text('Check payment status')),
        if (_c.canCancel && widget.provider.cancel) TextButton(onPressed: _c.cancel, child: const Text('Cancel')),
        if (_c.canRetry) FilledButton(onPressed: _retry, child: const Text('New QR')),
        if ((_c.isFinal && _c.phase != TerminalPhase.approved) || _c.phase == TerminalPhase.unknown)
          TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
      ],
    );
  }
}

class _QrPhaseView {
  const _QrPhaseView(this.title, {this.icon = Icons.qr_code_2, this.busy = false, this.error = false, this.detail});
  final String title;
  final IconData icon;
  final bool busy;
  final bool error;
  final String? detail;

  static _QrPhaseView of(TerminalPhase p) => switch (p) {
    TerminalPhase.connecting => const _QrPhaseView('Generating QR…', busy: true),
    TerminalPhase.waitingForCard => const _QrPhaseView('Waiting for customer payment…', detail: 'Ask the customer to scan the QR with any UPI app.'),
    TerminalPhase.processing => const _QrPhaseView('Checking payment…', busy: true),
    TerminalPhase.cancelling => const _QrPhaseView('Cancelling…', busy: true),
    TerminalPhase.approved => const _QrPhaseView('Payment received', icon: Icons.check_circle),
    TerminalPhase.declined => const _QrPhaseView('Payment failed', icon: Icons.cancel, error: true, detail: 'No payment was received. You can show a new QR or use another payment method.'),
    TerminalPhase.cancelled => const _QrPhaseView('Cancelled', icon: Icons.block, detail: 'The QR was cancelled; it can no longer be paid.'),
    TerminalPhase.expired => const _QrPhaseView('QR expired', icon: Icons.timer_off, detail: 'The QR expired without payment. Show a new QR to try again.'),
    TerminalPhase.unknown => const _QrPhaseView('Payment status unknown', icon: Icons.help_outline, error: true, detail: 'Do not take another payment until the status is confirmed.'),
    TerminalPhase.unavailable => const _QrPhaseView('UPI QR unavailable', icon: Icons.cloud_off, error: true),
  };
}
