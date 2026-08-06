import 'package:flutter/material.dart';

/// Design tokens shared with the web dashboard: a green-dominant palette
/// derived from the AlgaGuard shield logo, with navy demoted to a secondary
/// accent. Mirrors algaguard-web-dashboard/src/styles.css's :root tokens.
abstract final class AlgaGuardColors {
  static const navy50 = Color(0xffeff4f8);
  static const navy100 = Color(0xffdce6ee);
  static const navy200 = Color(0xffb7ccdc);
  static const navy300 = Color(0xff8caec6);
  static const navy400 = Color(0xff5d87a3);
  static const navy700 = Color(0xff1b384d);
  static const navy800 = Color(0xff10283a);
  static const navy900 = Color(0xff081b28);
  static const green50 = Color(0xffeaf7ef);
  static const green100 = Color(0xffd3eedd);
  static const green300 = Color(0xff7bc796);
  static const green400 = Color(0xff4fae73);
  static const green500 = Color(0xff2f8f57);
  static const green700 = Color(0xff1b5e38);
  static const green800 = Color(0xff144a2c);
  static const green900 = Color(0xff0d3320);
  static const gray50 = Color(0xfff7f9fa);
  static const gray200 = Color(0xffdee5e9);
  static const gray300 = Color(0xffc3ced4);
  static const gray600 = Color(0xff54636c);
  static const statusCritical = Color(0xffd03b3b);
  static const statusWarning = Color(0xfffab219);
  static const statusGood = Color(0xff0ca30c);
  static const purple50 = Color(0xfff4effc);
  static const purple500 = Color(0xff7c4fd6);
  static const purple700 = Color(0xff5b32ad);

}

/// Six telemetry-parameter icon colors, validated with the dataviz skill's
/// validate_palette.js against both this theme's light and dark surfaces.
/// Mirrors algaguard-web-dashboard/src/styles.css's --param-*-fg tokens
/// (light) and their dark-mode overrides. Never reuse purple here -- it is
/// reserved for the simulated/dev-data convention, see simulated_badge.dart.
/// Look up via `Theme.of(context).extension<ParamColors>()!`.
@immutable
class ParamColors extends ThemeExtension<ParamColors> {
  const ParamColors({
    required this.temperature,
    required this.ph,
    required this.light,
    required this.nitrate,
    required this.phosphate,
    required this.potassium,
  });

  static const light_ = ParamColors(
    temperature: Color(0xffeb6834),
    ph: Color(0xff2a78d6),
    light: Color(0xffeda100),
    nitrate: Color(0xff1baf7a),
    phosphate: Color(0xffe87ba4),
    potassium: Color(0xff4a3aa7),
  );

  static const dark_ = ParamColors(
    temperature: Color(0xffd95926),
    ph: Color(0xff3987e5),
    light: Color(0xffc98500),
    nitrate: Color(0xff199e70),
    phosphate: Color(0xffd55181),
    potassium: Color(0xff9085e9),
  );

  final Color temperature;
  final Color ph;
  final Color light;
  final Color nitrate;
  final Color phosphate;
  final Color potassium;

  /// The pastel circle background behind an icon of [fg], blended toward
  /// [surface] the same way the web dashboard computes it via CSS color-mix.
  static Color circleBackground(Color fg, Color surface) =>
      Color.lerp(surface, fg, 0.18)!;

  @override
  ParamColors copyWith({
    Color? temperature,
    Color? ph,
    Color? light,
    Color? nitrate,
    Color? phosphate,
    Color? potassium,
  }) => ParamColors(
    temperature: temperature ?? this.temperature,
    ph: ph ?? this.ph,
    light: light ?? this.light,
    nitrate: nitrate ?? this.nitrate,
    phosphate: phosphate ?? this.phosphate,
    potassium: potassium ?? this.potassium,
  );

  @override
  ParamColors lerp(ThemeExtension<ParamColors>? other, double t) {
    if (other is! ParamColors) return this;
    return ParamColors(
      temperature: Color.lerp(temperature, other.temperature, t)!,
      ph: Color.lerp(ph, other.ph, t)!,
      light: Color.lerp(light, other.light, t)!,
      nitrate: Color.lerp(nitrate, other.nitrate, t)!,
      phosphate: Color.lerp(phosphate, other.phosphate, t)!,
      potassium: Color.lerp(potassium, other.potassium, t)!,
    );
  }
}

abstract final class AppTheme {
  static ThemeData get light => _build(
    ColorScheme(
      brightness: Brightness.light,
      primary: AlgaGuardColors.green700,
      onPrimary: Colors.white,
      secondary: AlgaGuardColors.navy700,
      onSecondary: Colors.white,
      surface: Colors.white,
      onSurface: AlgaGuardColors.navy900,
      surfaceContainerHighest: AlgaGuardColors.gray50,
      error: AlgaGuardColors.statusCritical,
      onError: Colors.white,
      outline: AlgaGuardColors.gray300,
    ),
    scaffoldBackground: AlgaGuardColors.green50,
    appBarBackground: AlgaGuardColors.green800,
    navigationIndicator: AlgaGuardColors.green100,
    paramColors: ParamColors.light_,
  );

  static ThemeData get dark => _build(
    ColorScheme(
      brightness: Brightness.dark,
      primary: AlgaGuardColors.green300,
      onPrimary: AlgaGuardColors.green900,
      secondary: AlgaGuardColors.navy300,
      onSecondary: AlgaGuardColors.navy900,
      surface: const Color(0xff13201a),
      onSurface: Colors.white,
      surfaceContainerHighest: const Color(0xff182920),
      error: AlgaGuardColors.statusCritical,
      onError: Colors.white,
      outline: const Color(0x33ffffff),
    ),
    scaffoldBackground: const Color(0xff0b1611),
    appBarBackground: const Color(0xff081209),
    navigationIndicator: AlgaGuardColors.green700,
    paramColors: ParamColors.dark_,
  );

  static ThemeData _build(
    ColorScheme scheme, {
    required Color scaffoldBackground,
    required Color appBarBackground,
    required Color navigationIndicator,
    required ParamColors paramColors,
  }) {
    final radius = BorderRadius.circular(18);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffoldBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: appBarBackground,
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
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: navigationIndicator,
        elevation: 0,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 12,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurface,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? scheme.primary
                : scheme.onSurface,
          ),
        ),
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
      extensions: [paramColors],
    );
  }
}
