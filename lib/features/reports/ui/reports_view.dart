import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../core/network/pos_api_client.dart';
import '../../../core/theme/pos_tokens.dart';
import '../../../core/ui/state_views.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/json_read.dart';
import '../../auth/state/session_controller.dart';
import '../data/report_service.dart';
import '../export/report_file_sharer.dart';
import '../models/retail_report.dart';
import '../state/reports_controller.dart';

/// Phase 14F-B — Retail Reports: product, cashier, register and tax sales for
/// a period, exactly as the server reports them (rows AND totals). Opened
/// from the sidebar like Analytics (dialog on wide screens, sheet on
/// phones). A tab is hidden only when this staff member is KNOWN to lack its
/// permission; the server enforces every report itself.
Future<void> showReports(
  BuildContext context, {
  ReportService? service,
  ReportFileSharer? sharer,
}) {
  final session = context.read<SessionController>();
  final kinds = [
    for (final k in ReportKind.values)
      if (!session.isDenied(k.permission)) k,
  ];
  final controller = ReportsController(
    service ?? ApiReportService(context.read<PosApiClient>()),
    kinds: kinds,
    sharer: sharer,
  );
  final size = MediaQuery.sizeOf(context);
  Widget content() => ChangeNotifierProvider<ReportsController>.value(
    value: controller,
    child: const ReportsView(),
  );
  if (size.width >= 900) {
    return showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 820,
            maxHeight: size.height * 0.92,
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
    showDragHandle: true,
    builder: (_) => SizedBox(height: size.height * 0.92, child: content()),
  ).whenComplete(controller.dispose);
}

class ReportsView extends StatefulWidget {
  const ReportsView({super.key});

  @override
  State<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends State<ReportsView> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final c = context.read<ReportsController>();
      if (c.kinds.isNotEmpty) c.load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.watch<ReportsController>();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Reports',
                  style: Theme.of(context).textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ],
          ),
        ),
        if (c.kinds.isEmpty)
          const Expanded(
            child: EmptyView(
              title: 'No reports available',
              message: 'You do not have permission to view sales reports.',
              icon: Icons.lock_outline,
            ),
          )
        else ...[
          _DateBar(controller: c),
          _Tabs(controller: c),
          SizedBox(
            height: 4,
            child: c.status == ReportStatus.loading
                ? const LinearProgressIndicator()
                : null,
          ),
          Expanded(child: _Body(controller: c)),
        ],
      ],
    );
  }
}

class _DateBar extends StatelessWidget {
  const _DateBar({required this.controller});
  final ReportsController controller;

  Future<void> _pick(BuildContext context, bool from) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final current = from ? controller.draftFrom : controller.draftTo;
    final picked = await showDatePicker(
      context: context,
      initialDate: current ?? today,
      // The backend allows periods of up to 366 days.
      firstDate: today.subtract(const Duration(days: 365 * 3)),
      // The store's zone may already be a day ahead of this device.
      lastDate: today.add(const Duration(days: 1)),
    );
    if (picked == null) return;
    from ? controller.setFrom(picked) : controller.setTo(picked);
  }

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final busy = c.status == ReportStatus.loading;
    final r = c.report;
    String label(DateTime? d, String fallback) =>
        d == null ? fallback : ReportsController.iso(d);
    final period = r == null
        ? null
        : '${r.from == r.to ? r.from : '${r.from} – ${r.to}'}'
              '${r.timezone == null ? '' : ' · ${r.timezone}'}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: PosTokens.s8,
            runSpacing: PosTokens.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                key: const Key('report-from'),
                onPressed: busy ? null : () => _pick(context, true),
                icon: const Icon(Icons.event, size: 18),
                label: Text(label(c.draftFrom, 'From')),
              ),
              OutlinedButton.icon(
                key: const Key('report-to'),
                onPressed: busy ? null : () => _pick(context, false),
                icon: const Icon(Icons.event, size: 18),
                label: Text(label(c.draftTo, 'To')),
              ),
              FilledButton(
                key: const Key('report-apply'),
                onPressed: busy ? null : c.apply,
                child: const Text('Apply'),
              ),
              TextButton(
                key: const Key('report-today'),
                onPressed: busy ? null : c.today,
                child: const Text('Today'),
              ),
              _ExportButton(controller: c),
            ],
          ),
          if (c.exportError != null)
            Padding(
              padding: const EdgeInsets.only(top: PosTokens.s4),
              child: Text(
                c.exportError!,
                key: const Key('report-export-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (c.validation != null)
            Padding(
              padding: const EdgeInsets.only(top: PosTokens.s4),
              child: Text(
                c.validation!,
                key: const Key('report-validation'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (period != null)
            Padding(
              padding: const EdgeInsets.only(top: PosTokens.s4),
              child: Text(
                period,
                key: const Key('report-period'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }
}

/// Phase 14F-C — exports the report on screen (selected tab, applied
/// period) as CSV through the platform share / save sheet.
class _ExportButton extends StatelessWidget {
  const _ExportButton({required this.controller});
  final ReportsController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    return OutlinedButton.icon(
      key: const Key('report-export'),
      onPressed: c.canExport
          ? () {
              final box = context.findRenderObject() as RenderBox?;
              c.exportCsv(
                origin: box == null || !box.hasSize
                    ? null
                    : box.localToGlobal(Offset.zero) & box.size,
              );
            }
          : null,
      icon: c.exporting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.download_outlined, size: 18),
      label: Text(c.exporting ? 'Exporting…' : 'Export CSV'),
    );
  }
}

class _Tabs extends StatelessWidget {
  const _Tabs({required this.controller});
  final ReportsController controller;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final k in controller.kinds)
            Padding(
              padding: const EdgeInsets.only(right: PosTokens.s8),
              child: ChoiceChip(
                key: Key('report-tab-${k.path}'),
                label: Text(k.label),
                selected: controller.kind == k,
                onSelected: controller.status == ReportStatus.loading
                    ? null
                    : (_) => controller.select(k),
              ),
            ),
        ],
      ),
    );
  }
}

// ------------------------------------------------------------------ body

String _money(Object? v) {
  final d = asDouble(v);
  return d == null ? '—' : formatMoney(d);
}

/// Whole quantities as integers, anything else to exactly 3 decimals
/// (a WEIGHT 1.250 stays "1.250", never "1").
String _qty(Object? v) {
  final d = asDouble(v);
  if (d == null) return '—';
  if (d == d.roundToDouble()) return d.toInt().toString();
  return d.toStringAsFixed(3);
}

String _count(Object? v) => asInt(v)?.toString() ?? '—';

String _rate(Object? v) {
  final d = asDouble(v);
  return d == null ? '—' : '${formatQty(d)}%';
}

typedef _Field = (String label, String key, String Function(Object?) fmt);

const List<_Field> _salesMoney = [
  ('Gross sales', 'gross_sales', _money),
  ('Refunds', 'refunds', _money),
  ('Net sales', 'net_sales', _money),
  ('Tax', 'tax', _money),
  ('Net tax', 'net_tax', _money),
];

List<_Field> _rowFields(ReportKind k) => switch (k) {
  ReportKind.products => [
    ('Sales', 'sales_count', _count),
    ('Qty sold', 'quantity_sold', _qty),
    ('Qty refunded', 'quantity_refunded', _qty),
    ('Net qty', 'net_quantity', _qty),
    ..._salesMoney,
  ],
  ReportKind.cashiers || ReportKind.registers => [
    ('Sales', 'sales_count', _count),
    ('Refunds (count)', 'refunds_count', _count),
    ..._salesMoney,
  ],
  ReportKind.tax => [
    ('Sales', 'sales_count', _count),
    ('Lines', 'line_count', _count),
    ('Taxable', 'taxable_amount', _money),
    ('Tax', 'tax_amount', _money),
    ('Refund lines', 'refund_line_count', _count),
    ('Refund taxable', 'refund_taxable_amount', _money),
    ('Refund tax', 'refund_tax_amount', _money),
    ('Net taxable', 'net_taxable_amount', _money),
    ('Net tax', 'net_tax_amount', _money),
  ],
};

List<_Field> _totalFields(ReportKind k) => switch (k) {
  ReportKind.products => _salesMoney,
  ReportKind.cashiers ||
  ReportKind.registers => [('Sales', 'sales_count', _count), ..._salesMoney],
  ReportKind.tax => [
    ('Taxable', 'taxable_amount', _money),
    ('Tax', 'tax_amount', _money),
    ('Refund taxable', 'refund_taxable_amount', _money),
    ('Refund tax', 'refund_tax_amount', _money),
    ('Net taxable', 'net_taxable_amount', _money),
    ('Net tax', 'net_tax_amount', _money),
  ],
};

(String title, String? subtitle) _rowTitle(
  ReportKind k,
  Map<String, dynamic> r,
) {
  switch (k) {
    case ReportKind.products:
      final name =
          asString(r['product_name']) ??
          'Product #${r['product_variation_id']}';
      final variation = asString(r['variation_name']);
      final ids = [
        if (asString(r['sku']) != null) 'SKU ${asString(r['sku'])}',
        if (asString(r['barcode']) != null) 'Barcode ${asString(r['barcode'])}',
      ];
      return (
        variation == null ? name : '$name — $variation',
        ids.isEmpty ? null : ids.join(' · '),
      );
    case ReportKind.cashiers:
      final id = asString(r['staff_id']);
      return (asString(r['staff_name']) ?? id ?? 'Unknown cashier', id);
    case ReportKind.registers:
      final code = asString(r['register_code']);
      return (
        asString(r['register_name']) ??
            (r['register_id'] == null
                ? 'No register'
                : 'Register #${r['register_id']}'),
        code,
      );
    case ReportKind.tax:
      return ('Tax rate ${_rate(r['tax_rate'])}', null);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.controller});
  final ReportsController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    switch (c.status) {
      case ReportStatus.idle:
      case ReportStatus.loading:
        if (c.report == null) {
          return const LoadingView(label: 'Loading report');
        }
      case ReportStatus.error:
        return ErrorView(
          key: const Key('report-error'),
          message: c.error?.message ?? 'The report could not be loaded.',
          onRetry: c.load,
        );
      case ReportStatus.loaded:
        break;
    }
    final r = c.report!;
    final k = c.kind;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (k == ReportKind.tax &&
            r.taxComponents == null &&
            r.notes.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: PosTokens.s8),
            child: Text(
              r.notes.first,
              key: const Key('report-tax-note'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        _TotalsCard(kind: k, totals: r.totals),
        if (r.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: PosTokens.s16),
            child: Text(
              'No sales in this period.',
              key: Key('report-empty'),
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final (i, row) in r.rows.indexed)
            _RowCard(index: i, kind: k, row: row),
      ],
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.kind, required this.totals});
  final ReportKind kind;
  final Map<String, dynamic> totals;

  @override
  Widget build(BuildContext context) {
    return Card(
      key: const Key('report-totals'),
      margin: const EdgeInsets.only(bottom: PosTokens.s12),
      child: Padding(
        padding: const EdgeInsets.all(PosTokens.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Totals', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: PosTokens.s4),
            _Stats(
              fields: _totalFields(kind),
              values: totals,
              keyPrefix: 'report-total',
            ),
          ],
        ),
      ),
    );
  }
}

class _RowCard extends StatelessWidget {
  const _RowCard({required this.index, required this.kind, required this.row});
  final int index;
  final ReportKind kind;
  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final (title, subtitle) = _rowTitle(kind, row);
    final payments = asList(row['payments'])
        .map(asMap)
        .whereType<Map<String, dynamic>>()
        .toList();
    return Card(
      key: Key('report-row-$index'),
      margin: const EdgeInsets.only(bottom: PosTokens.s8),
      child: Padding(
        padding: const EdgeInsets.all(PosTokens.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              key: Key('report-$index-title'),
              style: theme.textTheme.titleSmall,
            ),
            if (subtitle != null)
              Text(
                subtitle,
                key: Key('report-$index-subtitle'),
                style: theme.textTheme.bodySmall,
              ),
            const SizedBox(height: PosTokens.s4),
            _Stats(
              fields: _rowFields(kind),
              values: row,
              keyPrefix: 'report-$index',
            ),
            // Only the methods the server returned (no invented rows).
            if (payments.isNotEmpty) ...[
              const SizedBox(height: PosTokens.s8),
              Text('Payments', style: theme.textTheme.labelLarge),
              for (final p in payments)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '${asString(p['method']) ?? '—'}: tendered ${_money(p['tendered'])} · '
                    'refunded ${_money(p['refunded'])} · net ${_money(p['net'])}',
                    key: Key('report-$index-pay-${asString(p['method'])}'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Label / value pairs that wrap on narrow screens (no horizontal overflow).
class _Stats extends StatelessWidget {
  const _Stats({
    required this.fields,
    required this.values,
    required this.keyPrefix,
  });
  final List<_Field> fields;
  final Map<String, dynamic> values;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: PosTokens.s16,
      runSpacing: PosTokens.s4,
      children: [
        for (final (label, key, fmt) in fields)
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                Text(
                  fmt(values[key]),
                  key: Key('$keyPrefix-$key'),
                  style: theme.textTheme.titleSmall,
                ),
              ],
            ),
          ),
      ],
    );
  }
}
