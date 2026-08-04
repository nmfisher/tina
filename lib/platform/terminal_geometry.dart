import 'dart:io';

/// Terminal dimensions behind an interface, so tests can supply fixed
/// dimensions via a fake instead of touching [stdout]. Kept separate from
/// [Environment] (env vars vs. live geometry) so a test that only needs env
/// vars doesn't have to fake a terminal size too. Production uses
/// [StdoutTerminalGeometry].
abstract class TerminalGeometry {
  int get columns;
  int get lines;
  bool get hasTerminal;
}

/// [TerminalGeometry] backed by [stdout]. Reads live, so a resize handler
/// reading [columns]/[lines] sees the new size.
class StdoutTerminalGeometry implements TerminalGeometry {
  const StdoutTerminalGeometry();

  @override
  int get columns => stdout.terminalColumns;

  @override
  int get lines => stdout.terminalLines;

  @override
  bool get hasTerminal => stdout.hasTerminal;
}
