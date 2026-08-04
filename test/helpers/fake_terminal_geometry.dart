import 'package:tina/platform/terminal_geometry.dart';

/// A [TerminalGeometry] with fixed, overrideable dimensions, for tests that
/// need a deterministic terminal size without touching [stdout].
class FakeTerminalGeometry implements TerminalGeometry {
  @override
  final int columns;
  @override
  final int lines;
  @override
  final bool hasTerminal;

  const FakeTerminalGeometry({
    this.columns = 80,
    this.lines = 24,
    this.hasTerminal = true,
  });
}
