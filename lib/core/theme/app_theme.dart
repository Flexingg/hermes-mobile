import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

/// ThemeMode preference.
enum ThemePreference { system, light, dark }

/// Builds the app's Material 3 theme with Material You dynamic color.
class AppTheme {
  /// Google Messages uses a green accent for "sent" messages and a grey for
  /// incoming. We derive the palette from the dynamic seed when available,
  /// otherwise fall back to a seed color.
  static ColorScheme _buildScheme(Color seed, Brightness brightness) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
  }

  // Material Expressive-style rounded shape.
  static const ShapeBorder _cardShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(20)),
  );

  static ThemeData _buildTheme(ColorScheme scheme, Brightness brightness) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      splashFactory: InkSparkle.splashFactory, // Material Expressive sparkle
    );

    return base.copyWith(
      scaffoldBackgroundColor: scheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        shape: _cardShape,
        color: scheme.surfaceContainerLow,
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: scheme.surface,
        selectedItemColor: scheme.primary,
        unselectedItemColor: scheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        elevation: 0,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHighest,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(28),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surface,
        indicatorColor: scheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
      ),
    );
  }

  /// Resolve the effective ColorScheme from the system [dynamicScheme] (from
  /// Android wallpaper) and the user's preferred [seedColor] override.
  static ColorScheme _scheme({
    required Brightness brightness,
    required ColorScheme? dynamicScheme,
    required Color? seedOverride,
  }) {
    if (seedOverride != null) return _buildScheme(seedOverride, brightness);
    if (dynamicScheme != null) return dynamicScheme;
    return _buildScheme(const Color(0xFF6750A4), brightness);
  }

  static ThemeData light({
    ColorScheme? dynamicScheme,
    Color? seedOverride,
  }) {
    final scheme = _scheme(
      brightness: Brightness.light,
      dynamicScheme: dynamicScheme,
      seedOverride: seedOverride,
    );
    return _buildTheme(scheme, Brightness.light);
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    Color? seedOverride,
  }) {
    final scheme = _scheme(
      brightness: Brightness.dark,
      dynamicScheme: dynamicScheme,
      seedOverride: seedOverride,
    );
    return _buildTheme(scheme, Brightness.dark);
  }

  /// Wraps a child with [DynamicColorBuilder] to capture the wallpaper palette.
  static Widget builder(Widget Function(ColorScheme? light, ColorScheme? dark) child) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => child(lightDynamic, darkDynamic),
    );
  }
}
