/// The TUI session: the same host the shell drives, the same services,
/// the TUI's own [Terminal] in the slot.
///
/// The payoff of the plugin-services design, in one small file: the
/// command plugin knows nothing about the TUI, the TUI knows nothing
/// about which commands exist. [TuiSession.start] registers the
/// [TuiTerminal] and the [Commands] registry into a fresh [Services]
/// **before** anything can read them, mounts the same plugins the shell
/// mounts ([ToolsPlugin] — the tools and the boundary, publishing itself
/// as the mode service — and the mode command plugin publishing its
/// word), and starts the one host. [TuiSession.runLine] dispatches
/// through [dispatchLine] — the pure decision — and runs a turn for a
/// plain line, so a TUI run and a shell run of the same input produce
/// the same log.
library;

import 'dart:io' show Directory;

import 'package:tina_host/tina_host.dart';
import 'package:tina_services/tina_services.dart';
import 'package:tina_tools/tina_tools.dart' show ModeCommandPlugin;

import 'tui_commands.dart';
import 'tui_terminal.dart';

export 'tui_commands.dart';
export 'tui_terminal.dart';

/// One TUI session: the host, the shared services, the TUI terminal.
final class TuiSession {
  TuiSession._({
    required this.host,
    required this.services,
    required this.terminal,
  }) : commands = services.get<Commands>();

  /// The session's host — the loop inside it is the conversation.
  final Host host;

  /// The shared services: the [Terminal] and [Commands] a plugin
  /// resolves at use.
  final Services services;

  /// The TUI's terminal — the text sink plugin lines land in.
  final TuiTerminal terminal;

  /// The registry the command plugins published into.
  final Commands commands;

  /// Assemble a session: services registered first, then the plugins,
  /// then the host. The factory seam is the shell's — a test drives a
  /// scripted provider through it, production reads the config.
  static TuiSession start({
    required ProviderFactory providerFactory,
    String model = 'scripted',
    required String workingDirectory,
    TuiTerminal? terminal,
    String? storePath,
  }) {
    final services = Services();
    final tui = terminal ?? TuiTerminal();
    services
      ..put<Terminal>(tui)
      ..put<Commands>(Commands());
    final tools = ToolsPlugin(
      workspaceRoot: workingDirectory,
      tinaDir: Directory('$workingDirectory/.tina'),
      services: services,
    );
    final host = Host.start(HostConfig(
      providerFactory: providerFactory,
      model: model,
      workingDirectory: workingDirectory,
      plugins: [tools],
      storePath: storePath,
    ));
    // The mode's word, owned by the plugin that carries it — the same
    // registration the shell performs, never a TUI-side copy of it.
    ModeCommandPlugin(services).register();
    return TuiSession._(host: host, services: services, terminal: tui);
  }

  /// Run one entered line through the pure dispatch: a published command
  /// runs its handler (which tells through the terminal), an unknown
  /// `/word` is reported — never swallowed, never a turn — and an
  /// ordinary line runs one turn. An empty line is nothing at all.
  Future<void> runLine(String line) async {
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
  }

  /// Close the host. The terminal's pending asks resolve with the empty
  /// answer — a closing front end never leaves a plugin hanging.
  void close() {
    terminal.closeInput();
    host.close();
  }
}
