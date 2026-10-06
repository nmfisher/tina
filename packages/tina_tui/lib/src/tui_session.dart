library;

import 'package:tina_host/tina_host.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_mode/tina_mode.dart' show ModePlugin;

import 'assembly.dart';
import 'tui_commands.dart';
import 'tui_terminal.dart';

export 'assembly.dart';
export 'assembly_config.dart';
export 'tui_commands.dart';
export 'tui_terminal.dart';

/// One TUI session: the assembly with the TUI's terminal in the slot.
final class TuiSession {
  TuiSession._({
    required this.assembly,
    required this.terminal,
  })  : host = assembly.host,
        commands = assembly.commands;

  /// The assembly this session wraps — the app, wiring and all.
  final TuiAssembly assembly;

  /// The session's host — the loop inside it is the conversation.
  final Host host;

  /// The session's terminal — the text sink plugin lines land in, and
  /// the queued answers to plugin asks come back through. A [TuiTerminal]
  /// when this wrapper created it; whatever the assembly was handed when
  /// it was built with one.
  final Terminal terminal;

  /// The registry the command plugins published into.
  final Commands commands;
  Command? _activeCommand;

  bool get canCancel => _activeCommand?.cancel != null || assembly.watchingTurn;

  void cancel() {
    _activeCommand?.cancel?.call();
    host.session.loop.cancel('escape');
  }

  /// Commands stay on the frontend's queue, even while a model turn runs.
  bool offerInput(String text) =>
      dispatchLine(commands, text) is PlainLine && host.offerInput(text);

  /// Raw submitted messages in transcript order, including inputs before
  /// compaction or clear. Legacy logs without input records use user text.
  List<String> get inputHistory {
    final log = host.session.loop.log;
    final recorded =
        log.whereType<InputRecordedEntry>().map((e) => e.turnId).toSet();
    return [
      for (final entry in log)
        if (entry is InputRecordedEntry && entry.text.isNotEmpty)
          entry.text
        else if (entry is MessageAppendedEntry &&
            entry.message.role == Role.user &&
            !recorded.contains(entry.turnId))
          for (final block in entry.message.content.whereType<TextBlock>())
            if (block.text.isNotEmpty) block.text,
    ];
  }

  /// The session's permission mode as the vocabulary's word — the status
  /// strip's label. The enum never leaves the tools package.
  String get modeWord {
    return ModePlugin.wordFor(assembly.tools.mode);
  }

  static TuiSession start({
    required ProviderFactory providerFactory,
    String model = 'scripted',
    required String workingDirectory,
    TuiTerminal? terminal,
    String? storePath,
    String? configPath,
    AssemblyWriter? writer,
  }) {
    final tui = terminal ?? TuiTerminal();
    final assembly = TuiAssembly.start(
      writer: writer ?? const _NullWriter(),
      providerFactory: (_) => providerFactory(model),
      terminal: tui,
      options: AssemblyOptions(
        configPath: configPath,
        workingDirectory: workingDirectory,
        storePath: storePath,
      ),
    );
    return TuiSession._(assembly: assembly, terminal: tui);
  }

  /// Wrap an assembly, retaining the terminal supplied to its plugins.
  factory TuiSession.wrap(TuiAssembly assembly) {
    return TuiSession._(assembly: assembly, terminal: assembly.terminal);
  }

  /// Run one entered line through the pure dispatch: a published command
  /// runs its handler (which tells through the terminal), an unknown
  /// `/word` is reported — never swallowed, never a turn — and an
  /// ordinary line runs one turn. An empty line is nothing at all. The
  /// rules are [dispatchLine]'s and the assembly's, kept identical so a
  /// rendered run and a headless `handleCommand` run agree.
  Future<bool> runLine(String line, {bool renderReply = true}) async {
    switch (dispatchLine(commands, line)) {
      case RunCommand(:final command, :final argument):
        _activeCommand = command;
        try {
          await command.handler(argument);
        } finally {
          _activeCommand = null;
        }
      case UnknownCommand(:final name):
        terminal.writeln('unknown command: /$name');
      case PlainLine(:final text) when text.isEmpty:
        break; // no turn for an empty line
      case PlainLine(:final text):
        assembly.turnObservation = Object();
        try {
          final outcome = await host.send(text);
          if (renderReply || outcome.stopReason != StopReason.complete) {
            terminal.writeln(outcome.detail);
          }
        } finally {
          assembly.turnObservation = null;
        }
    }
    return assembly.quitRequested;
  }

  /// UI dispatchers can offer a line without naming individual commands.
  /// Only an explicit opt-in may bypass the active conversation's queue.
  Future<void>? offerCommand(String line) {
    final decision = dispatchLine(commands, line);
    if (decision is RunCommand && decision.command.allowWhileRunning) {
      return decision.run();
    }
    return null;
  }

  /// Close the host. The terminal's pending asks resolve with the empty
  /// answer — a closing front end never leaves a plugin hanging. (Only
  /// a [TuiTerminal] promises that; a foreign terminal is left alone.)
  void close() {
    final t = terminal;
    if (t is TuiTerminal) t.closeInput();
    assembly.close();
  }
}

/// The wrapper's writer when the caller hands none in: nowhere. The
/// full-screen app passes a real one; nothing here needs the lines.
final class _NullWriter implements AssemblyWriter {
  const _NullWriter();

  @override
  void writeln([String? line]) {}
}
