import 'package:flutter/material.dart';

/// Design tokens shared with the web dashboard: a navy/green palette
/// derived from the AlgaGuard shield logo, "clean & clinical" tone.
abstract final class AlgaGuardColors {
  static const navy50 = Color(0xffeff4f8);
  static const navy100 = Color(0xffdce6ee);
  static const navy200 = Color(0xffb7ccdc);
  static const navy300 = Color(0xff8caec6);
  static const navy400 = Color(0xff5d87a3);
  static const navy700 = Color(0xff1b384d);
  static const navy800 = Color(0xff10283a);
  static const navy900 = Color(0xff081b28);
  static const green300 = Color(0xff93be6c);
  static const green500 = Color(0xff55882f);
  static const gray50 = Color(0xfff7f9fa);
  static const gray200 = Color(0xffdee5e9);
  static const gray300 = Color(0xffc3ced4);
  static const gray600 = Color(0xff54636c);
  static const statusCritical = Color(0xffd03b3b);
  static const statusWarning = Color(0xfffab219);
  static const statusGood = Color(0xff0ca30c);
}

abstract final class AppTheme {
  static ThemeData get light => _build(
    ColorScheme(
      brightness: Brightness.light,
      primary: AlgaGuardColors.navy700,
      onPrimary: Colors.white,
      secondary: AlgaGuardColors.green500,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: AlgaGuardColors.navy900,
      surfaceContainerHighest: AlgaGuardColors.gray50,
      error: AlgaGuardColors.statusCritical,
      onError: Colors.white,
      outline: AlgaGuardColors.gray300,
    ),
    scaffoldBackground: AlgaGuardColors.gray50,
  );

  static ThemeData get dark => _build(
    ColorScheme(
      brightness: Brightness.dark,
      primary: AlgaGuardColors.navy300,
      onPrimary: AlgaGuardColors.navy900,
      secondary: AlgaGuardColors.green300,
      onSecondary: AlgaGuardColors.navy900,
      surface: const Color(0xff131b22),
      onSurface: Colors.white,
      surfaceContainerHighest: const Color(0xff182029),
      error: AlgaGuardColors.statusCritical,
      onError: Colors.white,
      outline: const Color(0x33ffffff),
    ),
    scaffoldBackground: const Color(0xff0b1116),
  );

  static ThemeData _build(
    ColorScheme scheme, {
    required Color scaffoldBackground,
  }) {
    final radius = BorderRadius.circular(12);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: AlgaGuardColors.navy900,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: radius,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHighest,
        labelStyle: TextStyle(color: scheme.onSurface),
        side: BorderSide(color: scheme.outline),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: scheme.primary,
          side: BorderSide(color: scheme.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: scheme.primary),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
      ),
      listTileTheme: ListTileThemeData(iconColor: scheme.primary),
    );
  }
}
