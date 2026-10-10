import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/error_messages.dart';
import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/json_read.dart';
import '../../../core/utils/server_time.dart';
import '../../checkout/data/payment_exception_service.dart';
import '../../checkout/ui/payment_exception_dialog.dart';
import '../data/store_exception_service.dart';
import '../state/store_exceptions_controller.dart';
import '../../../core/ui/safe_insets.dart';

const _filterLabels = {
  'UNRESOLVED': 'Unresolved',
  'OPEN': 'Open',
  'MANUAL_REFUND_REQUIRED': 'Manual Refund Required',
  'REFUND_PENDING': 'Refund Pending',
  'REFUND_FAILED': 'Refund Failed',
  'REFUNDED': 'Refunded',
  'ALL': 'All',
};

String stateLabel(String s) => switch (s) {
  'OPEN' => 'Open — needs a manager',
  'MANUAL_REFUND_REQUIRED' => 'Manual refund required',
  'REFUND_PENDING' => 'Refund pending',
  'REFUND_FAILED' => 'Refund failed',
  'REFUNDED' => 'Refunded',
  _ => s,
};

/// Phase 9 — opens the manager's store-wide Payment Exceptions screen: the
/// current store's captured payments whose sale could not be completed,
/// from every register and device. Resolution reuses the existing exception
/// dialog and server actions (refund / manual close-out, four-eyes on the
/// server). Online only.
Future<void> showStoreExceptions(BuildContext context) {
  final client = context.read<PosApiClient>();
  final service = context.read<StoreExceptionService?>()!;
  PaymentExceptionService? actions;
  try {
    actions = Provider.of<PaymentExceptionService?>(context, listen: false);
  } on ProviderNotFoundException {
    actions = null;
  }
  final controller = StoreExceptionsController(
    service,
    isOffline: () => client.reachable.value == false,
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<StoreExceptionsController>.value(
    value: controller,
    child: StoreExceptionsView(service: service, actions: actions),
  );
  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 1100,
            maxHeight: size.height * 0.9,
          ),
          child: content(),
        ),
      ),
    ).whenComplete(controller.dispose);
  }
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (_) => SizedBox(
      height: size.height * 0.9,
      child: SheetSafeArea(child: content()),
    ),
  ).whenComplete(controller.dispose);
}

class StoreExceptionsView extends StatefulWidget {
  const StoreExceptionsView({super.key, required this.service, this.actions});
  final StoreExceptionService service;

  /// The resolution actions (null: viewing only).
  final PaymentExceptionService? actions;

  @override
  State<StoreExceptionsView> createState() => _StoreExceptionsViewState();
}

class _StoreExceptionsViewState extends State<StoreExceptionsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<StoreExceptionsController>().load();
    });
  }

  Future<void> _resolve(StoreExceptionDetail d) async {
    final actions = widget.actions;
    final sale = d.sale;
    if (actions == null || sale == null || sale.exception == null) return;
    final c = context.read<StoreExceptionsController>();
    final r = await showPaymentExceptionDialog(
      context,
      sale: sale,
      service: actions,
      onCheckPayment: () async => (await widget.service.detail(
        d.paymentAttemptId,
        refresh: true,
      )).toRecoveryResult(),
    );
    if (!mounted) return;
    // Whatever happened (or not), the server's state is re-read.
    await c.afterAction(d.paymentAttemptId);
    if (r != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(switch (r.state) {
            'REFUNDED' when r.isManualRefund =>
              'Manual refund recorded successfully.',
            'REFUNDED' => 'Payment refunded successfully.',
            'REFUND_PENDING' => 'Refund is being processed.',
            'REFUND_FAILED' => 'Refund could not be completed.',
            'MANUAL_REFUND_REQUIRED' => 'Manual Pine Labs refund required.',
            _ => r.state,
          }),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<StoreExceptionsController>();
    final wide = MediaQuery.sizeOf(context).width >= 900;
    final detail = c.detail;
    final showDetailOnly = !wide && (detail != null || c.detailLoading);
    return Material(
      child: Padding(
        padding: const EdgeInsets.all(PosTokens.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Payment Exceptions',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  key: const Key('store-exceptions-refresh'),
                  tooltip: 'Refresh',
                  onPressed: c.loading ? null : c.load,
                  icon: const Icon(Icons.refresh),
                ),
                IconButton(
                  tooltip: 'Close',
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const Text(
              'Captured payments in this store whose sale could not be completed — from every register.',
            ),
            const SizedBox(height: PosTokens.s8),
            if (c.offline)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: PosTokens.s16),
                child: Text(
                  'You are offline. Payment exceptions need a connection: nothing is shown or can be resolved until the POS is back online.',
                  key: Key('store-exceptions-offline'),
                ),
              )
            else
              Expanded(
                child: showDetailOnly
                    ? _DetailPane(
                        onResolve: _resolve,
                        canResolve: widget.actions != null,
                      )
                    : wide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Expanded(flex: 5, child: _ListPane()),
                          const VerticalDivider(width: PosTokens.s24),
                          Expanded(
                            flex: 6,
                            child: _DetailPane(
                              onResolve: _resolve,
                              canResolve: widget.actions != null,
                            ),
                          ),
                        ],
                      )
                    : const _ListPane(),
              ),
          ],
        ),
      ),
    );
  }
}

class _ListPane extends StatelessWidget {
  const _ListPane();

  @override
  Widget build(BuildContext context) {
    final c = context.watch<StoreExceptionsController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: PosTokens.s8,
          runSpacing: PosTokens.s4,
          children: [
            for (final f in StoreExceptionsController.filters)
              ChoiceChip(
                key: Key('store-exceptions-filter-$f'),
                label: Text(_filterLabels[f]!),
                selected: c.filter == f,
                onSelected: (_) => c.setFilter(f),
              ),
          ],
        ),
        const SizedBox(height: PosTokens.s8),
        if (c.error != null)
          Text(
            describeApiError(c.error!),
            key: const Key('store-exceptions-error'),
          ),
        Expanded(
          child: c.loading
              ? const Center(child: CircularProgressIndicator())
              : c.items.isEmpty
              ? const Center(
                  child: Text(
                    'No payment exceptions for this filter.',
                    key: Key('store-exceptions-empty'),
                  ),
                )
              : ListView(
                  children: [
                    for (final i in c.items) _ExceptionTile(item: i),
                    if (c.hasMore)
                      Padding(
                        padding: const EdgeInsets.all(PosTokens.s8),
                        child: OutlinedButton(
                          key: const Key('store-exceptions-more'),
                          onPressed: c.loadingMore ? null : c.loadMore,
                          child: Text(c.loadingMore ? 'Loading…' : 'Load more'),
                        ),
                      ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _ExceptionTile extends StatelessWidget {
  const _ExceptionTile({required this.item});
  final StoreExceptionItem item;

  @override
  Widget build(BuildContext context) {
    final c = context.read<StoreExceptionsController>();
    final selected =
        context.watch<StoreExceptionsController>().detail?.paymentAttemptId ==
        item.paymentAttemptId;
    final theme = Theme.of(context);
    // Unresolved items are emphasized by weight and wording (no colours).
    final style = item.unresolved
        ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)
        : theme.textTheme.bodyMedium;
    return ListTile(
      key: Key('store-exception-${item.paymentAttemptId}'),
      selected: selected,
      onTap: () => c.open(item.paymentAttemptId),
      title: Text(
        '${item.saleReference} · ${providerName(item.provider)} · ${formatMoney(item.amount)}',
        style: style,
      ),
      subtitle: Text(
        [
          item.unresolved
              ? 'ACTION NEEDED: ${stateLabel(item.state)}'
              : stateLabel(item.state),
          exceptionReasonText(item.reasonCode),
          'Cashier ${item.originalCashier ?? '—'}',
          'Register ${item.registerCode ?? '#${item.registerId}'}',
          if (item.createdAt != null) formatTimestamp(item.createdAt!),
        ].join(' · '),
      ),
    );
  }
}

class _DetailPane extends StatelessWidget {
  const _DetailPane({required this.onResolve, required this.canResolve});
  final Future<void> Function(StoreExceptionDetail) onResolve;
  final bool canResolve;

  @override
  Widget build(BuildContext context) {
    final c = context.watch<StoreExceptionsController>();
    final wide = MediaQuery.sizeOf(context).width >= 900;
    if (c.detailLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (c.detailError != null) {
      return Center(child: Text(describeApiError(c.detailError!)));
    }
    final d = c.detail;
    if (d == null) {
      return const Center(child: Text('Select a payment exception.'));
    }
    final ex = d.exception ?? const <String, dynamic>{};
    final sale = d.sale?.sale;
    final attempt = asList(d.json['payment_attempts'])
        .map(asMap)
        .whereType<Map<String, dynamic>>()
        .where((a) => asInt(a['id']) == d.paymentAttemptId)
        .firstOrNull;
    final theme = Theme.of(context);
    final state = asString(ex['state']);
    final canAct = asBool(ex['viewer_can_act']) ?? false;
    final block = asString(ex['viewer_block_reason']);
    final actionable = d.isException && state != null && state != 'REFUNDED';
    String ts(Object? v) {
      final t = DateTime.tryParse(asString(v) ?? '');
      return t == null ? '—' : formatTimestamp(t);
    }

    return ListView(
      key: const Key('store-exception-detail'),
      children: [
        if (!wide)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('store-exception-back'),
              onPressed: c.closeDetail,
              icon: const Icon(Icons.arrow_back),
              label: const Text('Back to list'),
            ),
          ),
        Text(
          state == null
              ? 'Not a payment exception (payment ${d.paymentStatus ?? '—'})'
              : stateLabel(state),
          key: const Key('store-exception-state'),
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: PosTokens.s8),
        _Section('SALE'),
        _Line('Sale / draft', d.sale?.reference ?? 'Draft #${d.saleId}'),
        if (sale != null) ...[
          for (final l in sale.items)
            _Line(
              '${l.quantity} × ${l.productName ?? 'Item ${l.productVariationId}'}',
              formatMoney(l.lineTotal),
            ),
          _Line('Tax', formatMoney(sale.totals.taxTotal)),
          _Line('Total', formatMoney(sale.totals.grandTotal)),
        ],
        _Line('Original cashier', asString(ex['original_cashier']) ?? '—'),
        _Line('Shift', '#${asInt(ex['original_shift_id']) ?? '—'}'),
        _Line(
          'Register',
          d.registerCode ?? '#${asInt(ex['register_id']) ?? '—'}',
        ),
        _Line('Device', '#${asInt(ex['device_id']) ?? '—'}'),
        _Line('Sale status', d.saleStatus ?? '—'),
        _Line('Created', ts(asMap(d.json['sale'])?['created_at'])),
        _Section('PAYMENT'),
        _Line('Provider', providerName(asString(attempt?['provider']))),
        _Line(
          'Payment reference',
          asString(attempt?['provider_reference']) ?? '—',
        ),
        _Line(
          'Amount',
          '${formatMoney(asDouble(attempt?['amount']))} ${asString(attempt?['currency']) ?? ''}',
        ),
        _Line('Payment state', d.paymentStatus ?? '—'),
        _Line('Captured', ts(ex['captured_at'])),
        _Section('EXCEPTION'),
        _Line('Reason', exceptionReasonText(asString(ex['reason_code']))),
        _Line('State', state == null ? '—' : stateLabel(state)),
        _Line('Flagged / requested', ts(ex['resolved_at'])),
        if (asString(ex['refund_method']) != null)
          _Line(
            'Refund method',
            asString(ex['refund_method']) == 'MANUAL'
                ? 'Manual (manager-confirmed)'
                : 'Provider',
          ),
        if (asMap(ex['manual_refund']) != null)
          _Line(
            'Manual refund reference',
            asString(asMap(ex['manual_refund'])!['reference']) ?? '—',
          ),
        const SizedBox(height: PosTokens.s8),
        if (actionable && canAct && canResolve)
          FilledButton(
            key: const Key('store-exception-resolve'),
            onPressed: () => onResolve(d),
            child: Text(
              state == 'MANUAL_REFUND_REQUIRED'
                  ? 'Manual Pine Labs Refund'
                  : 'Resolve Payment Exception',
            ),
          )
        else if (actionable)
          Text(
            block == 'SELF_RESOLUTION'
                ? 'Another authorized manager must resolve this payment.'
                : 'Manager approval required.',
            key: const Key('store-exception-viewer'),
          ),
        _Section('AUDIT'),
        if (d.events.isEmpty) const Text('No actions yet.'),
        for (final e in d.events)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              [
                if (e.createdAt != null) formatTimestamp(e.createdAt!),
                e.action,
                e.actor ?? '—',
                '${e.fromStatus ?? '—'} → ${e.toStatus ?? '—'}',
                if (e.refundMethod != null)
                  e.refundMethod == 'MANUAL' ? 'Manual' : 'Provider',
                if (e.refundReference != null) 'ref ${e.refundReference}',
                if (e.providerRefundId != null) e.providerRefundId!,
                if (e.errorCode != null) e.errorCode!,
                if (e.note != null) e.note!,
              ].join(' · '),
              key: Key('store-exception-event-${e.action}'),
            ),
          ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.title);
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: PosTokens.s12, bottom: PosTokens.s4),
    child: Text(title, style: Theme.of(context).textTheme.labelLarge),
  );
}

class _Line extends StatelessWidget {
  const _Line(this.label, this.value);
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
