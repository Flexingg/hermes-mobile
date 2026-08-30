import 'dart:ui' show lerpDouble;
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';

/// ThemeMode preference.
enum ThemePreference { system, light, dark }

/// List / control density.
enum UiDensity { comfortable, compact }

/// Corner rounding for cards, chips, and bubbles.
enum CornerRadius { standard, sharp, rounded }

/// Sent-chat-bubble color style.
enum BubbleStyle { theme, green, blue }

/// Bubble colors resolved from [BubbleStyle] + brightness.
(Color, Color) bubbleColors(BubbleStyle style, Brightness brightness) {
  final dark = brightness == Brightness.dark;
  switch (style) {
    case BubbleStyle.blue:
      return dark
          ? (const Color(0xFF1E6BD6), Colors.white)
          : (const Color(0xFFBBDEFB), const Color(0xFF001C3D));
    case BubbleStyle.theme:
    case BubbleStyle.green:
      return dark
          ? (const Color(0xFF2E7D5B), Colors.white)
          : (const Color(0xFFE7FEDB), const Color(0xFF001C06));
  }
}

/// Extra theme tokens the app's widgets read (chat bubble colors).
class HermesColors extends ThemeExtension<HermesColors> {
  final Color sentBubble;
  final Color sentBubbleText;
  final Color receivedBubble;
  final double bubbleRadius;
  const HermesColors({
    required this.sentBubble,
    required this.sentBubbleText,
    required this.receivedBubble,
    this.bubbleRadius = 18,
  });

  @override
  HermesColors copyWith({
    Color? sentBubble,
    Color? sentBubbleText,
    Color? receivedBubble,
    double? bubbleRadius,
  }) {
    return HermesColors(
      sentBubble: sentBubble ?? this.sentBubble,
      sentBubbleText: sentBubbleText ?? this.sentBubbleText,
      receivedBubble: receivedBubble ?? this.receivedBubble,
      bubbleRadius: bubbleRadius ?? this.bubbleRadius,
    );
  }

  @override
  HermesColors lerp(ThemeExtension<HermesColors>? other, double t) {
    if (other is! HermesColors) return this;
    return HermesColors(
      sentBubble: Color.lerp(sentBubble, other.sentBubble, t)!,
      sentBubbleText: Color.lerp(sentBubbleText, other.sentBubbleText, t)!,
      receivedBubble: Color.lerp(receivedBubble, other.receivedBubble, t)!,
      bubbleRadius: lerpDouble(bubbleRadius, other.bubbleRadius, t) ?? bubbleRadius,
    );
  }
}

double _cardRadius(CornerRadius r) {
  switch (r) {
    case CornerRadius.sharp:
      return 8;
    case CornerRadius.rounded:
      return 28;
    case CornerRadius.standard:
      return 20;
  }
}

double _bubbleRadius(CornerRadius r) {
  switch (r) {
    case CornerRadius.sharp:
      return 6;
    case CornerRadius.rounded:
      return 24;
    case CornerRadius.standard:
      return 18;
  }
}

/// Builds the app's Material 3 theme with Material You dynamic color.
class AppTheme {
  static ColorScheme _buildScheme(Color seed, Brightness brightness) {
    return ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
    );
  }

  static ThemeData _buildTheme(
    ColorScheme scheme,
    Brightness brightness, {
    UiDensity density = UiDensity.comfortable,
    CornerRadius radius = CornerRadius.standard,
    BubbleStyle bubble = BubbleStyle.green,
  }) {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      brightness: brightness,
      splashFactory: InkSparkle.splashFactory,
    );

    final (sent, sentText) = bubbleColors(bubble, brightness);
    final received =
        brightness == Brightness.dark ? scheme.surfaceContainerHighest : Colors.white;
    final radiusV = _cardRadius(radius);
    final bubbleV = _bubbleRadius(radius);
    final visual = density == UiDensity.compact
        ? VisualDensity.compact
        : VisualDensity.standard;

    return base.copyWith(
      visualDensity: visual,
      scaffoldBackgroundColor: scheme.surface,
      extensions: [
        HermesColors(
          sentBubble: sent,
          sentBubbleText: sentText,
          receivedBubble: received,
          bubbleRadius: bubbleV,
        ),
      ],
      cardTheme: CardThemeData(
        elevation: 0,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusV))),
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
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusV * 0.8))),
      ),
      chipTheme: base.chipTheme.copyWith(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusV * 0.5))),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(radiusV * 0.6))),
      ),
      searchBarTheme: SearchBarThemeData(
        elevation: const WidgetStatePropertyAll(0),
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(28))),
      ),
    );
  }

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
    UiDensity density = UiDensity.comfortable,
    CornerRadius radius = CornerRadius.standard,
    BubbleStyle bubble = BubbleStyle.green,
  }) {
    return _buildTheme(
      _scheme(
        brightness: Brightness.light,
        dynamicScheme: dynamicScheme,
        seedOverride: seedOverride,
      ),
      Brightness.light,
      density: density,
      radius: radius,
      bubble: bubble,
    );
  }

  static ThemeData dark({
    ColorScheme? dynamicScheme,
    Color? seedOverride,
    UiDensity density = UiDensity.comfortable,
    CornerRadius radius = CornerRadius.standard,
    BubbleStyle bubble = BubbleStyle.green,
  }) {
    return _buildTheme(
      _scheme(
        brightness: Brightness.dark,
        dynamicScheme: dynamicScheme,
        seedOverride: seedOverride,
      ),
      Brightness.dark,
      density: density,
      radius: radius,
      bubble: bubble,
    );
  }

  /// Wraps a child with [DynamicColorBuilder] to capture the wallpaper palette.
  static Widget builder(
      Widget Function(ColorScheme? light, ColorScheme? dark) child) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) => child(lightDynamic, darkDynamic),
    );
  }
}
