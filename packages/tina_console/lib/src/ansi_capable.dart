import 'dart:io';

/// Immutable record of whether ANSI escape sequences should be emitted.
/// Separated from raw-mode concerns (which control `\r\n` translation).
///
/// Constructed once at startup via [detect] or forced to a known value via
/// [AnsiCapable.yes] / [AnsiCapable.no].
class AnsiCapable {
  final bool useColor;

  const AnsiCapable._(this.useColor);

  /// Detect from the real environment. Checks `NO_COLOR`, `TERM=dumb`, and
  /// `stdout.supportsAnsiEscapes`.
  factory AnsiCapable.detect() {
    if (Platform.environment.containsKey('NO_COLOR')) {
      return const AnsiCapable._(false);
    }
    final term = Platform.environment['TERM'];
    if (term == 'dumb') {
      return const AnsiCapable._(false);
    }
    try {
      if (!stdout.supportsAnsiEscapes) {
        return const AnsiCapable._(false);
      }
    } catch (_) {
      return const AnsiCapable._(false);
    }
    return const AnsiCapable._(true);
  }

  /// Force colour on (for tests or explicit opt-in).
  static const AnsiCapable yes = AnsiCapable._(true);

  /// Force colour off.
  static const AnsiCapable no = AnsiCapable._(false);
}
