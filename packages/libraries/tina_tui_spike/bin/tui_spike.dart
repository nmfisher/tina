// Option 2 spike guest (issue #85): the tina console's REAL ANSI backend,
// screen, status strip and input parser, compiled to a wasm component and
// driven over WASI stdio by the host's `--tui` mode.
//
// The demo imports the console src libraries directly (the package barrel
// still drags dart:io/fuzzy_ranker; that closure is documented as
// spike-blocking work, not demo work). It proves three things end to end:
// ANSI rendering bytes reach the terminal, parsed keys come back through
// WASI stdin, and the host-owned tty size authority drives live resize.
//
// Env knobs (set by the host):
//   TUI_SPIKE_TRAP=1 — paint once, then trap (the forced-kill restore case).
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:typed_data';

import 'package:tina_console/src/ansi_capable.dart';
import 'package:tina_console/src/backend/ansi_backend.dart';
import 'package:tina_console/src/backend/ansi_input_backend.dart';
import 'package:tina_console/src/input_event.dart';
import 'package:tina_console/src/renderer.dart' show RenderLine, RenderRun;
import 'package:tina_console/src/region.dart' show ScrollingTextRegion;
import 'package:tina_console/src/screen.dart';
import 'package:tina_console/src/screen_layout.dart';
import 'package:tina_console/src/stdio.dart';
import 'package:tina_console/src/theme.dart';

import 'package:tina_tui_spike/src/components/tina_tui_tui_spike.dart' as root;
import 'package:tina_tui_spike/src/components/wasi_cli.dart' as wasi_cli;
import 'package:wasm_components/wasm_components.dart' as cm;

void main(List<String> arguments) {
  root.tuiSpikeComponent((imports) => _SpikeRun(imports));
}

final class _SpikeRun implements wasi_cli.Run {
  final root.TuiSpikeImports _imports;

  _SpikeRun(this._imports);

  @override
  Future<cm.Result<void, void>> run() async {
    final environment = <String, String>{
      for (final (name, value) in _imports.cliEnvironment.getEnvironment())
        name: value,
    };

    // The host owns the real terminal: the size authority answers with the
    // live window, and the terminal instances tell us honestly whether
    // stdin/stdout are a tty.
    final (initialCols, initialRows) = _imports.termTty.getSize();
    final stdio = WasiStdio(_imports);

    final backend = AnsiBackend(io: stdio, ansi: AnsiCapable.yes);
    final screen = Screen.withBackend(
      backend: backend,
      io: stdio,
      layout: ScreenLayout.fromSize(initialCols, initialRows, split: false),
      ansi: AnsiCapable.yes,
      theme: const Theme.defaults(),
    );

    screen.enterAltScreen();
    final chat = ScrollingTextRegion(screen);
    chat.writeln('tina TUI compiled to wasm — ANSI backend (Option 2 spike)');
    chat.writeln('');
    chat.writeln(
        'renderer: AnsiBackend over WASI stdio · size ${initialCols}x$initialRows');
    chat.writeln('keys echo below · Esc notes a cancel · Ctrl-L clears · '
        'Ctrl-C quits');
    chat.writeln('');
    screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
    _status(screen, stdio, initialCols, initialRows);

    if (environment['TUI_SPIKE_TRAP'] == '1') {
      // Painted one frame, then died mid-run: the host must still restore
      // the terminal. This is the forced-kill case of the spike demo.
      throw StateError('spike trap requested via TUI_SPIKE_TRAP');
    }

    final input = AnsiInputBackend(io: stdio);
    final quit = Completer<void>();
    late final StreamSubscription<InputEvent> events;
    events = input.events.listen((event) {
      switch (event) {
        case CharInput(:final text):
          chat.write(text);
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
        case ControlKey(code: ControlCode.enter):
          chat.writeln('');
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
        case ControlKey(code: ControlCode.ctrlC):
          quit.complete();
        case EscapeKey():
          chat.writeln('\n[escape]');
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
        case ArrowKey():
          chat.write('·');
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
        case PasteInput(:final text):
          chat.writeln('\n[paste ${text.length} chars]');
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
        case _:
          chat.write('·');
          screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
      }
    });

    // Resize: the host re-supplies the size on SIGWINCH through the tty
    // import; the guest polls it (WASI has no guest-side signal path).
    (int, int) last = (initialCols, initialRows);
    final poll = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final (cols, rows) = _imports.termTty.getSize();
      if (cols == last.$1 && rows == last.$2) return;
      last = (cols, rows);
      stdio.noteSize(cols, rows);
      screen.resize(ScreenLayout.fromSize(cols, rows, split: false));
      chat.writeln('resized to ${cols}x$rows');
      screen.requestChatPresentation(chat, contentRowsAtWindowStart: 0);
      _status(screen, stdio, cols, rows);
    });

    await quit.future;
    poll.cancel();
    await events.cancel();
    input.dispose();
    screen.leaveAltScreen();
    screen.dispose();
    stdio.write('\nspike run ended cleanly (raw mode restored by the host)\n');
    await stdio.drain();
    return const cm.OkResult(null);
  }

  void _status(Screen screen, Stdio stdio, int cols, int rows) {
    screen.setStatusLines([
      RenderLine(runs: const [
        RenderRun('wasm · ansi', null),
        RenderRun('  ·  Option 2 spike', null),
      ]),
    ]);
  }
}

/// The WASI-backed [Stdio] the real ANSI backend writes through and reads
/// from. Output is one ordered queue of stream writes (never interleaved);
/// input fans out from the single WASI stdin stream like the native relay.
final class WasiStdio implements Stdio {
  WasiStdio(this._imports) {
    final (stream, _) = _imports.cliStdin.readViaStream();
    _stdinSub = stream.listen(
      (chunk) => _stdin.add(chunk),
      onDone: () => _stdin.close(),
      onError: (Object e) => _stdin.addError(e),
    );
  }

  final root.TuiSpikeImports _imports;
  final StreamController<List<int>> _stdin =
      StreamController<List<int>>.broadcast(sync: true);
  late final StreamSubscription<Uint8List> _stdinSub;
  Future<void> _outbound = Future<void>.value();
  int _columns = 80;
  int _rows = 24;

  /// The live size, re-supplied by the run loop from the host's tty import.
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
  bool get hasTerminal => _imports.cliTerminalStdin.getTerminalStdin().hasValue;

  @override
  Stream<ProcessSignal> watchSignal(ProcessSignal s) => const Stream.empty();
}
