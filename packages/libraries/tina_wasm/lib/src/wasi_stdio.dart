/// The WASI-backed [Stdio] the TUI guest's ANSI backend writes through and
/// reads from: output is one ordered queue of stream writes (never
/// interleaved); input fans out from the single WASI stdin stream like the
/// native relay; the size authority is the host's `tina:term/tty` answer
/// (re-noted by the run loop's poll); echo/line modes are no-ops — the
/// host's raw-mode pipe is the truth under wasm.
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:tina_console/src/stdio.dart';

import 'components/tina_probe_tui_app.dart' as root;

final class WasiStdio implements Stdio {
  WasiStdio(this._imports) {
    final (stream, _) = _imports.cliStdin.readViaStream();
    _stdinSub = stream.listen(
      (chunk) => _stdin.add(chunk),
      onDone: () => _stdin.close(),
      onError: (Object e) => _stdin.addError(e),
    );
  }

  final root.TuiAppImports _imports;
  final StreamController<List<int>> _stdin =
      StreamController<List<int>>.broadcast(sync: true);

  // Kept so the subscription's lifetime is explicit in debuggers; the
  // component owns it for the process's life.
  // ignore: unused_field
  late final StreamSubscription<Uint8List> _stdinSub;
  Future<void> _outbound = Future<void>.value();
  int _columns = 80;
  int _rows = 24;

  /// The live size, re-supplied by the run loop's tty poll.
  void noteSize(int cols, int rows) {
    _columns = cols;
    _rows = rows;
  }

  @override
  Stream<List<int>> get stdin => _stdin.stream;

  @override
  void write(String s) {
    _outbound = _outbound.then(
      (_) => _imports.cliStdout.writeViaStream(
        data: Stream.value(Uint8List.fromList(utf8.encode(s))),
      ),
    );
  }

  /// Every ordered write has reached the host sink.
  Future<void> drain() => _outbound;

  @override
  int get terminalColumns => _columns;

  @override
  int get terminalLines => _rows;

  @override
  bool get hasTerminal =>
      _imports.cliTerminalStdin.getTerminalStdin().hasValue;

  @override
  bool get stdinHasTerminal =>
      _imports.cliTerminalStdin.getTerminalStdin().hasValue;

  @override
  bool get echoMode => false;

  @override
  bool get lineMode => false;

  @override
  void setEchoMode(bool value) {}

  @override
  void setLineMode(bool value) {}

  /// Signals are host-owned: the raw byte stream carries ^C and the input
  /// parser turns it into Ctrl-C. No guest-side signal watching.
  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}
