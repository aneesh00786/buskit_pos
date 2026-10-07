import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/pos_tokens.dart';

/// Top bar for medium/expanded/wide layouts: search, quick actions (alerts,
/// reports, settings — placeholders), the signed-in staff member, the time and
/// the server-reachability indicator. Secondary items drop away as the bar
/// narrows so the search field always keeps its room.
class PosHeader extends StatelessWidget {
  const PosHeader({
    super.key,
    required this.search,
    this.staffLabel,
    this.roleLabel = 'POS staff',
    this.reachable,
    this.now,
    this.onScanBarcode,
    this.onOpenReports,
    this.scanUnavailableReason =
        'Camera scanning is not available on this device',
  });

  final Widget search;
  final String? staffLabel;
  final String roleLabel;
  final ValueListenable<bool?>? reachable;

  /// Opens the camera scanner; null when this device has no camera scanning.
  final VoidCallback? onScanBarcode;
  final String scanUnavailableReason;

  /// Phase 14F-C — opens the Reports screen; null keeps the placeholder.
  final VoidCallback? onOpenReports;

  /// Injectable clock for tests.
  final DateTime Function()? now;

  static const _actions = [
    (Icons.notifications_none, 'Alerts'),
    (Icons.bar_chart_outlined, 'Reports'),
    (Icons.settings_outlined, 'Quick settings'),
  ];

  void _action(BuildContext context, String what) {
    if (what == 'Reports' && onOpenReports != null) return onOpenReports!();
    _soon(context, what);
  }

  void _soon(BuildContext context, String what) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('$what is coming soon')));
  }

  @override
  Widget build(BuildContext context) {
    final t = PosTokens.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: PosTokens.s16,
        vertical: PosTokens.s8,
      ),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: LayoutBuilder(
        builder: (context, c) {
          // Priority when space is tight: search > server status > staff > barcode
          // > quick actions > clock.
          final w = c.maxWidth;
          final showBarcode = w >= 520;
          final showStatus = w >= 560;
          final showStaffText = w >= 680;
          final showActions = w >= 780;
          final showMore = w >= 560;
          final showClock = w >= 900;
          return Row(
            children: [
              Expanded(child: search),
              if (showBarcode)
                IconButton(
                  tooltip: onScanBarcode == null
                      ? scanUnavailableReason
                      : 'Scan barcode with camera',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: onScanBarcode,
                  icon: const Icon(Icons.qr_code_scanner),
                ),
              if (showActions)
                for (final a in _actions)
                  IconButton(
                    tooltip: a.$2,
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    onPressed: () => _action(context, a.$2),
                    icon: Icon(a.$1),
                  )
              else if (showMore)
                PopupMenuButton<String>(
                  tooltip: 'More actions',
                  icon: const Icon(Icons.more_horiz),
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onSelected: (label) => _action(context, label),
                  itemBuilder: (_) => [
                    for (final a in _actions)
                      PopupMenuItem<String>(
                        value: a.$2,
                        child: Row(
                          children: [
                            Icon(a.$1),
                            const SizedBox(width: 12),
                            Text(a.$2),
                          ],
                        ),
                      ),
                  ],
                ),
              const SizedBox(width: PosTokens.s8),
              _StaffChip(
                label: staffLabel,
                role: roleLabel,
                showText: showStaffText,
              ),
              if (showStatus) ...[
                const SizedBox(width: PosTokens.s16),
                NetworkStatusChip(reachable: reachable),
              ],
              if (showClock) ...[
                const SizedBox(width: PosTokens.s16),
                ClockText(now: now),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _StaffChip extends StatelessWidget {
  const _StaffChip({
    required this.label,
    required this.role,
    required this.showText,
  });
  final String? label;
  final String role;
  final bool showText;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Semantics(
      label: 'Signed in as ${label ?? 'staff'}, $role',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: scheme.primaryContainer,
              child: Icon(
                Icons.person_outline,
                color: scheme.onPrimaryContainer,
                size: 20,
              ),
            ),
            if (showText) ...[
              const SizedBox(width: PosTokens.s8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label ?? 'Signed in',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.titleSmall,
                    ),
                    Text(
                      role,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Global offline notice: visible only while the last request could not
/// reach the server (the API client's reachability — real server access, not
/// "Wi-Fi is on"). It never says anything was synced.
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key, this.reachable});
  final ValueListenable<bool?>? reachable;

  static const message =
      'OFFLINE — cannot reach the server. Card-terminal and UPI payments need an internet connection.';

  @override
  Widget build(BuildContext context) {
    final source = reachable;
    if (source == null) return const SizedBox.shrink();
    return ValueListenableBuilder<bool?>(
      valueListenable: source,
      builder: (context, ok, _) {
        if (ok != false) return const SizedBox.shrink();
        final t = PosTokens.of(context);
        return Semantics(
          liveRegion: true,
          child: Container(
            key: const Key('offline-banner'),
            width: double.infinity,
            color: t.warning.withValues(alpha: 0.15),
            padding: const EdgeInsets.symmetric(
              horizontal: PosTokens.s16,
              vertical: PosTokens.s8,
            ),
            child: Row(
              children: [
                Icon(Icons.cloud_off, size: 18, color: t.warning),
                const SizedBox(width: PosTokens.s8),
                const Expanded(child: Text(message)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Server reachability, from the API client's last request (not a system
/// connectivity check).
class NetworkStatusChip extends StatelessWidget {
  const NetworkStatusChip({super.key, this.reachable, this.showLabel = true});
  final ValueListenable<bool?>? reachable;

  /// The phone app bar shows just the colored dot.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final source = reachable;
    if (source == null) return const SizedBox.shrink();
    final t = PosTokens.of(context);
    return ValueListenableBuilder<bool?>(
      valueListenable: source,
      builder: (context, ok, _) {
        final (label, color) = switch (ok) {
          true => ('Online', t.success),
          false => ('Offline', t.warning),
          null => ('Connecting', Theme.of(context).colorScheme.outline),
        };
        return Semantics(
          label: 'Server status: $label',
          child: ExcludeSemantics(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                if (showLabel) ...[
                  const SizedBox(width: 6),
                  Text(label, style: Theme.of(context).textTheme.bodyMedium),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String formatClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${_weekdays[t.weekday - 1]}, ${t.day} ${_months[t.month - 1]} · ${two(t.hour)}:${two(t.minute)}';
}

/// Local date and time, refreshed every 30 seconds (cheap; no per-second
/// rebuilds on a POS device).
class ClockText extends StatefulWidget {
  const ClockText({super.key, this.now});
  final DateTime Function()? now;

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;
  late DateTime _t;

  DateTime _read() => (widget.now ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    _t = _read();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _t = _read());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(formatClock(_t), style: Theme.of(context).textTheme.bodyMedium);
  }
}
