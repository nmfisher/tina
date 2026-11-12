/// The `dart:io` variant of the [Stdio] seam: the native behavior,
/// unchanged. Selected by `stdio.dart` where `dart:io` exists.
library;

import 'dart:async';
import 'dart:io' as io;

// Re-export the types that appear in the public API so consumers don't need
// their own dart:io import.
export 'dart:io' show ProcessSignal;

/// Narrow interface over stdin/stdout and signal watching. Lets tests inject
/// a fake that accumulates output and pumps synthetic input without touching
/// the real terminal.
abstract class Stdio {
  Stream<List<int>> get stdin;
  void write(String s);
  int get terminalColumns;

  /// Terminal rows (the height half of the window size).
  int get terminalLines;
  bool get hasTerminal;

  /// Whether stdin is a terminal (Stdin.hasTerminal natively; under wasm the
  /// terminal instance answers honestly).
  bool get stdinHasTerminal;

  /// stdin's current echo mode (read before the app disables it so it can be
  /// restored on teardown).
  bool get echoMode;

  /// stdin's current line mode.
  bool get lineMode;
  void setEchoMode(bool value);
  void setLineMode(bool value);

  /// Watch a process signal (e.g. SIGWINCH). Returns an empty stream on
  /// platforms that don't support the signal.
  Stream<io.ProcessSignal> watchSignal(io.ProcessSignal s);
}

/// Lazily-initialised broadcast relay for [io.stdin].
///
/// [io.stdin] is a single-subscription stream — once someone listens to it
/// (e.g. [probeTerminalBg] via `.first`) no other subscriber can attach.
/// This relay subscribes once and fans out to any number of consumers so that
/// the OSC-11 background probe and the [AnsiInputBackend] can both work.
Stream<List<int>> get _sharedStdin {
  final c = _stdinRelayController;
  if (c != null) return c.stream;
  final controller = StreamController<List<int>>.broadcast(sync: true);
  io.stdin.listen(
    (data) => controller.add(data),
    onError: (Object e) => controller.addError(e),
    onDone: () => controller.close(),
  );
  _stdinRelayController = controller;
  return controller.stream;
}

StreamController<List<int>>? _stdinRelayController;

/// Production implementation that delegates to `dart:io` globals.
class LiveStdio implements Stdio {
  const LiveStdio();

  @override
  Stream<List<int>> get stdin => _sharedStdin;

  @override
  void write(String s) => io.stdout.write(s);

  @override
  int get terminalColumns => io.stdout.terminalColumns;

  @override
  int get terminalLines => io.stdout.terminalLines;

  @override
  bool get hasTerminal => io.stdout.hasTerminal;

  @override
  bool get stdinHasTerminal => io.stdin.hasTerminal;

  @override
  bool get echoMode => io.stdin.echoMode;

  @override
  bool get lineMode => io.stdin.lineMode;

  @override
  void setEchoMode(bool value) => io.stdin.echoMode = value;

  @override
  void setLineMode(bool value) => io.stdin.lineMode = value;

  @override
  Stream<io.ProcessSignal> watchSignal(io.ProcessSignal s) {
    try {
      return s.watch();
    } on io.SignalException {
      return const Stream.empty();
    }
  }
}
