import 'package:flutter/material.dart';

/// Width classes for the POS shell. The 900 dp boundary is the same one the app
/// has always used to decide between a bottom cart (phone / small tablet
/// portrait) and a side cart (tablet).
enum PosLayoutClass {
  /// < 900: compact app bar + drawer, product grid, bottom cart bar + sheet.
  compact,

  /// 900–1279: icon-only navigation rail, products, side cart.
  medium,

  /// 1280–1599: full sidebar, products, side cart.
  expanded,

  /// >= 1600: adds the sales summary column.
  wide;

  static PosLayoutClass forWidth(double width) {
    if (width < 900) return PosLayoutClass.compact;
    if (width < 1280) return PosLayoutClass.medium;
    if (width < 1600) return PosLayoutClass.expanded;
    return PosLayoutClass.wide;
  }

  bool get isCompact => this == PosLayoutClass.compact;
  bool get hasSideCart => this != PosLayoutClass.compact;
  bool get hasFullSidebar =>
      this == PosLayoutClass.expanded || this == PosLayoutClass.wide;
  bool get hasSummary => this == PosLayoutClass.wide;

  double get sideCartWidth => this == PosLayoutClass.medium ? 360 : 400;
}

/// Rebuilds with the current [PosLayoutClass]. Uses the window width (not the
/// parent's), so nested widgets agree on the layout.
class ResponsivePosLayout extends StatelessWidget {
  const ResponsivePosLayout({super.key, required this.builder});

  final Widget Function(BuildContext context, PosLayoutClass layout) builder;

  @override
  Widget build(BuildContext context) {
    return builder(
      context,
      PosLayoutClass.forWidth(MediaQuery.sizeOf(context).width),
    );
  }
}
