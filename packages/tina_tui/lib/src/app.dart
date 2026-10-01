library;

import 'dart:async';
import 'dart:collection';
import 'plugin_catalog.dart';
import 'dart:io' as io;

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/notcurses.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';

import 'settings_panel.dart';
import 'completion_sources.dart';
import 'tui_session.dart';
import 'session_view.dart';
import 'session_selection.dart';

/// Run the app on [session] until the user quits or stdin ends.
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
  String backend = 'ansi',
  StartupTerminal? startup,
}) async {
  final terminal = session.terminal;
  if (terminal is! TuiTerminal) {
    throw ArgumentError('runApp requires a TuiTerminal');
  }
  final s = startup?.screen ??
      screen ??
      _newScreen(theme: resolveTheme(session.assembly.theme), backend: backend);
  if (startup != null) s.setTheme(resolveTheme(session.assembly.theme));
  // UI plugins own presentation. The app only routes generic notices and
  // mounts console capabilities; headless output still uses TuiTerminal.
  final queued = Queue<String>();
  final commands = <Future<void>>{};
  var stopping = false;
  StreamSubscription<ScreenLayout>? resizeSubscription;

  // The editor owns the raw bytes; where its keys go is decided below.
  late final LineEditor editor = startup?.editor ??
      (editorFor != null
          ? editorFor(s)
          : LineEditor(
              screen: s,
              input: s.backend is NotcursesBackend
                  ? (s.backend as NotcursesBackend).createInputBackend()
                  : null));
  editor.restoreHistory(session.inputHistory);
  final console = consoleContextFor?.call(s, editor) ??
      ConsoleContext(screen: s, editor: editor);
  final settings = SettingsPanel(s, editor);
  session.assembly.openSettings = () => console.interact(() async {
        if (stopping) return;
        try {
          final saved = await settings.run(
              applyGeneration: session.assembly.applySavedGeneration,
              path: session.assembly.configPath,
              sections: console.settings,
              descriptors: session.assembly.descriptors,
              validatePlugins: session.assembly.validatePlugins,
              pluginIds: session.assembly.pluginSettings.registry.ids,
              pluginDescriptions:
                  pluginDescriptions(session.assembly.pluginSettings.registry),
              pluginSettings: session.assembly.pluginSettings,
              pluginManager: session.assembly.pluginManager);
          terminal.writeln(saved
              ? 'Settings saved. Generation applies to the next request.'
              : 'Settings closed.');
        } catch (_) {
          terminal.writeln(
              'Could not open settings. Check the config file and its permissions.');
        }
        s.chat.repaint();
      });

  // Completion is a front-end concern: the two sources hang off the
  // editor's own pickers (`/` — command names from the session's
  // registry, read at use so later publications still suggest; `@` —
  // candidate paths from the session's working directory). A test's
  // injected editor keeps whatever sources it was built with.
  if (editorFor == null) {
    editor
      ..commandProvider = CommandNameCompletionSource(session.commands)
      ..completionProvider = GitFileCompletionSource(
          workingDir: session.assembly.host.config.workingDirectory);
  }

  final contributions =
      session.host.plugins.whereType<ConsoleContribution>().toList();
  final attached = <ConsoleContribution, ConsoleAttachment>{};
  terminal.onLine = (text) {
    final transcripts = attached.keys.whereType<ConsoleTranscript>();
    if (transcripts.isEmpty) {
      s.frame(() => s.chat.writeln(text));
    } else {
      transcripts.first.writeNotice(text);
    }
  };
  void repaintContributions() {
    for (final contribution in attached.keys.toList()) {
      contribution.repaintConsole();
    }
  }

  void attachContribution(AgentPlugin plugin) {
    if (plugin is! ConsoleContribution) return;
    final contribution = plugin as ConsoleContribution;
    attached[contribution] = ConsoleAttachment.attach(contribution, console);
  }

  void detachContribution(AgentPlugin plugin) {
    if (plugin is! ConsoleContribution) return;
    final contribution = plugin as ConsoleContribution;
    attached.remove(contribution)?.dispose();
  }

  session.assembly.pluginManager.onLoaded = attachContribution;
  session.assembly.pluginManager.onUnloading = detachContribution;

  var ownsTty = false;
  bool? previousEchoMode;
  bool? previousLineMode;
  try {
    // Raw mode only when this loop opened the real screen and there is
    // a controlling terminal; tolerantly skipped everywhere else — a
    // test harness drives events by hand and has no tty to change. An
    // injected screen still renders (alt screen below), it just never
    // touches the process's tty.
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
    // Native capability-reply draining must finish before a visible prompt
    // invites typing. Otherwise a quick first message can be discarded.
    if (s.backend is NotcursesBackend) await editor.input.ready;
    final workspace =
        session.host.plugins.whereType<ConsoleWorkspace>().firstOrNull;
    if (workspace != null) {
      resizeSubscription = (resizes ??
              (screen == null
                  ? s.io.watchSignal(io.ProcessSignal.sigwinch).map((_) =>
                      ScreenLayout.fromSize(
                          io.stdout.terminalColumns, io.stdout.terminalLines,
                          split: false))
                  : const Stream<ScreenLayout>.empty()))
          .listen((layout) {
        s.resize(layout);
        workspace.repaintConsole();
      });
      return await workspace.runConsole(
          console,
          SessionView(session, showConfig: true),
          (model) async =>
              SessionView(TuiSession.wrap(session.assembly.newSession(model))));
    }
    for (final contribution in contributions) {
      attached[contribution] = ConsoleAttachment.attach(contribution, console);
    }

    // First paint: what the assembly already knows — the config note it
    // read, the resumed log it seeded — then the status strip and the
    // empty input row, all in one frame.
    s.frame(() {
      s.redrawFrame();
      final note = session.assembly.configNote;
      if (note != null) terminal.writeln(note);
      repaintContributions();
      s.input.render(
          prompt: editor.promptBuilder?.call() ?? '› ', buffer: '', cursor: 0);
    });

    resizeSubscription = (resizes ??
            (screen == null
                ? s.io.watchSignal(io.ProcessSignal.sigwinch).map((_) =>
                    ScreenLayout.fromSize(
                        io.stdout.terminalColumns, io.stdout.terminalLines,
                        split: false))
                : const Stream<ScreenLayout>.empty()))
        .listen((layout) {
      s.resize(layout);
      editor.handleResize();
      repaintContributions();
      settings.repaint();
    });
    editor.onDoubleEscape = () {
      if (!session.assembly.watchingTurn) return false;
      session.host.session.loop.cancel('escape');
      return true;
    };

    while (true) {
      if (session.assembly.quitRequested) break;
      repaintContributions();
      final line =
          queued.isEmpty ? await editor.readLine('› ') : queued.removeFirst();
      if (line == null) break; // stdin closed
      if (line.isEmpty) continue;
      editor.beginCancelMonitor(() {
        if (session.assembly.watchingTurn)
          session.host.session.loop.cancel('escape');
      }, onQueueSubmit: (text) {
        final command = session.offerCommand(text);
        if (command != null) {
          late final Future<void> task;
          task = command.catchError((Object error) {
            if (!stopping) terminal.writeln('Command error: $error');
          }).whenComplete(() => commands.remove(task));
          commands.add(task);
          return;
        }
        if (text.trimLeft().startsWith('/') || !session.host.offerInput(text))
          queued.addLast(text);
      }, queueCount: queued.length);
      try {
        await session.runLine(line, renderReply: false);
      } finally {
        editor.endInputCaptureWindow();
      }
      // Refresh frontend contributions before returning to the editor.
      repaintContributions();
    }
    return 0;
  } finally {
    stopping = true;
    settings.cancel();
    await Future.wait(commands.toList());
    await resizeSubscription?.cancel();
    session.assembly.openSettings = null;
    session.assembly.pluginManager.onLoaded = null;
    session.assembly.pluginManager.onUnloading = null;
    editor.onDoubleEscape = null;
    for (final attachment in attached.values.toList().reversed) {
      try {
        attachment.dispose();
      } catch (_) {/* Restore the terminal regardless. */}
    }
    terminal.onLine = null;
    if (ownsTty) {
      try {
        if (previousEchoMode != null) io.stdin.echoMode = previousEchoMode;
        if (previousLineMode != null) io.stdin.lineMode = previousLineMode;
      } catch (_) {}
    }
    // Restore modes before cancelling the direct stdin subscription: Dart
    // closes its descriptor when that subscription is cancelled.
    if (startup != null) {
      startup.close();
    } else {
      editor.close(reportLatency: false);
      s.dispose();
      if (!s.passthrough) s.leaveAltScreen();
    }
    editor.reportInputLatency();
    session.close();
  }
}

/// The real screen: size off the process's stdout, selected backend, no
/// menu bar — one chat panel, one status row, one input row. Without a
/// terminal there is no size to ask for (`terminalColumns` throws on a
/// pipe), so debug and CI runs fall back to a conventional 80×24.
Screen _newScreen({Theme? theme, String backend = 'ansi'}) {
  var columns = 80;
  var lines = 24;
  if (io.stdout.hasTerminal) {
    columns = io.stdout.terminalColumns;
    lines = io.stdout.terminalLines;
  }
  final layout = ScreenLayout.fromSize(columns, lines, split: false);
  if (backend == 'notcurses') {
    if (!io.stdout.hasTerminal || !io.stdin.hasTerminal) {
      throw StateError('--backend notcurses requires a terminal');
    }
    final native = NotcursesBackend.create(io: const _AppStdio());
    try {
      return Screen.withBackend(
          backend: native,
          io: const _AppStdio(),
          theme: theme ?? const Theme.defaults(),
          layout: layout);
    } catch (_) {
      native.enterAltScreen();
      native.leaveAltScreen();
      rethrow;
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
  StartupTerminal._(this.screen, this.editor, this._echo, this._line);
  final Screen screen;
  final LineEditor editor;
  final bool? _echo;
  final bool? _line;
  bool _closed = false;

  factory StartupTerminal.open({String backend = 'ansi'}) {
    final screen = _newScreen(backend: backend);
    final native = screen.backend is NotcursesBackend;
    final editor = LineEditor(
        screen: screen,
        input: native
            ? (screen.backend as NotcursesBackend).createInputBackend()
            : null);
    final terminal = StartupTerminal._(screen, editor,
        native ? null : io.stdin.echoMode, native ? null : io.stdin.lineMode);
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
      editor.endKeyCaptureWindow();
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

/// Merge explicit color overrides over the selected shipped variant.
Theme resolveTheme(Map<String, dynamic> values) {
  final base = switch (values['variant']) {
    'light' => const Theme.light(),
    'dark' => const Theme.dark(),
    _ => const Theme.defaults(),
  };
  Map<String, dynamic> merge(Map<String, dynamic> a, Map<String, dynamic> b) =>
      {
        ...a,
        for (final e in b.entries)
          if (e.key != 'variant')
            e.key: e.value is Map && a[e.key] is Map
                ? merge(Map<String, dynamic>.from(a[e.key] as Map),
                    Map<String, dynamic>.from(e.value as Map))
                : e.value,
      };
  return Theme.fromMap(merge(base.toMap(), values));
}

/// Initial configuration has no model session and writes only on Save.
Future<bool> runConfigEditor(String path,
    {String backend = 'ansi', StartupTerminal? startup}) async {
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
    final registry = firstPartyPlugins();
    return await panel.run(
        path: path,
        pluginIds: registry.ids,
        pluginDescriptions: pluginDescriptions(registry),
        validatePlugins: registry.validate);
  } finally {
    await resize?.cancel();
    terminal.close();
  }
}
