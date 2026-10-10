/// Phase 18A — the scale's place in the POS: a small panel inside the
/// existing weight dialog (lib/features/cart/ui/quantity_dialog.dart).
///
/// "Use scale weight" only FILLS the dialog's weight field with a stable,
/// valid reading converted to kg; the cashier still confirms with the
/// dialog's own button, and Cancel discards it. A reading arriving never
/// selects a product, changes a cart line or submits anything. Without a
/// scale (no [ScaleScope]) the dialog is exactly the manual one.
library;

import 'package:flutter/material.dart';

import '../scale_adapter.dart';
import '../scale_controller.dart';

/// Makes a configured scale available to the weight dialog. Absent = no scale.
class ScaleScope extends InheritedWidget {
  const ScaleScope({super.key, required this.controller, required super.child});

  final ScaleController controller;

  static ScaleController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ScaleScope>()?.controller;

  @override
  bool updateShouldNotify(ScaleScope oldWidget) =>
      controller != oldWidget.controller;
}

class ScaleWeightPanel extends StatefulWidget {
  const ScaleWeightPanel({
    super.key,
    required this.controller,
    required this.onUseWeight,
  });

  final ScaleController controller;

  /// Receives the kg text ("1.250") to put in the weight field.
  final ValueChanged<String> onUseWeight;

  @override
  State<ScaleWeightPanel> createState() => _ScaleWeightPanelState();
}

class _ScaleWeightPanelState extends State<ScaleWeightPanel> {
  @override
  void initState() {
    super.initState();
    // Connect in the background (after this frame, so no listener is
    // notified mid-build); manual entry works meanwhile and afterwards.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.controller.connect();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final c = widget.controller;
        final weight = c.saleWeight;
        final reading = c.reading;
        final String status = switch (c.connectionState) {
          ScaleConnectionState.connecting => 'Connecting…',
          ScaleConnectionState.connected =>
            reading == null
                ? 'Waiting for a reading…'
                : 'Reading ${reading.displayText}${reading.isStable ? '' : ' (settling)'}',
          ScaleConnectionState.error ||
          ScaleConnectionState.disconnected => 'Not connected',
        };
        final hint =
            c.error ?? (c.isConnected && !weight.isOk ? weight.problem : null);
        return Container(
          key: const Key('scale-panel'),
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            border: Border.all(color: theme.colorScheme.outlineVariant),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.scale_outlined, size: 18),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      c.isSimulated ? '${c.name} (not a real scale)' : c.name,
                      style: theme.textTheme.labelLarge,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(status, key: const Key('scale-status')),
              if (hint != null)
                Text(
                  hint,
                  key: const Key('scale-hint'),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  FilledButton.tonal(
                    key: const Key('scale-use'),
                    onPressed: weight.isOk
                        ? () => widget.onUseWeight(weight.text!)
                        : null,
                    child: Text(
                      weight.isOk
                          ? 'Use ${weight.text} kg'
                          : 'Use scale weight',
                    ),
                  ),
                  if (!c.isConnected &&
                      c.connectionState != ScaleConnectionState.connecting)
                    TextButton(
                      key: const Key('scale-connect'),
                      onPressed: c.connect,
                      child: const Text('Connect'),
                    ),
                  if (c.isConnected && c.capabilities.canZero)
                    TextButton(
                      key: const Key('scale-zero'),
                      onPressed: c.zero,
                      child: const Text('Zero'),
                    ),
                  if (c.isConnected && c.capabilities.canTare)
                    TextButton(
                      key: const Key('scale-tare'),
                      onPressed: c.tare,
                      child: const Text('Tare'),
                    ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}
