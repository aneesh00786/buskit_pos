import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';
import '../../../core/utils/format.dart';
import '../../../core/utils/money.dart';
import '../../../core/utils/server_time.dart';
import '../models/shift_summary.dart';
import 'shift_close_view.dart' show paymentMethodLabel;

/// Phase 14C-B2 — the retail shift report, on screen. "Shift Report (X
/// Report)" for the open shift, "Shift Closing Report (Z Report)" for the
/// closed one. Every figure is the server's (current shift summary / close
/// result); the only derived value is net sales = gross sales − refunds,
/// in exact thousandths (the backend analytics definition). Not a fiscal
/// printer protocol, and nothing here is printed.
class ShiftReportView extends StatelessWidget {
  const ShiftReportView({
    super.key,
    required this.summary,
    required this.closing,
    this.varianceKey,
  });

  final ShiftSummary summary;

  /// true = the final Z report of a closed shift.
  final bool closing;
  final Key? varianceKey;

  static String title(bool closing) =>
      closing ? 'Shift Closing Report (Z Report)' : 'Shift Report (X Report)';

  @override
  Widget build(BuildContext context) {
    final s = summary;
    final count = s.cashCount;
    final netMilli =
        milliFromDouble(s.salesTotal) - milliFromDouble(s.refundsTotal);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title(closing),
          key: Key(closing ? 'z-report-title' : 'x-report-title'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: PosTokens.s8),
        _Section(
          title: 'Shift',
          children: [
            _Line('Store', s.storeId == null ? '—' : 'Store #${s.storeId}'),
            _Line('Register', s.registerLabel),
            _Line(
              'Shift',
              '#${s.shiftId}',
              valueKey: const Key('report-shift-id'),
            ),
            _Line('Cashier', s.openedBy ?? '—'),
            _Line(
              'Opened',
              s.openedAt == null ? '—' : formatTimestamp(s.openedAt!),
            ),
            if (s.closedAt != null)
              _Line('Closed', formatTimestamp(s.closedAt!)),
            _Line(
              'Status',
              s.isOpen ? 'Open' : 'Closed',
              valueKey: const Key('report-status'),
            ),
          ],
        ),
        _Section(
          title: 'Cash',
          children: [
            _Line('Opening cash', formatMoney(s.cash.opening)),
            _Line('Cash sales', formatMoney(s.cash.cashSales)),
            _Line('Cash refunds', '−${formatMoney(s.cash.cashRefunds)}'),
            _Line('Cash deposits', formatMoney(s.cash.deposits)),
            _Line('Cash withdrawals', '−${formatMoney(s.cash.withdrawals)}'),
            _Line(
              'Expected cash',
              formatMoney(s.cash.expected),
              emphasise: true,
              valueKey: const Key('report-expected'),
            ),
            if (s.cash.counted != null)
              _Line(
                'Counted cash',
                formatMoney(s.cash.counted),
                valueKey: const Key('report-counted'),
              ),
            if (s.cash.variance != null)
              _Line(
                'Variance',
                signedMilli(milliFromDouble(s.cash.variance!)),
                emphasise: true,
                valueKey: varianceKey ?? const Key('report-variance'),
              ),
          ],
        ),
        _Section(
          title: 'Payments',
          children: s.payments.isEmpty
              ? [const _Line('No payments', '—')]
              : [
                  for (final p in s.payments)
                    _Line(
                      '${paymentMethodLabel(p.method)} (${p.count})',
                      formatMoney(p.amount),
                      valueKey: Key('report-payment-${p.method}'),
                    ),
                ],
        ),
        _Section(
          title: 'Sales',
          children: [
            _Line(
              'Number of sales',
              '${s.salesCount}',
              valueKey: const Key('report-sales-count'),
            ),
            _Line('Gross sales', formatMoney(s.salesTotal)),
            _Line(
              'Refunds (${s.refundsCount})',
              '−${formatMoney(s.refundsTotal)}',
            ),
            _Line(
              'Net sales',
              formatMilli(netMilli),
              emphasise: true,
              valueKey: const Key('report-net'),
            ),
            if (s.voidsCount > 0)
              _Line('Voided (${s.voidsCount})', formatMoney(s.voidsTotal)),
          ],
        ),
        if (count != null)
          _Section(
            title: count.currency.isEmpty
                ? 'Cash count'
                : 'Cash count (${count.currency})',
            children: [
              for (final l in count.lines)
                _Line(
                  '${formatMilli(l.valueMilli)} × ${l.quantity}',
                  formatMilli(l.lineMilli),
                  valueKey: Key('report-denom-${l.valueMilli}'),
                ),
              _Line(
                'Counted',
                formatMilli(count.countedMilli),
                emphasise: true,
                valueKey: const Key('report-count-total'),
              ),
            ],
          ),
      ],
    );
  }
}

/// `+5.00` / `−7.50` / `0.00` for a milli amount.
String signedMilli(int milli) {
  if (milli == 0) return formatMilli(0);
  return milli > 0 ? '+${formatMilli(milli)}' : '−${formatMilli(-milli)}';
}

/// Opens the X report of the open shift as a dialog (on screen only).
Future<void> showXReport(BuildContext context, ShiftSummary summary) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: ShiftReportView(summary: summary, closing: false),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('x-report-close'),
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: PosTokens.s12),
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
