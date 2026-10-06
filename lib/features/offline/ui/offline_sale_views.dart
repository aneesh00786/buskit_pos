import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/server_time.dart';
import '../../checkout/models/payment.dart';
import '../models/offline_sale.dart';
import '../offline_services.dart';
import '../offline_sync_service.dart';

/// The offline services of this app run, or null when there is no local
/// storage (then every offline surface is simply absent).
OfflineServices? readOfflineServices(BuildContext context) {
  try {
    return Provider.of<OfflineServices?>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

String _money(int milli) => formatMoney(milli / 1000);

/// The cashier-facing title of a sale stored on this device. There is no
/// server sale number until a future sync, so the local reference is shown.
String offlineSaleTitle(OfflineSale sale) =>
    'Offline Sale #${sale.displayReference}';

/// Everything recorded for one offline sale: reference, time, staff, shift,
/// customer, lines (price, quantity, tax, discount), totals, payments and the
/// offline status. Never shows a server sale number.
class OfflineSaleDetails extends StatelessWidget {
  const OfflineSaleDetails({super.key, required this.sale, this.padding});
  final OfflineSale sale;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final when = sale.completedAt ?? sale.createdAt;
    return SingleChildScrollView(
      padding: padding ?? const EdgeInsets.all(PosTokens.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Row('Reference', offlineSaleTitle(sale), bold: true),
          _Row(
            'Status',
            offlineSyncLabel(sale),
            key: const Key('offline-status'),
          ),
          if (sale.serverSaleId != null)
            _Row(
              'Server sale',
              sale.serverSaleNumber ?? '#${sale.serverSaleId}',
              key: const Key('offline-server-sale'),
            ),
          if (sale.lastError != null && sale.status != OfflineSaleStatus.synced)
            _Row(
              'Sync problem',
              sale.lastError!,
              key: const Key('offline-sync-error'),
            ),
          _Row('Date / time', formatTimestamp(when)),
          _Row(
            key: const Key('offline-cashier'),
            'Cashier',
            sale.salesmanName == null
                ? sale.salesmanId
                : '${sale.salesmanName} (${sale.salesmanId})',
          ),
          _Row('Shift', '#${sale.shiftId}', key: const Key('offline-shift')),
          _Row('Register', '#${sale.registerId}'),
          if (sale.resolvedBy != null) ...[
            _Row(
              'Resolved by',
              sale.resolvedBy!,
              key: const Key('offline-resolved-by'),
            ),
            if (sale.resolutionReason != null)
              _Row('Resolution', resolutionReasonLabel(sale.resolutionReason!)),
          ],
          _Row(
            'Customer',
            sale.customerId == null
                ? 'Guest checkout'
                : (sale.customerName ?? sale.customerId!),
          ),
          const Divider(height: PosTokens.s24),
          Text('Items', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final l in sale.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.variationName == null
                              ? l.productName
                              : '${l.productName} · ${l.variationName}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          '${l.quantity} × ${_money(l.unitPriceMilli)}'
                          ' · tax ${_money(l.taxAmountMilli)}'
                          '${l.taxIncluded ? ' (incl.)' : ''}'
                          '${l.discountAmountMilli > 0 ? ' · discount ${_money(l.discountAmountMilli)}' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: PosTokens.s8),
                  Text(_money(l.lineTotalMilli)),
                ],
              ),
            ),
          const Divider(height: PosTokens.s24),
          _Row('Subtotal', _money(sale.subtotalMilli)),
          _Row('Tax', _money(sale.taxTotalMilli)),
          if (sale.discountTotalMilli != 0)
            _Row('Discount', '-${_money(sale.discountTotalMilli)}'),
          _Row('Total', _money(sale.grandTotalMilli), bold: true),
          const Divider(height: PosTokens.s24),
          Text('Payment', style: theme.textTheme.titleSmall),
          const SizedBox(height: PosTokens.s4),
          for (final p in sale.payments) ...[
            _Row(
              TenderMethod.fromWire(p.method)?.label ?? p.method,
              _money(p.amountMilli),
            ),
            if (p.tenderedMilli != null)
              _Row('  Tendered', _money(p.tenderedMilli!)),
            if ((p.changeMilli ?? 0) > 0)
              _Row('  Change', _money(p.changeMilli!)),
            if (p.reference != null) _Row('  Reference', p.reference!),
          ],
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {super.key, this.bold = false});
  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(context).textTheme.titleMedium
        : Theme.of(context).textTheme.bodyMedium;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
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

/// The success view after a sale was saved on this device (offline). Says
/// exactly that — saved locally, not yet synced — and nothing else.
class OfflineSaleSavedView extends StatelessWidget {
  const OfflineSaleSavedView({
    super.key,
    required this.sale,
    required this.onNewSale,
  });
  final OfflineSale sale;
  final VoidCallback onNewSale;

  static const savedMessage = 'Sale saved on this device.';
  static const notSyncedMessage = 'Not yet synced with server.';

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    final theme = Theme.of(context);
    final change = sale.payments.fold<int>(
      0,
      (s, p) => s + (p.changeMilli ?? 0),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: PosTokens.s16),
        Icon(Icons.cloud_off, size: 56, color: t.success),
        const SizedBox(height: PosTokens.s8),
        Text(
          savedMessage,
          key: const Key('offline-sale-saved'),
          textAlign: TextAlign.center,
          style: theme.textTheme.titleLarge,
        ),
        Text(
          notSyncedMessage,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        if (change > 0)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PosTokens.s16,
              PosTokens.s12,
              PosTokens.s16,
              0,
            ),
            child: Container(
              padding: const EdgeInsets.all(PosTokens.s12),
              decoration: BoxDecoration(
                color: t.surfaceMuted,
                borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Change due', style: theme.textTheme.titleMedium),
                  Text(
                    _money(change),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: OfflineSaleDetails(sale: sale)),
        Padding(
          padding: const EdgeInsets.all(PosTokens.s16),
          child: FilledButton.icon(
            onPressed: onNewSale,
            icon: const Icon(Icons.add_shopping_cart),
            label: const Text('New Sale'),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              backgroundColor: t.success,
              foregroundColor: t.onSuccess,
            ),
          ),
        ),
      ],
    );
  }
}

/// Cashier-facing sync status of a sale stored on this device.
String offlineSyncLabel(OfflineSale sale) => switch (sale.status) {
  OfflineSaleStatus.completedLocal ||
  OfflineSaleStatus.queued => 'Saved on this device — waiting to sync',
  OfflineSaleStatus.syncing => 'Syncing…',
  OfflineSaleStatus.syncFailed => 'Sync failed',
  OfflineSaleStatus.synced => 'Synced',
  OfflineSaleStatus.draft => 'Draft',
  OfflineSaleStatus.cancelled => 'Cancelled',
};

/// The detail of one offline sale. [onRetry] (shown for SYNC_FAILED sales)
/// re-queues it with the SAME local sale id and syncs again.
Future<void> showOfflineSaleDetail(
  BuildContext context,
  OfflineSale sale, {
  Future<void> Function()? onRetry,
  Future<void> Function()? onResolve,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(offlineSaleTitle(sale)),
      content: SizedBox(
        width: 480,
        child: OfflineSaleDetails(sale: sale, padding: EdgeInsets.zero),
      ),
      actions: [
        if (onResolve != null)
          FilledButton(
            key: const Key('offline-resolve'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await onResolve();
            },
            child: const Text('Resolve'),
          ),
        if (onRetry != null &&
            onResolve == null &&
            sale.status == OfflineSaleStatus.syncFailed)
          TextButton(
            key: const Key('offline-retry-sync'),
            onPressed: () async {
              Navigator.of(ctx).pop();
              await onRetry();
            },
            child: const Text('Retry sync'),
          ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// Sales recorded on THIS device: the ones not yet on the server (waiting,
/// syncing, failed — with the reason) and, separately, the recently synced
/// ones as "local reference -> server sale number" so a synced sale is never
/// shown as a second, separate sale next to the server history.
class LocalSalesSection extends StatefulWidget {
  const LocalSalesSection({
    super.key,
    required this.offline,
    this.canResolve = false,
    this.currentSalesmanId,
  });
  final OfflineServices offline;

  /// The signed-in staff member POSITIVELY holds sales.resolve_offline (the
  /// server enforces it again). Without it no resolution action is shown.
  final bool canResolve;
  final String? currentSalesmanId;

  @override
  State<LocalSalesSection> createState() => _LocalSalesSectionState();
}

extension on _LocalSalesSectionState {
  Widget _pendingTile(
    BuildContext context,
    OfflineSale s,
    OfflineSyncService? sync,
  ) {
    final needsManager = offlineNeedsManagerResolution(
      s,
      widget.currentSalesmanId,
    );
    final canResolve =
        sync != null &&
        offlineCanResolve(
          s,
          hasPermission: widget.canResolve,
          currentSalesmanId: widget.currentSalesmanId,
        );
    final ownSale = s.salesmanId == widget.currentSalesmanId;
    final note = !needsManager
        ? null
        : canResolve
        ? 'Manager resolution required'
        : s.status == OfflineSaleStatus.queued
        ? 'Waiting for its cashier to sign in.'
        : ownSale
        ? 'Another manager must resolve this sale.'
        : 'A manager must resolve this sale.';
    final lines = [
      '${formatTimestamp(s.completedAt ?? s.createdAt)} · ${offlineSyncLabel(s)}',
      ?s.lastError,
      ?note,
    ];
    return ListTile(
      dense: true,
      key: Key('pending-${s.localSaleId}'),
      title: Text(offlineSaleTitle(s)),
      subtitle: Text(lines.join('\n')),
      isThreeLine: lines.length > 1,
      trailing: Text(_money(s.grandTotalMilli)),
      onTap: () => showOfflineSaleDetail(
        context,
        s,
        onRetry: sync == null || needsManager
            ? null
            : () => _run(() => sync.retry(s.localSaleId)),
        onResolve: !canResolve
            ? null
            : () async {
                await showOfflineResolutionDialog(
                  context,
                  s,
                  onResolve: (reason, note) =>
                      sync.resolve(s.localSaleId, reason: reason, note: note),
                );
                if (mounted) _reload();
              },
      ),
    );
  }
}

class _LocalSalesData {
  const _LocalSalesData(this.pending, this.synced, [this.unreadable = 0]);
  final List<OfflineSale> pending;
  final List<OfflineSale> synced;

  /// Sale files on this device that cannot be read (kept, never synced).
  final int unreadable;
}

class _LocalSalesSectionState extends State<LocalSalesSection> {
  late Future<_LocalSalesData> _sales = _load();
  bool _syncing = false;

  Future<_LocalSalesData> _load() async {
    try {
      final storage = widget.offline.storage;
      final pending = (await storage.getPendingSales()).reversed.toList();
      final synced = (await storage.getSyncedSales()).reversed
          .take(20)
          .toList();
      final unreadable = (await storage.unreadableSaleFiles()).length;
      return _LocalSalesData(pending, synced, unreadable);
    } catch (_) {
      return const _LocalSalesData([], []);
    }
  }

  void _reload() => setState(() {
    _sales = _load();
  });

  Future<void> _run(Future<void> Function() action) async {
    if (_syncing) return;
    setState(() => _syncing = true);
    try {
      await action();
    } catch (_) {
      // The sale keeps its state and reason; nothing to add here.
    } finally {
      if (mounted) {
        setState(() {
          _syncing = false;
          _sales = _load();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sync = widget.offline.sync;
    return FutureBuilder<_LocalSalesData>(
      future: _sales,
      builder: (context, snap) {
        final data = snap.data;
        if (data == null ||
            (data.pending.isEmpty &&
                data.synced.isEmpty &&
                data.unreadable == 0)) {
          return const SizedBox.shrink();
        }
        return Card(
          key: const Key('local-sales'),
          margin: const EdgeInsets.all(PosTokens.s8),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 260),
            child: ListView(
              shrinkWrap: true,
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_off),
                  title: Text(
                    'On this device — not yet synced (${data.pending.length})',
                    style: theme.textTheme.titleSmall,
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (sync != null && data.pending.isNotEmpty)
                        _syncing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : TextButton(
                                key: const Key('offline-sync-now'),
                                onPressed: () =>
                                    _run(() => sync.syncNow(force: true)),
                                child: const Text('Sync now'),
                              ),
                      IconButton(
                        tooltip: 'Reload',
                        icon: const Icon(Icons.refresh),
                        onPressed: _reload,
                      ),
                    ],
                  ),
                ),
                if (data.unreadable > 0)
                  ListTile(
                    key: const Key('offline-unreadable'),
                    dense: true,
                    leading: Icon(
                      Icons.warning_amber,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(
                      '${data.unreadable} offline sale '
                      '${data.unreadable == 1 ? 'file' : 'files'} on this '
                      'device could not be read.',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                    subtitle: const Text(
                      'They are kept safely and are not synced. Contact '
                      'support before clearing or replacing this device.',
                    ),
                  ),
                for (final s in data.pending) _pendingTile(context, s, sync),
                if (data.synced.isNotEmpty) ...[
                  const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PosTokens.s16,
                      PosTokens.s8,
                      PosTokens.s16,
                      0,
                    ),
                    child: Text(
                      'Synced from this device (listed in the sales history '
                      'under their server number)',
                      style: theme.textTheme.labelMedium,
                    ),
                  ),
                  for (final s in data.synced)
                    ListTile(
                      dense: true,
                      key: Key('synced-${s.localSaleId}'),
                      title: Text(
                        '${offlineSaleTitle(s)} → '
                        '${s.serverSaleNumber ?? '#${s.serverSaleId}'}',
                      ),
                      subtitle: Text('Synced · ${_money(s.grandTotalMilli)}'),
                      onTap: () => showOfflineSaleDetail(context, s),
                    ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

String resolutionReasonLabel(String wire) {
  for (final r in OfflineResolutionReason.values) {
    if (r.wire == wire) return r.label;
  }
  return wire;
}

/// The manager's confirmation screen for resolving one offline sale. Shows
/// what will be synced (unchanged), requires a reason (OTHER: a note) and an
/// explicit acknowledgement, then calls [onResolve] and shows the result.
Future<void> showOfflineResolutionDialog(
  BuildContext context,
  OfflineSale sale, {
  required Future<OfflineResolutionOutcome> Function(
    OfflineResolutionReason reason,
    String? note,
  )
  onResolve,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _ResolutionDialog(sale: sale, onResolve: onResolve),
  );
}

class _ResolutionDialog extends StatefulWidget {
  const _ResolutionDialog({required this.sale, required this.onResolve});
  final OfflineSale sale;
  final Future<OfflineResolutionOutcome> Function(
    OfflineResolutionReason reason,
    String? note,
  )
  onResolve;

  @override
  State<_ResolutionDialog> createState() => _ResolutionDialogState();
}

class _ResolutionDialogState extends State<_ResolutionDialog> {
  static const acknowledgement =
      'I understand this sale was created during a previous shift and I am '
      'authorizing synchronization without reopening that shift.';

  OfflineResolutionReason? _reason;
  final _note = TextEditingController();
  bool _confirmed = false;
  bool _busy = false;
  OfflineResolutionOutcome? _outcome;

  bool get _noteOk =>
      _reason != OfflineResolutionReason.other ||
      _note.text.trim().length >= OfflineSyncService.resolutionNoteMinLength;
  bool get _valid => _reason != null && _noteOk && _confirmed && !_busy;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() => _busy = true);
    final outcome = await widget.onResolve(_reason!, _note.text.trim());
    if (!mounted) return;
    setState(() {
      _busy = false;
      _outcome = outcome;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sale = widget.sale;
    final done = _outcome;
    if (done != null && done.ok) {
      final synced = done.sale!;
      return AlertDialog(
        title: const Text('Offline sale synchronized'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Offline sale synchronized successfully.',
              key: Key('resolution-success'),
            ),
            const SizedBox(height: PosTokens.s8),
            _Row('Reference', offlineSaleTitle(synced)),
            _Row(
              'Server sale',
              synced.serverSaleNumber ?? '#${synced.serverSaleId}',
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ],
      );
    }
    final methods = sale.payments
        .map((p) => TenderMethod.fromWire(p.method)?.label ?? p.method)
        .toSet()
        .join(', ');
    return AlertDialog(
      title: const Text('Resolve offline sale'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Row('Reference', offlineSaleTitle(sale), bold: true),
              _Row(
                'Original cashier',
                sale.salesmanName == null
                    ? sale.salesmanId
                    : '${sale.salesmanName} (${sale.salesmanId})',
              ),
              _Row('Original shift', '#${sale.shiftId}'),
              _Row('Original register', '#${sale.registerId}'),
              _Row(
                'Sale date / time',
                formatTimestamp(sale.completedAt ?? sale.createdAt),
              ),
              _Row(
                'Customer',
                sale.customerId == null
                    ? 'Guest checkout'
                    : (sale.customerName ?? sale.customerId!),
              ),
              for (final l in sale.lines)
                _Row(
                  '${l.quantity} × ${l.productName}',
                  _money(l.lineTotalMilli),
                ),
              _Row('Total', _money(sale.grandTotalMilli), bold: true),
              _Row('Payment', methods),
              _Row('Sync problem', sale.lastError ?? offlineSyncLabel(sale)),
              const Divider(height: PosTokens.s24),
              DropdownButtonFormField<OfflineResolutionReason>(
                key: const Key('resolution-reason'),
                isExpanded: true,
                initialValue: _reason,
                decoration: const InputDecoration(
                  labelText: 'Resolution reason',
                ),
                items: [
                  for (final r in OfflineResolutionReason.values)
                    DropdownMenuItem(value: r, child: Text(r.label)),
                ],
                onChanged: _busy ? null : (r) => setState(() => _reason = r),
              ),
              const SizedBox(height: PosTokens.s8),
              TextField(
                key: const Key('resolution-note'),
                controller: _note,
                enabled: !_busy,
                maxLength: 255,
                decoration: InputDecoration(
                  labelText: _reason == OfflineResolutionReason.other
                      ? 'Resolution note (required)'
                      : 'Resolution note (optional)',
                  errorText:
                      _reason == OfflineResolutionReason.other &&
                          !_noteOk &&
                          _note.text.isNotEmpty
                      ? 'At least ${OfflineSyncService.resolutionNoteMinLength} characters'
                      : null,
                ),
                onChanged: (_) => setState(() {}),
              ),
              CheckboxListTile(
                key: const Key('resolution-confirm'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _confirmed,
                onChanged: _busy
                    ? null
                    : (v) => setState(() => _confirmed = v ?? false),
                title: Text(acknowledgement, style: theme.textTheme.bodySmall),
              ),
              if (done != null && !done.ok)
                Padding(
                  padding: const EdgeInsets.only(top: PosTokens.s8),
                  child: Text(
                    done.message!,
                    key: const Key('resolution-error'),
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: Text(done == null ? 'Cancel' : 'Close'),
        ),
        FilledButton(
          key: const Key('resolution-submit'),
          onPressed: _valid ? _submit : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Authorize sync'),
        ),
      ],
    );
  }
}
