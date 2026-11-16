import 'package:flutter/material.dart';

/// Material 3 theme modelled on the LunarisDolby reference app: an indigo
/// primary with slate/amber accents, dark `#131318` surfaces, and large
/// rounded "extra-large" cards.
abstract final class AppTheme {
  static const _indigo = Color(0xFF4B4FCF);
  static const _amber = Color(0xFF7A5900);

  /// Corner radii used across the app.
  static const radiusCard = 28.0;
  static const radiusTile = 20.0;
  static const radiusChip = 14.0;

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _indigo,
      brightness: brightness,
      tertiary: _amber,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      scaffoldBackgroundColor: scheme.surface,
      splashFactory: InkSparkle.splashFactory,
      cardTheme: CardThemeData(
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusCard)),
        ),
        margin: EdgeInsets.zero,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(radiusTile)),
        ),
      ),
    );
  }

  static ThemeData get light => _base(Brightness.light);
  static ThemeData get dark => _base(Brightness.dark);
}

extension ContextTheme on BuildContext {
  ColorScheme get colors => Theme.of(this).colorScheme;
  TextTheme get texts => Theme.of(this).textTheme;
}
