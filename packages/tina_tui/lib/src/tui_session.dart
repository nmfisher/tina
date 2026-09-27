/// The TUI session: the assembly the app drives, with the TUI's
/// [TuiTerminal] in the slot.
///
/// With `tina_cli` gone there is one assembly, so there is nothing left
/// to be "the same as": the wrapper exists so the render loop holds one
/// object that carries the [TuiTerminal] and the [Commands] next to the
/// host — the render loop reads the terminal, the loop dispatches
/// through the assembly's registry via [TuiSession.runLine], and the
/// assembly guarantees the wiring order (services → plugins → host) no
/// matter who builds the app.
///
/// The payoff of the plugin-services design survives intact: the command
/// plugin knows nothing about the TUI, the TUI knows nothing about which
/// commands exist. [TuiSession.start] hands the [TuiTerminal] to
/// [TuiAssembly.start] and lets the assembly do the whole wiring — the
/// tools plugin (the tools and the boundary, publishing itself as the
/// mode service) and the mode command plugin publishing its word come
/// from there, never re-registered here.
library;

import 'package:tina_host/tina_host.dart';
import 'package:tina_llm/tina_llm.dart' show builtinDescriptors;
import 'package:tina_services/tina_services.dart';

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
        services = assembly.services,
        commands = assembly.commands;

  /// The assembly this session wraps — the app, wiring and all.
  final TuiAssembly assembly;

  /// The session's host — the loop inside it is the conversation.
  final Host host;

  /// The shared services: the [Terminal] and [Commands] a plugin
  /// resolves at use.
  final Services services;

  /// The TUI's terminal — the text sink plugin lines land in, and the
  /// queued answers to plugin asks come back through.
  final TuiTerminal terminal;

  /// The registry the command plugins published into.
  final Commands commands;

  /// Assemble a session: the assembly does the wiring (services →
  /// plugins → host → published commands), this wrapper only hands it
  /// the terminal. No terminal handed in, a fresh one is built — a test
  /// captures its lines instead of a screen. The model parameter keeps
  /// the scripted-factory tests honest: the factory is still the seam,
  /// the model is still the label it receives.
  static TuiSession start({
    required ProviderFactory providerFactory,
    String model = 'scripted',
    required String workingDirectory,
    TuiTerminal? terminal,
    String? storePath,
    AssemblyWriter? writer,
  }) {
    final tui = terminal ?? TuiTerminal();
    final assembly = TuiAssembly.start(
      writer: writer ?? const _NullWriter(),
      providerFactory: (_) => providerFactory(model),
      terminal: tui,
      options: AssemblyOptions(
        workingDirectory: workingDirectory,
        storePath: storePath,
      ),
      descriptors: builtinDescriptors,
    );
    return TuiSession._(assembly: assembly, terminal: tui);
  }

  /// Run one entered line through the pure dispatch: a published command
  /// runs its handler (which tells through the terminal), an unknown
  /// `/word` is reported — never swallowed, never a turn — and an
  /// ordinary line runs one turn. An empty line is nothing at all. The
  /// rules are [dispatchLine]'s and the assembly's, kept identical so a
  /// rendered run and a headless `handleCommand` run agree.
  Future<bool> runLine(String line) async {
    switch (dispatchLine(commands, line)) {
      case RunCommand(:final command, :final argument):
        command.handler(argument);
      case UnknownCommand(:final name):
        terminal.writeln('unknown command: /$name');
      case PlainLine(:final text) when text.isEmpty:
        break; // no turn for an empty line
      case PlainLine(:final text):
        final outcome = await host.send(text);
        terminal.writeln(outcome.detail);
    }
    return assembly.quitRequested;
  }

  /// Close the host. The terminal's pending asks resolve with the empty
  /// answer — a closing front end never leaves a plugin hanging.
  void close() {
    terminal.closeInput();
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
