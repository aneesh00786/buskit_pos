import 'package:flutter/material.dart';

import 'pos_tokens.dart';

/// Light and dark themes built from the same seed and the [PosTokens] palette.
class AppTheme {
  static const Color seed = Color(0xFF16A34A);

  static ThemeData light() => _build(Brightness.light, PosTokens.light);
  static ThemeData dark() => _build(Brightness.dark, PosTokens.dark);

  static ThemeData _build(Brightness brightness, PosTokens t) {
    // Green primary actions (Add, Pay, selected chips) come straight from the tokens.
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
    ).copyWith(primary: t.success, onPrimary: t.onSuccess);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      brightness: brightness,
    );
    final text = base.textTheme;
    return base.copyWith(
      extensions: [t],
      scaffoldBackgroundColor: t.canvas,
      visualDensity: VisualDensity.standard,
      materialTapTargetSize: MaterialTapTargetSize.padded,
      textTheme: text.copyWith(
        titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        titleSmall: text.titleSmall?.copyWith(fontWeight: FontWeight.w600),
      ),
      cardTheme: CardThemeData(
        color: t.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PosTokens.rCard),
          side: BorderSide(color: t.border),
        ),
      ),
      dividerTheme: DividerThemeData(color: t.border, space: 1, thickness: 1),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, 48),
          side: BorderSide(color: t.border),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PosTokens.rSmall + 2),
          ),
        ),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PosTokens.rPill),
        ),
        side: BorderSide(color: t.border),
      ),
      snackBarTheme: SnackBarThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PosTokens.rSmall),
        ),
      ),
      drawerTheme: DrawerThemeData(backgroundColor: t.sidebar),
    );
  }
}
