import 'package:tina_console/tina_console.dart';
import 'theme_overrides.dart';

/// Resolve plain stored values using the existing console defaults and parsing.
Theme themeFromOverrides(ThemeOverrides? overrides) =>
    Theme.fromMap(overrides?.toMap());
