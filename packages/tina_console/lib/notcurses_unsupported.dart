/// The no-`dart:io` variant of the notcurses barrel (wasm compilation):
/// a shape-compatible stub extending [TerminalBackend]. Every operation
/// refuses loudly — a wiring bug, since the guest runs the ANSI backend
/// only — while app-level `is NotcursesBackend` checks compile and are
/// simply always false, making every native-backend branch dead code.
library;

import 'dart:typed_data';

import 'src/backend/backend_surface.dart';
import 'src/backend/terminal_backend.dart';
import 'src/rect.dart';
import 'src/stdio.dart';

/// Stub standing in for the FFI [NotcursesBackend] under wasm.
final class NotcursesBackend extends TerminalBackend {
  NotcursesBackend._();

  /// Never succeeds under wasm: the host owns the terminal and the guest
  /// runs the ANSI backend. Reaching this is a wiring bug.
  static Never create({required Stdio io, bool mouseWheel = false}) =>
      throw UnsupportedError(
          'notcurses is a native-only backend; the wasm guest runs ANSI');

  Never createInputBackend() => throw UnsupportedError(
      'notcurses is a native-only backend; the wasm guest runs ANSI');

  @override
  Never moveCursor(int row, int col) => _refuse();

  @override
  Never eraseCells(int row, int col, int n) => _refuse();

  @override
  Never writeText(String text) => _refuse();

  @override
  Never saveCursor() => _refuse();

  @override
  Never restoreCursor() => _refuse();

  @override
  Never flush() => _refuse();

  @override
  Never enterAltScreen() => _refuse();

  @override
  Never leaveAltScreen() => _refuse();

  @override
  Never enableBracketedPaste() => _refuse();

  @override
  Never disableBracketedPaste() => _refuse();

  @override
  bool get supportsColor => false;

  @override
  String colorize(String code, String text) => text;

  @override
  Never get stdin => _refuse();

  @override
  int get terminalColumns => 80;

  @override
  Never renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) =>
      _refuse();

  @override
  Never createSurface(Rect bounds) => _refuse();

  @override
  bool get coalescesPaints => false;

  static Never _refuse() => throw UnsupportedError(
      'notcurses is a native-only backend; the wasm guest runs ANSI');
}
