import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/network/error_messages.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../cart/state/cart_controller.dart';
import '../../offline/offline_storage_service.dart';
import '../data/payment_exception_service.dart';
import '../data/payment_recovery_service.dart';
import '../models/payment.dart';
import '../models/terminal_payment.dart';
import 'payment_exception_dialog.dart';

/// Phase 6 — after the app (re)starts, or the connection comes back with an
/// empty cart: asks the server for this device's unfinished sales and shows
/// the Payment Recovery screen when there is anything to recover. Nothing is
/// restored or paid silently: every action is the cashier's, and no action
/// here ever starts a new payment — completing uses ONLY the captured
/// attempts the server lists; a new payment is only possible from the normal
/// pay screen after a failed / cancelled attempt (the server refuses one
/// while a payment is open or captured).
///
/// Returns true when the recovery screen was shown.
Future<bool> runPaymentRecovery(
  BuildContext context, {
  required PaymentRecoveryService service,
  required CartController cart,
  OfflineStorageService? storage,
  PaymentExceptionService? exceptions,
}) async {
  List<int> markers = const [];
  try {
    markers = await storage?.getPaymentRecoveryMarkers() ?? const [];
  } catch (_) {}
  final PaymentRecoveryResult result;
  try {
    result = await service.fetch(saleIds: markers);
  } on ApiException {
    return false; // offline / server down: tried again on reconnect
  }
  // Reminders the server no longer knows as a draft of this device, other
  // than completed ones the cashier must be told about, are cleared quietly.
  final keep = {
    ...result.recoverable.map((r) => r.saleId),
    ...result.resolved.where((r) => r.completed).map((r) => r.saleId),
  };
  for (final id in markers.where((m) => !keep.contains(m))) {
    try {
      await storage?.removePaymentRecoveryMarker(id);
    } catch (_) {}
  }
  final completed = result.resolved.where((r) => r.completed).toList();
  // Phase 7: a captured payment already flagged for a manual (Pine Labs)
  // refund needs nothing more from staff who cannot act on it — it stays
  // visible to managers / admins, but does not pop up on every launch or
  // resume. Phase 8: a manager who can close it out IS shown it.
  final needsAttention = result.recoverable.where(
    (r) =>
        r.exception?.state != 'MANUAL_REFUND_REQUIRED' ||
        r.exception!.viewerCanAct,
  );
  if (needsAttention.isEmpty && completed.isEmpty) return false;
  if (!context.mounted) return false;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PaymentRecoveryDialog(
      initial: PaymentRecoveryResult(
        recoverable: result.recoverable,
        resolved: completed,
      ),
      service: service,
      cart: cart,
      storage: storage,
      exceptions: exceptions,
    ),
  );
  return true;
}

class PaymentRecoveryDialog extends StatefulWidget {
  const PaymentRecoveryDialog({
    super.key,
    required this.initial,
    required this.service,
    required this.cart,
    this.storage,
    this.exceptions,
  });
  final PaymentRecoveryResult initial;
  final PaymentRecoveryService service;
  final CartController cart;
  final OfflineStorageService? storage;

  /// Phase 7 — refund / manual-refund of a captured payment whose sale
  /// cannot complete (manager only; null hides the action).
  final PaymentExceptionService? exceptions;

  @override
  State<PaymentRecoveryDialog> createState() => _PaymentRecoveryDialogState();
}

class _PaymentRecoveryDialogState extends State<PaymentRecoveryDialog> {
  late List<RecoverableSale> _sales = widget.initial.recoverable;
  late final List<ResolvedSale> _completed = widget.initial.resolved;
  int? _selected;
  bool _busy = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    if (_sales.length == 1) _selected = _sales.first.saleId;
  }

  RecoverableSale? get _current {
    for (final s in _sales) {
      if (s.saleId == _selected) return s;
    }
    return null;
  }

  Future<void> _forget(int saleId) async {
    try {
      await widget.storage?.removePaymentRecoveryMarker(saleId);
    } catch (_) {}
  }

  Future<void> _reload({bool refresh = false}) async {
    final ids = {..._sales.map((s) => s.saleId)}.toList();
    final r = await widget.service.fetch(refresh: refresh, saleIds: ids);
    if (!mounted) return;
    for (final done in r.resolved) {
      await _forget(done.saleId);
      if (done.completed) {
        _notice =
            'Sale ${done.saleNumber ?? '#${done.saleId}'} is already completed. '
            'No further payment is needed.';
      }
    }
    setState(() {
      _sales = r.recoverable;
      if (_current == null && _sales.length == 1) {
        _selected = _sales.first.saleId;
      }
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = describeApiError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// CAPTURED: restore the draft and complete it with the captured
  /// attempt(s) — the existing completion (same transaction, stock and
  /// idempotency). Never a new payment.
  Future<void> _resume(RecoverableSale s) => _run(() async {
    if (!widget.cart.restoreRecoveredSale(s.sale)) {
      setState(
        () => _error = 'Finish, hold or void the sale in the cart first, then resume this one.',
      );
      return;
    }
    final ok = await widget.cart.completeSale(s.completionPayments);
    if (ok) {
      await _forget(s.saleId);
      final done = widget.cart.completedSale;
      widget.cart.acknowledgeCompletion();
      if (!mounted) return;
      setState(() {
        _notice =
            'Sale ${done?.displayNumber ?? s.reference} completed with the '
            'payment already taken. No further payment was needed.';
        _sales = _sales.where((x) => x.saleId != s.saleId).toList();
        _selected = _sales.length == 1 ? _sales.first.saleId : null;
      });
      return;
    }
    final message = widget.cart.error?.message;
    // The sale stays a draft with its captured payment (nothing lost); the
    // cart is cleared so it cannot be edited into something else.
    widget.cart.reset();
    await _reload();
    if (!mounted) return;
    setState(
      () => _error = message == null
          ? 'The sale could not be completed.'
          : 'The sale could not be completed: $message The payment stays '
                'recorded; a manager must handle it.',
    );
  });

  Future<void> _check() => _run(() => _reload(refresh: true));

  Future<void> _cancel(RecoverableSale s) => _run(() async {
    // Phase 18B.18: never an attempt whose reference is recorded but not attached.
    for (final a in s.attempts.where((a) => a.cancellable && !a.referenceRecordedUnattached)) {
      await widget.service.cancelAttempt(a.attempt.id);
    }
    await _reload();
  });

  /// FAILED / CANCELLED / no payment: put the draft back in the cart; the
  /// cashier takes payment with the normal pay screen (a NEW attempt and
  /// reference — the old one is never reused).
  Future<void> _restore(RecoverableSale s) async {
    if (_busy) return;
    if (!widget.cart.restoreRecoveredSale(s.sale)) {
      setState(
        () => _error = 'Finish, hold or void the sale in the cart first, then restore this one.',
      );
      return;
    }
    await _forget(s.saleId);
    if (mounted) Navigator.of(context).pop();
  }

  /// Phase 7 — a manager resolves a captured payment whose sale cannot be
  /// completed. The result is shown in the exception dialog; the list is
  /// then re-read from the server (a refunded draft is cancelled there).
  Future<void> _resolve(RecoverableSale s) async {
    final service = widget.exceptions;
    if (_busy || service == null || s.exception == null) return;
    final r = await showPaymentExceptionDialog(
      context,
      sale: s,
      service: service,
      onCheckPayment: () =>
          widget.service.fetch(refresh: true, saleIds: [s.saleId]),
    );
    if (r == null || !mounted) return;
    await _run(() async {
      await _reload();
      if (r.state == 'REFUNDED') await _forget(s.saleId);
    });
    if (!mounted) return;
    setState(
      () => _notice = switch (r.state) {
        'REFUNDED' when r.isManualRefund =>
          'Manual refund recorded successfully.',
        'REFUNDED' => 'Payment refunded successfully.',
        'REFUND_PENDING' => 'Refund is being processed.',
        'REFUND_FAILED' => 'Refund could not be completed.',
        'MANUAL_REFUND_REQUIRED' => 'Manual Pine Labs refund required.',
        _ => null,
      },
    );
  }

  /// What a captured-payment exception means for whoever is looking at it.
  static String exceptionMessage(RecoveryExceptionInfo e) => switch (e.state) {
    'REFUND_PENDING' => 'Refund is being processed.',
    'REFUNDED' => 'Payment refunded successfully.',
    'REFUND_FAILED' => 'Refund could not be completed.',
    'MANUAL_REFUND_REQUIRED' =>
      'Manual Pine Labs refund required. The payment has not been refunded '
          'by the POS.',
    _ => 'Payment captured but sale could not be completed.',
  };

  static String? viewerMessage(RecoveryExceptionInfo e) {
    if (e.state == 'REFUNDED') return null;
    if (e.viewerCanAct) return null;
    return e.viewerBlockReason == 'SELF_RESOLUTION'
        ? 'Another authorized manager must resolve this payment.'
        : 'Manager approval required.';
  }

  static String blockedMessage(String reason) => switch (reason) {
    'SHIFT_NOT_CURRENT' =>
      'This sale belongs to an earlier shift and cannot be completed now. '
          'A manager must handle the payment.',
    'CAPTURED_AMOUNT_DIFFERS' =>
      'The payment taken no longer matches the sale total (a price or tax '
          'changed). A manager must handle the payment.',
    'UNAVAILABLE_ITEMS' =>
      'A product in this sale is no longer available. A manager must handle '
          'this sale.',
    'PAYMENT_STILL_OPEN' =>
      'Another payment for this sale is still in progress. Check it first.',
    'STOCK_CONFLICT' ||
    'AMOUNT_MISMATCH' ||
    'PRODUCT_UNAVAILABLE' ||
    'BUSINESS_RULE' ||
    'CHECK_FAILED' =>
      '${exceptionReasonText(reason)} A manager must handle the payment.',
    _ => 'This sale needs a manager.',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = _current;
    final multiple = _sales.length > 1;
    return AlertDialog(
      title: const Text('Payment Recovery', key: Key('recovery-title')),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final c in _completed)
                _Banner(
                  key: Key('recovery-completed-${c.saleId}'),
                  text:
                      'Sale ${c.saleNumber ?? '#${c.saleId}'} was completed before '
                      'the app restarted. No further payment is needed.',
                ),
              if (_sales.isNotEmpty)
                Text(
                  multiple
                      ? '${_sales.length} unfinished sales were found on this register.'
                      : 'An unfinished payment was found on this register.',
                ),
              if (multiple) ...[
                const SizedBox(height: PosTokens.s8),
                for (final s in _sales)
                  ListTile(
                    key: Key('recovery-sale-${s.saleId}'),
                    dense: true,
                    selected: s.saleId == _selected,
                    title: Text(
                      '${s.reference} · ${formatMoney(s.sale.totals.grandTotal)}',
                    ),
                    subtitle: Text(
                      '${_providers(s)} · ${s.state.label}'
                      '${s.createdAt == null ? '' : ' · ${formatTimestamp(s.createdAt!)}'}',
                    ),
                    onTap: _busy
                        ? null
                        : () => setState(() => _selected = s.saleId),
                  ),
              ],
              if (current != null) ...[
                const Divider(height: PosTokens.s24),
                _SaleDetail(sale: current),
                if (current.blockedReason != null)
                  Padding(
                    padding: const EdgeInsets.only(top: PosTokens.s8),
                    child: Text(
                      blockedMessage(current.blockedReason!),
                      key: const Key('recovery-blocked'),
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                if (current.exception case final e?) ...[
                  Padding(
                    padding: const EdgeInsets.only(top: PosTokens.s8),
                    child: Text(
                      exceptionMessage(e),
                      key: const Key('recovery-exception'),
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  if (e.resolvedBy != null)
                    Text(
                      'Handled by ${e.resolvedBy}',
                      key: const Key('recovery-exception-resolver'),
                    ),
                  if (viewerMessage(e) case final m?)
                    Text(m, key: const Key('recovery-exception-viewer')),
                ],
              ],
              if (_notice != null)
                _Banner(key: const Key('recovery-notice'), text: _notice!),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: PosTokens.s8),
                  child: Text(
                    _error!,
                    key: const Key('recovery-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('recovery-later'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(_sales.isEmpty ? 'Close' : 'Later'),
        ),
        if (current != null) ..._actions(current),
      ],
    );
  }

  List<Widget> _actions(RecoverableSale s) {
    final busy = _busy;
    final e = s.exception;
    if (e != null && s.state == RecoveryState.captured) {
      if (e.state == 'REFUNDED' ||
          !e.viewerCanAct ||
          widget.exceptions == null) {
        return const [];
      }
      if (e.state == 'MANUAL_REFUND_REQUIRED') {
        // Phase 8: record the manual Pine Labs refund (manager-confirmed).
        return [
          FilledButton(
            key: const Key('recovery-complete-manual-refund'),
            onPressed: busy ? null : () => _resolve(s),
            child: const Text('Manual Pine Labs Refund'),
          ),
        ];
      }
      return [
        FilledButton(
          key: const Key('recovery-resolve-exception'),
          onPressed: busy ? null : () => _resolve(s),
          child: const Text('Resolve Payment Exception'),
        ),
      ];
    }
    if (s.blockedReason != null && s.state != RecoveryState.pending) {
      return const [];
    }
    switch (s.state) {
      case RecoveryState.captured:
        return [
          FilledButton(
            key: const Key('recovery-resume'),
            onPressed: busy || !s.canComplete ? null : () => _resume(s),
            child: const Text('Resume Sale'),
          ),
        ];
      case RecoveryState.pending:
      case RecoveryState.authorized:
        return [
          if (s.attempts.any((a) => a.cancellable && !a.referenceRecordedUnattached))
            TextButton(
              key: const Key('recovery-cancel'),
              onPressed: busy ? null : () => _cancel(s),
              child: const Text('Cancel Payment'),
            ),
          FilledButton(
            key: const Key('recovery-check'),
            onPressed: busy ? null : _check,
            child: const Text('Check Payment'),
          ),
        ];
      case RecoveryState.failed:
        return [
          FilledButton(
            key: const Key('recovery-retry'),
            onPressed: busy || !s.currentShift ? null : () => _restore(s),
            child: const Text('Retry Payment'),
          ),
        ];
      case RecoveryState.cancelled:
        return [
          FilledButton(
            key: const Key('recovery-retry'),
            onPressed: busy || !s.currentShift ? null : () => _restore(s),
            child: const Text('Start Payment Again'),
          ),
        ];
      case RecoveryState.noPayment:
        return [
          FilledButton(
            key: const Key('recovery-restore'),
            onPressed: busy || !s.currentShift ? null : () => _restore(s),
            child: const Text('Restore Cart'),
          ),
        ];
    }
  }

  static String _providers(RecoverableSale s) {
    final names = s.attempts
        .map((a) => a.attempt.provider)
        .whereType<String>()
        .toSet();
    return names.isEmpty ? 'No provider payment' : names.join(', ');
  }
}

/// Phase 18B.18 — shown for an open attempt whose provider reference is
/// recorded but not attached. Says nothing about whether money was taken.
const recordedReferenceGuidance =
    'The provider reference for this payment is recorded but not attached yet. It may still be paid at the provider — '
    'do not take another payment. A manager must attach the recorded reference in the admin portal (Payment Reconciliation); '
    'then use Check Payment, and the payment can be checked or cancelled normally.';

/// Phase 18B.18 — the provider-reference line for an OPEN attempt; null when
/// the server did not say (older backend) or the attempt has ended.
String? referenceLabel(RecoveryAttempt a) {
  if (!a.attempt.status.isOpen) return null;
  if (a.attempt.hasProviderReference) return 'Provider reference attached';
  return switch (a.attempt.referenceStatus) {
    ProviderReferenceStatus.recordedUnattached => 'Provider reference recorded — waiting for a manager to attach it',
    ProviderReferenceStatus.notRecorded => 'No provider reference',
    ProviderReferenceStatus.attached => 'Provider reference attached',
    ProviderReferenceStatus.unknown => null,
  };
}

class _SaleDetail extends StatelessWidget {
  const _SaleDetail({required this.sale});
  final RecoverableSale sale;

  static String _status(AttemptStatus s) => switch (s) {
    AttemptStatus.pending => 'Pending',
    AttemptStatus.authorized => 'Authorized',
    AttemptStatus.captured => 'Captured',
    AttemptStatus.failed => 'Failed',
    AttemptStatus.cancelled => 'Cancelled',
    _ => s.name,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      key: Key('recovery-detail-${sale.saleId}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(sale.reference, style: theme.textTheme.titleMedium),
        Text(sale.state.label, key: const Key('recovery-state')),
        const SizedBox(height: PosTokens.s8),
        for (final l in sale.sale.items)
          _Line(
            '${l.quantity} × ${l.productName ?? 'Item ${l.productVariationId}'}',
            formatMoney(l.lineTotal),
          ),
        _Line('Total', formatMoney(sale.sale.totals.grandTotal), bold: true),
        const SizedBox(height: PosTokens.s8),
        for (final a in sale.attempts) ...[
          _Line(
            '${a.attempt.provider ?? ''} · '
                '${TenderMethod.fromWire(a.method.toLowerCase())?.label ?? (a.method == 'QR' ? 'UPI QR' : a.method)}'
                '${a.attempt.providerReference == null ? '' : ' · ${a.attempt.providerReference}'}',
            '${formatMoney(a.attempt.amount)} · ${_status(a.attempt.status)}'
                '${a.refreshError == null ? '' : ' (provider not reachable)'}',
          ),
          // Phase 18B.18: the provider-reference state of an open attempt.
          if (referenceLabel(a) != null)
            Text(referenceLabel(a)!, key: Key('recovery-reference-${a.attempt.id}'), style: theme.textTheme.bodySmall),
          if (a.referenceRecordedUnattached)
            _Banner(text: recordedReferenceGuidance, key: Key('recovery-reference-recorded-${a.attempt.id}')),
        ],
      ],
    );
  }
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value, {this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleSmall
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: PosTokens.s8),
          Flexible(
            child: Text(value, style: style, textAlign: TextAlign.end),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      margin: const EdgeInsets.only(top: PosTokens.s8),
      padding: const EdgeInsets.all(PosTokens.s12),
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
      ),
      child: Text(text),
    );
  }
}
