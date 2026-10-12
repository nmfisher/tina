library;

import 'package:tina_host/tina_host.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_engine_2/tina_engine_2.dart' show StopReason;
import 'package:tina_mode/tina_mode.dart' show ModePlugin;
import 'assembly.dart';
import 'session_terminal.dart';
import 'package:tina_tui/tina_tui.dart';
import 'tui_presentation.dart';
import 'console_catalog.dart';
import 'package:tina_console/tina_console.dart' show ConsoleWorkspace;

export 'assembly.dart';
export 'assembly_config.dart';
export 'session_terminal.dart';

/// One TUI session: the assembly with the TUI's terminal in the slot.
final class TuiSession {
  TuiSession._({
    required this.assembly,
    required this.terminal,
    ConsoleViewFactory viewFactory = createConsoleView,
  })  : host = assembly.host,
        commands = assembly.commands,
        _viewFactory = viewFactory,
        _connection = assembly.host.connect();

  /// The assembly this session wraps — the app, wiring and all.
  final SessionAssembly assembly;

  /// The session's host — the loop inside it is the conversation.
  final Host host;

  /// The session's terminal — the text sink for plugin lines and the adapter
  /// for ordinary questions answered by request ID. A [SessionTerminal]
  /// when this wrapper created it; whatever the assembly was handed when
  /// it was built with one.
  final Terminal terminal;

  /// The registry the command plugins published into.
  final Commands commands;
  final SessionConnection _connection;
  final ConsoleViewFactory _viewFactory;
  bool _closed = false;
  List<String>? _closedHistory;
  late final presentation = presentationForAssembly(assembly,
      connection: _connection, viewFactory: _viewFactory);

  SessionView createView(
      {bool showConfig = false, SessionRole role = SessionRole.controller}) {
    final connection = host.connect(role: role);
    return SessionView(
        connection,
        presentationForAssembly(assembly,
            connection: connection, viewFactory: _viewFactory),
        showConfig: showConfig);
  }

  TuiSession spawn([String? model]) =>
      TuiSession.wrap(assembly.newSession(model), viewFactory: _viewFactory);

  ConsoleWorkspace? createWorkspace() => assembly.host.plugins
      .map((plugin) => _viewFactory(plugin, access: _connection.access))
      .whereType<ConsoleWorkspace>()
      .firstOrNull;

  bool get canCancel => !_closed && _connection.status.canCancel;

  void cancel() {
    if (_closed) return;
    _connection.cancel(
        _connection.status.cancellableWork.map((work) => work.id),
        reason: 'escape');
  }

  /// Only plain messages may enter the model input queue.
  bool offerInput(String text) => _connection.offerInput(text);

  /// Raw submitted messages in transcript order, including inputs before
  /// compaction or clear. Legacy logs without input records use user text.
  List<String> get inputHistory => _closedHistory ?? _connection.inputHistory;

  /// The session's permission mode as the vocabulary's word — the status
  /// strip's label. The enum never leaves the tools package.
  String get modeWord {
    return ModePlugin.wordFor(assembly.tools.mode);
  }

  static TuiSession start({
    required ProviderFactory providerFactory,
    String model = 'scripted',
    required String workingDirectory,
    SessionTerminal? terminal,
    String? storePath,
    String? configPath,
    AssemblyWriter? writer,
  }) {
    final tui = terminal ?? SessionTerminal();
    final assembly = SessionAssembly.start(
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

  /// Wrap an assembly with application-owned view construction. The factory
  /// creates a fresh view per attachment and receives that client's authority.
  factory TuiSession.wrap(SessionAssembly assembly,
      {ConsoleViewFactory viewFactory = createConsoleView}) {
    return TuiSession._(
        assembly: assembly,
        terminal: assembly.terminal,
        viewFactory: viewFactory);
  }

  /// Run one entered line through the pure dispatch: a published command
  /// runs its handler (which tells through the terminal), an unknown
  /// `/word` is reported — never swallowed, never a turn — and an
  /// ordinary line runs one turn. An empty line is nothing at all. The
  /// rules belong to the host connection, shared with the assembly so a
  /// rendered run and a headless `handleCommand` run agree.
  Future<bool> runLine(String line, {bool renderReply = true}) async {
    final result = await _connection.submit(line);
    if (result.detail.isNotEmpty &&
        (renderReply || result.stopReason != StopReason.complete)) {
      terminal.writeln(result.detail);
    }
    return assembly.quitRequested;
  }

  /// UI dispatchers can offer a line without naming individual commands.
  /// Only an explicit opt-in may bypass the active conversation's queue.
  Future<void>? offerCommand(String line) =>
      _connection.offerCommand(line)?.then((result) {
        if (result.notice case final notice?) terminal.writeln(notice);
      });

  Future<void> shutdown() async {
    try {
      await assembly.shutdown();
    } finally {
      close();
    }
  }

  /// Owner-only cleanup after cancelling and awaiting active work. Views use
  /// their own close/detach operation and must not call this method.
  /// The terminal's pending asks resolve with the empty
  /// answer — a closing front end never leaves a plugin hanging. (Only
  /// a [SessionTerminal] promises that; a foreign terminal is left alone.)
  void close() {
    if (_closed) return;
    _closedHistory = _connection.inputHistory;
    final t = terminal;
    if (t is SessionTerminal) t.closeInput();
    assembly.close();
    _connection.close();
    _closed = true;
  }
}

/// The wrapper's writer when the caller hands none in: nowhere. The
/// full-screen app passes a real one; nothing here needs the lines.
final class _NullWriter implements AssemblyWriter {
  const _NullWriter();

  @override
  void writeln([String? line]) {}
}
