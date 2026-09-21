import 'package:flutter/material.dart';

/// Design tokens shared by every POS widget: spacing, radii, elevation and the
/// handful of semantic colors that are not part of Material's ColorScheme.
/// Widgets read them through `PosTokens.of(context)` so light and dark themes
/// stay consistent.
@immutable
class PosTokens extends ThemeExtension<PosTokens> {
  const PosTokens({
    required this.canvas,
    required this.surface,
    required this.surfaceMuted,
    required this.border,
    required this.success,
    required this.onSuccess,
    required this.warning,
    required this.danger,
    required this.onDanger,
    required this.sidebar,
    required this.onSidebar,
    required this.shadow,
    required this.heroGradient,
  });

  final Color canvas; // page background behind cards
  final Color surface; // cards
  final Color surfaceMuted; // image placeholders, chips at rest
  final Color border;
  final Color success; // Add buttons, "in stock"
  final Color onSuccess;
  final Color warning; // low / out of stock
  final Color danger; // Hold, destructive emphasis
  final Color onDanger;
  final Color sidebar; // dark navy/teal navigation background (both themes)
  final Color onSidebar;
  final Color shadow;
  final List<Color> heroGradient;

  // Spacing scale (dp).
  static const double s4 = 4;
  static const double s8 = 8;
  static const double s12 = 12;
  static const double s16 = 16;
  static const double s24 = 24;

  // Radii.
  static const double rSmall = 10;
  static const double rCard = 16;
  static const double rPill = 999;

  static const light = PosTokens(
    canvas: Color(0xFFF4F5F7),
    surface: Colors.white,
    surfaceMuted: Color(0xFFEDEFF2),
    border: Color(0xFFE3E6EA),
    success: Color(0xFF16A34A),
    onSuccess: Colors.white,
    warning: Color(0xFFD97706),
    danger: Color(0xFFDC2626),
    onDanger: Colors.white,
    sidebar: Color(0xFF0E2A36),
    onSidebar: Color(0xFFE6F0F2),
    shadow: Color(0x14000000),
    heroGradient: [Color(0xFF0F766E), Color(0xFF16A34A)],
  );

  static const dark = PosTokens(
    canvas: Color(0xFF0F1214),
    surface: Color(0xFF181C1F),
    surfaceMuted: Color(0xFF23282C),
    border: Color(0xFF2B3136),
    success: Color(0xFF22C55E),
    onSuccess: Color(0xFF052E16),
    warning: Color(0xFFF59E0B),
    danger: Color(0xFFEF4444),
    onDanger: Colors.white,
    sidebar: Color(0xFF08191F),
    onSidebar: Color(0xFFE5E7EB),
    shadow: Color(0x66000000),
    heroGradient: [Color(0xFF115E59), Color(0xFF15803D)],
  );

  static PosTokens of(BuildContext context) =>
      Theme.of(context).extension<PosTokens>() ?? light;

  /// Subtle card shadow used across the app.
  List<BoxShadow> get cardShadow => [
    BoxShadow(color: shadow, blurRadius: 12, offset: const Offset(0, 4)),
  ];

  BoxDecoration card({
    Color? color,
    double radius = rCard,
    bool outlined = true,
  }) => BoxDecoration(
    color: color ?? surface,
    borderRadius: BorderRadius.circular(radius),
    border: outlined ? Border.all(color: border) : null,
    boxShadow: cardShadow,
  );

  @override
  PosTokens copyWith() => this;

  @override
  PosTokens lerp(ThemeExtension<PosTokens>? other, double t) =>
      other is PosTokens ? (t < 0.5 ? this : other) : this;
}
