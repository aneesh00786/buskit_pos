import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../data/payment_exception_service.dart';
import '../data/payment_recovery_service.dart';
import '../models/terminal_payment.dart';

/// Why a captured payment's sale could not be completed (server reason code).
String exceptionReasonText(String? code) => switch (code) {
  'STOCK_CONFLICT' => 'Stock is no longer available.',
  'AMOUNT_MISMATCH' || 'CAPTURED_AMOUNT_DIFFERS' =>
    'A price or tax changed, so the payment no longer matches the sale total.',
  'PRODUCT_UNAVAILABLE' ||
  'UNAVAILABLE_ITEMS' => 'A product in this sale is no longer available.',
  'SHIFT_NOT_CURRENT' => 'The original shift is no longer open.',
  'BUSINESS_RULE' => 'A sale rule prevents completing it.',
  'CHECK_FAILED' => 'The sale could not be checked right now.',
  _ => 'The sale cannot be completed.',
};

String providerName(String? p) => switch (p) {
  'PINE_LABS' => 'Pine Labs',
  'RAZORPAY' => 'Razorpay',
  null => '—',
  _ => p,
};

/// Phase 7 — the manager's "Resolve Payment Exception" screen for one
/// captured payment whose sale cannot be completed. Razorpay: a FULL refund
/// through the server (amount fixed, explicit confirmation). Pine Labs: an
/// acknowledged manual-refund flag (never claimed as refunded).
/// Phase 8 — Pine Labs MANUAL_REFUND_REQUIRED: after refunding through the
/// Pine Labs / manual procedure, the manager records the refund slip
/// reference ("Mark Refund Completed"; the POS never calls Pine Labs). When
/// the server has not yet seen the payment captured, the manager is sent to
/// "Check Payment" ([onCheckPayment]: a refreshed recovery check of this
/// sale) instead of retrying.
/// The server enforces permission, four-eyes and idempotency; double-taps
/// are ignored.
Future<PaymentExceptionView?> showPaymentExceptionDialog(
  BuildContext context, {
  required RecoverableSale sale,
  required PaymentExceptionService service,
  Future<PaymentRecoveryResult> Function()? onCheckPayment,
}) {
  return showDialog<PaymentExceptionView>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ExceptionDialog(
      sale: sale,
      service: service,
      onCheckPayment: onCheckPayment,
    ),
  );
}

class _ExceptionDialog extends StatefulWidget {
  const _ExceptionDialog({
    required this.sale,
    required this.service,
    this.onCheckPayment,
  });
  final RecoverableSale sale;
  final PaymentExceptionService service;
  final Future<PaymentRecoveryResult> Function()? onCheckPayment;

  @override
  State<_ExceptionDialog> createState() => _ExceptionDialogState();
}

class _ExceptionDialogState extends State<_ExceptionDialog> {
  late RecoverableSale _sale = widget.sale;
  final _reference = TextEditingController();
  final _note = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  String? _error;
  PaymentExceptionView? _result;

  /// The server does not know the payment is captured yet: check it first.
  bool _captureUnknown = false;
  String? _checkMessage;

  RecoveryExceptionInfo get _info => _sale.exception!;
  bool get _manual => _info.recommendedAction == 'MANUAL_REFUND';
  bool get _closeout => _info.state == 'MANUAL_REFUND_REQUIRED';
  String? get _validReference => validManualRefundReference(_reference.text);

  RecoveryAttempt? get _attempt {
    for (final a in _sale.attempts) {
      if (a.attempt.id == _info.paymentAttemptId) return a;
    }
    return null;
  }

  @override
  void dispose() {
    _reference.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        if (e.errorCode == captureStatusUnknownCode) {
          _captureUnknown = true;
          _checkMessage = null;
        } else {
          _error = describeApiError(e);
        }
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() {
    final id = _info.paymentAttemptId;
    return _run(() async {
      final r = await switch (_info.state) {
        'REFUND_PENDING' => widget.service.checkRefund(id),
        'REFUND_FAILED' => widget.service.retryRefund(id),
        'MANUAL_REFUND_REQUIRED' => widget.service.completeManualRefund(
          id,
          reference: _validReference!,
          note: _note.text.trim().isEmpty ? null : _note.text.trim(),
        ),
        _ =>
          _manual
              ? widget.service.flagManualRefund(id)
              : widget.service.refund(id),
      };
      if (mounted) setState(() => _result = r);
    });
  }

  /// "Check Payment": ask the server to refresh this sale's payment, then
  /// say what it found. Only a captured payment returns to the refund flow.
  Future<void> _checkPayment() {
    final check = widget.onCheckPayment;
    if (check == null) return Future.value();
    return _run(() async {
      final r = await check();
      if (!mounted) return;
      RecoverableSale? found;
      for (final s in r.recoverable) {
        if (s.saleId == _sale.saleId) found = s;
      }
      final attempt = found?.attempts
          .where((a) => a.attempt.id == _info.paymentAttemptId)
          .firstOrNull;
      setState(() {
        if (found != null && found.exception != null) {
          _sale = found;
          _captureUnknown = false;
          _confirmed = false;
          _checkMessage = 'Payment captured. You can continue.';
          return;
        }
        _checkMessage = switch (attempt?.attempt.status) {
          AttemptStatus.pending || AttemptStatus.authorized =>
            'The payment is still pending. Check again shortly.',
          AttemptStatus.failed || AttemptStatus.cancelled => 'The payment was not captured (failed or cancelled): no money was taken, so no refund is needed or available.',
          AttemptStatus.refunded || AttemptStatus.partiallyRefunded =>
            'This payment has already been refunded.',
          AttemptStatus.captured => 'The payment is captured and the sale can be completed: resume the sale instead of refunding it.',
          _ =>
            r.resolved.any((x) => x.saleId == _sale.saleId && x.completed)
                ? 'The sale was completed with this payment. No refund is needed.'
                : 'This payment has already been refunded and the sale is closed.',
        };
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _sale;
    final a = _attempt;
    final amount = a?.attempt.amount ?? s.sale.totals.grandTotal ?? 0;
    final provider = a?.attempt.provider ?? _info.provider ?? '';
    final result = _result;
    final state = result?.state ?? _info.state;
    final closeout = _closeout && result == null;
    return AlertDialog(
      title: Text(
        _closeout ? 'Manual Pine Labs Refund' : 'Resolve Payment Exception',
      ),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Payment captured but sale could not be completed.',
                key: Key('exception-headline'),
              ),
              const SizedBox(height: PosTokens.s8),
              _Line('Sale', s.reference),
              for (final l in s.sale.items)
                _Line(
                  '${l.quantity} × ${l.productName ?? 'Item ${l.productVariationId}'}',
                  formatMoney(l.lineTotal),
                ),
              _Line(
                'Amount captured',
                formatMoney(amount),
                key: const Key('exception-captured'),
              ),
              if (!_manual)
                _Line(
                  'Refund amount',
                  formatMoney(amount),
                  key: const Key('exception-refund-amount'),
                ),
              _Line('Provider', provider),
              _Line(
                _closeout ? 'Original payment reference' : 'Provider reference',
                a?.attempt.providerReference ?? '—',
              ),
              if (_closeout) ...[
                _Line('Original cashier', _info.originalCashier ?? '—'),
                _Line(
                  'Captured',
                  _info.capturedAt == null
                      ? '—'
                      : formatTimestamp(_info.capturedAt!),
                ),
              ],
              _Line(
                'Payment status',
                a == null ? '—' : a.attempt.status.name.toUpperCase(),
              ),
              _Line('Reason', exceptionReasonText(s.blockedReason)),
              const Divider(height: PosTokens.s24),
              if (result != null)
                _resultView(result, theme)
              else if (_captureUnknown) ...[
                Text(
                  'Payment status needs to be checked first.',
                  key: const Key('exception-capture-unknown'),
                  style: theme.textTheme.titleSmall,
                ),
                const Text(
                  'The server has not confirmed that this payment was captured. '
                  'Check the payment before requesting a refund.',
                ),
              ] else if (closeout) ...[
                const Text(
                  'Refund this payment through the Pine Labs/manual process first.',
                  key: Key('exception-closeout-instructions'),
                ),
                const SizedBox(height: PosTokens.s8),
                TextField(
                  key: const Key('exception-refund-reference'),
                  controller: _reference,
                  enabled: !_busy,
                  maxLength: 64,
                  decoration: InputDecoration(
                    labelText: 'Refund Reference',
                    helperText: 'The Pine Labs / manual refund slip number',
                    errorText:
                        _reference.text.trim().isNotEmpty &&
                            _validReference == null
                        ? 'Use letters, digits, spaces or - / . _ : # (never a card number)'
                        : null,
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                TextField(
                  key: const Key('exception-note'),
                  controller: _note,
                  enabled: !_busy,
                  maxLength: 255,
                  decoration: const InputDecoration(
                    labelText: 'Manager Note (optional)',
                  ),
                ),
              ] else ...[
                if (_manual)
                  const Text(
                    'Manual Pine Labs refund required. Refund the payment on the '
                    'Pine Labs terminal or merchant portal using the reference '
                    'above, then keep the refund slip. The POS records that a '
                    'manual refund is required — it does not refund the payment.',
                    key: Key('exception-manual-instructions'),
                  ),
                if (state == 'REFUND_PENDING')
                  const Text(
                    'Refund is being processed. Check its status again.',
                  ),
                if (state == 'REFUND_FAILED')
                  const Text(
                    'The last refund could not be completed. You can request it again.',
                  ),
              ],
              if (result == null &&
                  !_captureUnknown &&
                  (state == 'OPEN' ||
                      state == 'REFUND_FAILED' ||
                      state == 'MANUAL_REFUND_REQUIRED'))
                CheckboxListTile(
                  key: const Key('exception-confirm'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _confirmed,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _confirmed = v ?? false),
                  title: Text(
                    _closeout
                        ? 'I confirm that the customer payment has been manually refunded.'
                        : _manual
                        ? 'I acknowledge this payment must be refunded manually at Pine Labs.'
                        : 'Refund the full captured amount of ${formatMoney(amount)} to the customer.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (_checkMessage != null)
                Padding(
                  padding: const EdgeInsets.only(top: PosTokens.s8),
                  child: Text(
                    _checkMessage!,
                    key: const Key('exception-check-result'),
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: PosTokens.s8),
                  child: Text(
                    _error!,
                    key: const Key('exception-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(result),
          child: Text(result == null ? 'Cancel' : 'Close'),
        ),
        if (result == null && _captureUnknown)
          FilledButton(
            key: const Key('exception-check-payment'),
            onPressed: _busy || widget.onCheckPayment == null
                ? null
                : _checkPayment,
            child: const Text('Check Payment'),
          )
        else if (result == null || result.state == 'REFUND_PENDING')
          FilledButton(
            key: const Key('exception-submit'),
            onPressed: _busy || !_canSubmit(result?.state ?? state)
                ? null
                : _submit,
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_label(result?.state ?? state)),
          ),
      ],
    );
  }

  bool _canSubmit(String state) => switch (state) {
    'OPEN' || 'REFUND_FAILED' => _confirmed,
    'MANUAL_REFUND_REQUIRED' => _confirmed && _validReference != null,
    'REFUND_PENDING' => true,
    _ => false,
  };

  String _label(String state) => switch (state) {
    'REFUND_PENDING' => 'Check Refund',
    'REFUND_FAILED' => 'Retry Refund',
    'MANUAL_REFUND_REQUIRED' => 'Mark Refund Completed',
    _ => _manual ? 'Mark for Manual Refund' : 'Refund Captured Payment',
  };

  Widget _resultView(PaymentExceptionView r, ThemeData theme) {
    if (r.state == 'REFUNDED' && r.isManualRefund) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Manual refund recorded successfully.',
            key: const Key('exception-manual-refunded'),
            style: theme.textTheme.titleMedium,
          ),
          _Line('Refund reference', r.manualRefundReference ?? '—'),
          _Line('Amount', formatMoney(r.amount)),
          _Line('Provider', providerName(r.provider)),
          const _Line('Refund method', 'Manual (manager-confirmed)'),
          _Line('Manager', r.manualRefundCompletedBy ?? '—'),
          if (r.manualRefundCompletedAt != null)
            _Line('Date / time', formatTimestamp(r.manualRefundCompletedAt!)),
        ],
      );
    }
    switch (r.state) {
      case 'REFUNDED':
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Payment refunded successfully.',
              key: const Key('exception-refunded'),
              style: theme.textTheme.titleMedium,
            ),
            _Line('Refund amount', formatMoney(r.refundAmount ?? r.amount)),
            _Line('Refund reference', r.providerRefundId ?? '—'),
            _Line('Provider', r.provider),
            if (r.resolvedAt != null)
              _Line('Time', formatTimestamp(r.resolvedAt!)),
          ],
        );
      case 'REFUND_PENDING':
        return const Text(
          'Refund is being processed.',
          key: Key('exception-pending'),
        );
      case 'REFUND_FAILED':
        return const Text(
          'Refund could not be completed.',
          key: Key('exception-failed'),
        );
      case 'MANUAL_REFUND_REQUIRED':
        return const Text(
          'Manual Pine Labs refund required. The payment is recorded as needing a manual refund — it has not been refunded by the POS.',
          key: Key('exception-manual'),
        );
      default:
        return Text(r.state);
    }
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(label)),
        const SizedBox(width: PosTokens.s8),
        Flexible(child: Text(value, textAlign: TextAlign.end)),
      ],
    ),
  );
}
