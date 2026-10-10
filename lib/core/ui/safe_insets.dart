import 'package:flutter/widgets.dart';

/// Phase 16B — keeps a bottom sheet's content (its last row, its action
/// buttons) above the bottom system inset: Android navigation / gesture bar,
/// iOS home indicator.
///
/// `showModalBottomSheet(useSafeArea: true)` only avoids the TOP and the
/// sides (Flutter wraps the sheet in `SafeArea(bottom: false)`), so a sheet
/// that runs to the bottom of the screen needs this inside it. Place it
/// INSIDE any fixed-height box, so the sheet never grows taller than before.
///
/// While the keyboard is up Flutter reports no bottom padding (the keyboard
/// already covers that area), so this never adds a gap above the keyboard.
class SheetSafeArea extends StatelessWidget {
  const SheetSafeArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => SafeArea(top: false, child: child);
}
