/// The no-`dart:io` variant of the [Stdio] seam, selected by `stdio.dart`
/// under the wasm compilation (where `dart:io` does not exist).
///
/// The interface is identical to the native one; the composition root
/// injects its WASI-backed implementation. `LiveStdio` reaching a wasm run
/// is a wiring bug, and `ProcessSignal` is a shape-compatible stub (the
/// host owns signals; a guest never watches one).
library;

import 'dart:async';

/// Stub standing in for `dart:io`'s [ProcessSignal] under wasm: same name,
/// same members the console reads, never delivered (the host owns signals).
enum ProcessSignal { sighup, sigint, sigquit, sigill, sigtrap, sigabrt, sigwinch, sigterm, sigusr1, sigusr2 }

/// Narrow interface over stdin/stdout and signal watching. Lets tests inject
/// a fake that accumulates output and pumps synthetic input without touching
/// the real terminal.
abstract class Stdio {
  Stream<List<int>> get stdin;
  void write(String s);
  int get terminalColumns;
  int get terminalLines;
  bool get hasTerminal;
  bool get stdinHasTerminal;
  bool get echoMode;
  bool get lineMode;
  void setEchoMode(bool value);
  void setLineMode(bool value);

  /// Watch a process signal. Empty under wasm: signals are host-owned.
  Stream<ProcessSignal> watchSignal(ProcessSignal s);
}

/// Production `dart:io` implementation. Under wasm there is no `dart:io`:
/// constructing this is a wiring bug (the composition root injects the
/// WASI-backed [Stdio] instead).
class LiveStdio implements Stdio {
  const LiveStdio();

  @override
  Stream<List<int>> get stdin => throw UnsupportedError(
      'no dart:io stdin on this platform: inject a Stdio implementation');

  @override
  void write(String s) => throw UnsupportedError(
      'no dart:io stdout on this platform: inject a Stdio implementation');

  @override
  int get terminalColumns =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  int get terminalLines =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  bool get hasTerminal =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  bool get stdinHasTerminal =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  bool get echoMode =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  bool get lineMode =>
      throw UnsupportedError('no dart:io terminal on this platform');

  @override
  void setEchoMode(bool value) => throw UnsupportedError(
      'no dart:io terminal on this platform');

  @override
  void setLineMode(bool value) => throw UnsupportedError(
      'no dart:io terminal on this platform');

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) =>
      throw UnsupportedError('no dart:io signals on this platform');
}
