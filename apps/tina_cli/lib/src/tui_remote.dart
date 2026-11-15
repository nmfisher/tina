/// The TUI over a remote pipes engine (Option 1 Phase B): a spawned engine
/// process — `tina-wasm-host`, or any command speaking the pipes protocol on
/// stdio — with the session front end routed through [PipesConnection].
///
/// What is shared with the native (in-process) TUI: the renderer, the input
/// editor, resize, `SessionView`, the connection-driven plugin views, and
/// everything the wire now carries (entries, notices, feature projections,
/// command vocabulary, questions). What stays front-end-only: raw mode,
/// window size, signals. What a remote engine cannot serve: child sessions
/// (one process is one session), configuration-driven theming (the wire
/// carries no theme), the settings editor (the `settings` op is discovery
/// only), and the working directory for file completion (reads as '').
///
/// Approval asks arrive as `approval` events and are answered through the
/// [PipesApprovalView] dialog over the `approve` op — the same decision set
/// the headless protocol allows (allow / always / deny); command patterns
/// and directory grants stay engine-side.
library;

import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart' show Terminal;
import 'package:tina_host/tina_host.dart';
import 'package:tina_tui/tina_tui.dart' show SessionView;

import 'tui_session.dart' show TuiSessionHandle;

import 'engine_launcher.dart' show EngineProcess;
import 'pipes_connection.dart' show PipesApprovals, PipesConnection;
import 'session_terminal.dart' show SessionTerminal;
import 'session_view_remote.dart' show presentationForRemote;

/// One TUI session over a remote engine process.
final class RemoteTuiSession implements TuiSessionHandle {
  RemoteTuiSession._(this._engine, this._connection)
      : terminal = SessionTerminal();

  /// Spawns [engine] and waits for the engine's `ready` event. Throws when
  /// the process exits before becoming ready (the engine's stderr tail is
  /// attached to the error).
  static Future<RemoteTuiSession> start(EngineProcess engine) async {
    final connection = await engine.ready;
    return RemoteTuiSession._(engine, connection);
  }

  /// The session id the engine reported in `ready` — for the resume hint.
  String get sessionId => _connection.status.id;

  /// The engine's approval asks, for harnesses and diagnostics. The view
  /// set serves the dialog; nothing else should answer through this.
  PipesApprovals get approvals => _connection.approvals;

  /// The spawned engine process — harnesses watch its stderr and exit.
  EngineProcess get engine => _engine;

  /// The front-end terminal slot. The engine owns the real asks; this
  /// terminal answers nothing and only satisfies the shared [runTui]
  /// contract (plugin lines are engine notices/entries here).
  @override
  final Terminal terminal;
  final EngineProcess _engine;
  final PipesConnection _connection;
  bool _closed = false;

  late final presentation = presentationForRemote(_connection);

  /// The root view. [role] exists for the shared contract; a remote engine
  /// serves exactly one controlling front end.
  @override
  SessionView createView(
          {bool showConfig = false, SessionRole role = SessionRole.controller}) =>
      SessionView(_connection, presentation, showConfig: showConfig);

  /// A remote engine process serves one session; the panel/workspace path
  /// never runs (runApp only requests child sessions with a workspace).
  @override
  Never spawn([String? model]) =>
      throw UnsupportedError('a remote engine serves one session');

  /// No plugin publishes a console workspace over the pipes surface today;
  /// null keeps runApp on the single-conversation path.
  @override
  ConsoleWorkspace? createWorkspace() => null;

  @override
  bool get canCancel => !_closed && _connection.status.canCancel;

  @override
  void cancel() {
    if (_closed) return;
    _connection.cancel(
        _connection.status.cancellableWork.map((work) => work.id),
        reason: 'escape');
  }

  @override
  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    try {
      await _engine.stop();
    } finally {
      _connection.close();
      // The front-end terminal owns no asks; closing it is a formality that
      // keeps parity with the in-process session's teardown.
      (terminal as SessionTerminal).closeInput();
    }
  }

  /// Teardown when the renderer never started (spawn or startup failure).
  void close() {
    if (_closed) return;
    _closed = true;
    _connection.close();
    _engine.kill();
  }
}
