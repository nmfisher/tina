library;

import 'dart:async';
import 'dart:collection';
import 'plugin_catalog.dart';
import 'settings_stack.dart';
import 'dart:io' as io;

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/notcurses.dart';
import 'package:tina_persistence/tina_persistence.dart';

import 'settings_panel.dart';
import 'config_settings_management.dart';
import 'tui_session.dart';
import 'session_view.dart';
export 'theme.dart';
import 'session_selection.dart';
import 'terminal_startup.dart';

/// Run the app on [session] until the user quits or stdin ends.
/// This embedded application owns [session] and every session it spawns:
/// exit cancels and settles dispatched work before closing runtime resources.
/// Use [SessionView] for an independently disposable view of a borrowed session.
///
/// The named seams exist for tests: [screen] replaces the real
/// full-screen one, [editorFor] replaces the raw-mode line editor and
/// [consoleContextFor] supplies frontend capabilities to UI contributions. Returns 0 — the
/// process exits nonzero only on a startup failure, before this runs.
Future<int> runApp(
  TuiSession session, {
  Screen? screen,
  LineEditor Function(Screen screen)? editorFor,
  ConsoleContext Function(Screen, LineEditor)? consoleContextFor,
  Stream<ScreenLayout>? resizes,
  String backend = 'auto',
  StartupTerminal? startup,
  Map<String, String>? environment,
}) async {
  if (session.terminal is! TuiTerminal) {
    throw ArgumentError('runApp requires a TuiTerminal');
  }
  final view = session.createView(showConfig: true);
  final selection = resolveBackendSelection(backend, environment: environment);
  final s = startup?.screen ??
      screen ??
      _newScreen(theme: view.theme, backend: selection.backend);
  if (startup != null) s.setTheme(view.theme);
  final tmuxNotice = startup?.tmuxNotice ?? selection.tmuxNotice;
  final queued = Queue<String>();
  final commands = <Future<void>>{};
  Future<void>? activeWork;
  var stopping = false;
  void Function()? releaseQueueStatus, releaseBackendStatus;
  StreamSubscription<ScreenLayout>? resizeSubscription;
  StreamSubscription<io.ProcessSignal>? interruptSubscription;
  late final LineEditor editor = startup?.editor ??
      (editorFor != null
          ? editorFor(s)
          : LineEditor(
              screen: s,
              input: s.backend is NotcursesBackend
                  ? (s.backend as NotcursesBackend).createInputBackend()
                  : null));
  editor.restoreHistory(view.inputHistory);
  final console = consoleContextFor?.call(s, editor) ??
      ConsoleContext(screen: s, editor: editor);
  if (editorFor == null) {
    editor.commandProvider = view.commandCompletion;
    editor.completionProvider = view.fileCompletion;
  }
  var ownsTty = false;
  bool? previousEchoMode, previousLineMode;
  try {
    ownsTty = startup == null &&
        screen == null &&
        s.io.hasTerminal &&
        s.backend is! NotcursesBackend;
    if (ownsTty) {
      try {
        previousEchoMode = io.stdin.echoMode;
        previousLineMode = io.stdin.lineMode;
        io.stdin.echoMode = false;
        io.stdin.lineMode = false;
      } catch (_) {}
    }
    if (!s.passthrough) s.enterAltScreen();
    releaseBackendStatus = console.bindStatus(
        () => [
              RenderLine(runs: [
                RenderRun(s.backend is NotcursesBackend ? 'notcurses' : 'ansi',
                    s.theme.chat.dim),
                if (tmuxNotice != null)
                  RenderRun('  ·  $tmuxNotice', s.theme.chat.dim),
              ])
            ],
        priority: -20);
    if (s.backend is NotcursesBackend) await editor.input.ready;
    interruptSubscription = s.io
        .watchSignal(io.ProcessSignal.sigint)
        .listen((_) => editor.inject(ControlKey(ControlCode.ctrlC)));
    final workspace = session.presentation.createWorkspace();
    resizeSubscription = (resizes ??
            (screen == null
                ? s.io.watchSignal(io.ProcessSignal.sigwinch).map((_) =>
                    ScreenLayout.fromSize(
                        io.stdout.terminalColumns, io.stdout.terminalLines,
                        split: false))
                : const Stream<ScreenLayout>.empty()))
        .listen((layout) {
      s.resize(layout);
      if (workspace != null)
        workspace.repaintConsole();
      else {
        editor.handleResize();
        view.repaintConsole();
      }
    });
    if (workspace != null) {
      final owned = <ConsoleSessionView, TuiSession>{view: session};
      return await workspace.runConsole(console, view, (model) async {
        final child = session.spawn(model);
        final childView = child.createView();
        owned[childView] = child;
        return childView;
      }, onViewClosed: (closedView, pendingWork) async {
        final owner = owned.remove(closedView);
        if (owner == null) return;
        // The root assembly also supplies configuration and new sessions until
        // app exit; child sessions can release their resources immediately.
        if (identical(owner, session)) {
          owner.cancel();
          await pendingWork;
        } else {
          await Future.wait([owner.shutdown(), pendingWork]);
        }
      });
    }
    view.attachConsole(console);
    releaseQueueStatus = console.bindStatus(() {
      final count = queued.length + view.pendingInputCount;
      return count == 0
          ? []
          : [
              RenderLine(align: StatusAlign.right, runs: [
                RenderRun(
                    '$count ${count == 1 ? 'message' : 'messages'} queued',
                    s.theme.chat.yellow)
              ])
            ];
    }, priority: 0);
    s.frame(() {
      s.redrawFrame();
      view.repaintConsole();
      s.input.render(
          prompt: editor.promptBuilder?.call() ?? '› ', buffer: '', cursor: 0);
    });
    editor.onDoubleEscape = () {
      if (!view.canCancel) return false;
      view.cancel();
      return true;
    };
    while (!view.quitRequested && !editor.quitRequested) {
      view.repaintConsole();
      final line =
          queued.isEmpty ? await editor.readLine('› ') : queued.removeFirst();
      if (line == null) break;
      console.refreshStatus();
      if (line.isEmpty) continue;
      editor.beginCancelMonitor(() {
        if (view.canCancel) view.cancel();
      }, onQueueSubmit: (text) {
        final command = view.offerCommand(text);
        if (command != null) {
          late final Future<void> task;
          task = command.catchError((Object error) {
            if (!stopping) view.notice('Command error: $error');
          }).whenComplete(() => commands.remove(task));
          commands.add(task);
          return;
        }
        if (!view.offerInput(text)) queued.addLast(text);
        view.notice('Message queued; waiting for current work.');
        console.refreshStatus();
      }, queueCountProvider: () => queued.length + view.pendingInputCount);
      try {
        activeWork = view.submit(line);
        await Future.any([activeWork, editor.whenQuit]);
        if (editor.quitRequested) break;
        activeWork = null;
      } finally {
        editor.endInputCaptureWindow();
      }
    }
    return 0;
  } finally {
    stopping = true;
    // Detach first, including local dialogs. The owner separately drains all
    // runtime work, including submissions made through another connection.
    releaseQueueStatus?.call();
    releaseBackendStatus?.call();
    view.close();
    editor.onDoubleEscape = null;
    try {
      await Future.wait([
        session.shutdown(),
        if (activeWork != null) activeWork,
        ...commands,
      ]);
    } finally {
      await interruptSubscription?.cancel();
      await resizeSubscription?.cancel();
      if (ownsTty) {
        try {
          if (previousEchoMode != null) io.stdin.echoMode = previousEchoMode;
          if (previousLineMode != null) io.stdin.lineMode = previousLineMode;
        } catch (_) {}
      }
      if (startup != null)
        startup.close();
      else {
        editor.close(reportLatency: false);
        s.dispose();
        if (!s.passthrough) s.leaveAltScreen();
      }
      editor.reportInputLatency();
    }
  }
}

/// The resolved `--backend` selection: the renderer to construct and, when
/// tmux demoted `auto` to ANSI, the one-line notice the status bar shows.
///
/// Inside tmux (`$TMUX` set) `auto` selects ANSI: notcurses renders
/// unpredictably there — its glyph layout disagrees with tmux's raster
/// (tin-q4vz, tin-p8k2), its DA1 reply confuses the vendored input automaton,
/// and a detached session needs the reply-guard detour that surrenders
/// colour detection (tin-r2vd). An explicit `--backend` always wins and
/// silences the notice; outside tmux nothing changes.
({String backend, String? tmuxNotice}) resolveBackendSelection(String backend,
    {Map<String, String>? environment}) {
  if (backend != 'auto') return (backend: backend, tmuxNotice: null);
  final insideTmux =
      ((environment ?? io.Platform.environment)['TMUX'] ?? '').isNotEmpty;
  if (!insideTmux) return (backend: backend, tmuxNotice: null);
  return (
    backend: 'ansi',
    tmuxNotice: 'tmux: --backend ansi renders more predictably than notcurses',
  );
}

/// The real screen: size off the process's stdout, selected backend, no
/// menu bar — one chat panel, one status row, one input row. Without a
/// terminal there is no size to ask for (`terminalColumns` throws on a
/// pipe), so debug and CI runs fall back to a conventional 80×24. The
/// caller resolves the selection first ([resolveBackendSelection]); this
/// constructor only honours the name it is given.
Screen _newScreen({Theme? theme, required String backend}) {
  var columns = 80;
  var lines = 24;
  if (io.stdout.hasTerminal) {
    columns = io.stdout.terminalColumns;
    lines = io.stdout.terminalLines;
  }
  final layout = ScreenLayout.fromSize(columns, lines, split: false);
  final interactive = io.stdout.hasTerminal && io.stdin.hasTerminal;
  if (backend == 'notcurses' && !interactive) {
    throw StateError('--backend notcurses requires a terminal');
  }
  if (backend != 'ansi' && interactive) {
    TerminalStartupSnapshot? snapshot;
    NotcursesBackend? native;
    try {
      snapshot = TerminalStartupSnapshot.capture();
      native = NotcursesBackend.create(io: const _AppStdio());
      return Screen.withBackend(
          backend: native,
          io: const _AppStdio(),
          theme: theme ?? const Theme.defaults(),
          layout: layout);
    } catch (_) {
      try {
        native?.enterAltScreen();
        native?.leaveAltScreen();
      } finally {
        snapshot?.restore();
      }
      if (backend == 'notcurses') rethrow;
    } finally {
      snapshot?.dispose();
    }
  }
  return Screen(
    io: const _AppStdio(),
    theme: theme ?? const Theme.defaults(),
    layout: layout,
  );
}

/// ANSI input reads the process stream directly, so disposing its input
/// backend releases that subscription. Notcurses owns its capability queries
/// and input queue; its paired input backend is the sole reader on that path.
class _AppStdio extends LiveStdio {
  const _AppStdio();

  @override
  Stream<List<int>> get stdin => io.stdin;
}

/// One terminal owner from the startup picker through the resumed app. The
/// same reader stays attached to stdin; native terminal initialization runs
/// once. The CLI also closes this on cancellation or assembly failure.
final class StartupTerminal {
  StartupTerminal._(this.screen, this.editor, this._echo, this._line,
      {String? tmuxNotice})
      : _tmuxNotice = tmuxNotice;
  final Screen screen;
  final LineEditor editor;

  /// Non-null when startup resolved `auto` inside tmux and demoted it to
  /// ANSI; runApp binds it into the status bar. Never set for an explicit
  /// `--backend` or a shell outside tmux.
  final String? _tmuxNotice;

  /// The fallback notice this terminal was opened with, if any.
  String? get tmuxNotice => _tmuxNotice;
  final bool? _echo;
  final bool? _line;
  bool _closed = false;

  factory StartupTerminal.open(
      {String backend = 'auto', Map<String, String>? environment}) {
    final selection = resolveBackendSelection(backend,
        environment: environment ?? io.Platform.environment);
    final screen = _newScreen(backend: selection.backend);
    final native = screen.backend is NotcursesBackend;
    final editor = LineEditor(
        screen: screen,
        input: native
            ? (screen.backend as NotcursesBackend).createInputBackend()
            : null);
    final terminal = StartupTerminal._(screen, editor,
        native ? null : io.stdin.echoMode, native ? null : io.stdin.lineMode,
        tmuxNotice: selection.tmuxNotice);
    try {
      if (!native) {
        io.stdin.echoMode = false;
        io.stdin.lineMode = false;
      }
      screen.enterAltScreen();
      return terminal;
    } catch (_) {
      terminal.close();
      rethrow;
    }
  }

  Future<String?> pickSession(List<StoredSession> sessions) async {
    await editor.input.ready;
    final picker = SessionPicker(screen, editor, sessions);
    final resize = io.ProcessSignal.sigwinch.watch().listen((_) {
      screen.resize(ScreenLayout.fromSize(
          io.stdout.terminalColumns, io.stdout.terminalLines,
          split: false));
      picker.repaint();
    });
    try {
      return await picker.run();
    } finally {
      await resize.cancel();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    // Restoring modes precedes closing stdin; Dart can release its descriptor.
    if (_echo != null) io.stdin.echoMode = _echo;
    if (_line != null) io.stdin.lineMode = _line;
    editor.close(reportLatency: false);
    screen.dispose();
    screen.leaveAltScreen();
  }
}

/// Initial configuration has no model session; it edits the scoped stack
/// directly over the config file, so first-run and `/settings` share one
/// editor. Without a conversation there is no session layer — writes land
/// in Global (the workspace path aliases the same file).
Future<bool> runConfigEditor(String path,
    {String backend = 'auto', StartupTerminal? startup}) async {
  final terminal = startup ?? StartupTerminal.open(backend: backend);
  final screen = terminal.screen;
  final editor = terminal.editor;
  final panel = SettingsPanel(screen, editor);
  StreamSubscription<io.ProcessSignal>? resize;
  try {
    await editor.input.ready;
    resize = io.ProcessSignal.sigwinch.watch().listen((_) {
      screen.resize(ScreenLayout.fromSize(
          io.stdout.terminalColumns, io.stdout.terminalLines,
          split: false));
      panel.repaint();
    });
    final descriptors = configuredDescriptors();
    final stack = ScopedSettingsStack.build(
        globalPath: path, workspacePath: path, descriptors: descriptors);
    final registry = stack.registry;
    final saved = await panel.run(
        management: ConfigSettingsManagement(
            scopedSettings: stack.settings,
            backend: stack.backend,
            descriptors: descriptors,
            pluginDescriptions: pluginDescriptions(registry),
            validatePlugins: registry.validate));
    stack.settings.close();
    return saved;
  } finally {
    await resize?.cancel();
    terminal.close();
  }
}
