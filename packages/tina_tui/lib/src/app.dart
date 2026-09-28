library;

import 'dart:async';
import 'dart:collection';
import 'plugin_catalog.dart';
import 'dart:io' as io;

import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'settings_panel.dart';
import 'completion_sources.dart';
import 'tui_session.dart';
import 'turn_renderer.dart';

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
}) async {
  final terminal = session.terminal;
  if (terminal is! TuiTerminal) {
    throw ArgumentError('runApp requires a TuiTerminal');
  }
  final s = screen ?? _newScreen(theme: resolveTheme(session.assembly.theme));
  // Every line the session's plugins tell is painted into the chat
  // region inside its own frame — the only screen writes outside the
  // loop below.
  final renderer = TurnRenderer(s);
  terminal.onLine = renderer.line;
  session.assembly.onWatch = renderer.watch;
  final logSubscription = session.host.session.loop.subscribe(renderer.entry);
  var busy = false;
  final queued = Queue<String>();
  StreamSubscription<ScreenLayout>? resizeSubscription;

  // The editor owns the raw bytes; where its keys go is decided below.
  late final LineEditor editor =
      editorFor != null ? editorFor(s) : LineEditor(screen: s);
  final settings = SettingsPanel(s, editor);
  session.assembly.openSettings = () async {
    try {
      final saved = await settings.run(
          path: session.assembly.configPath,
          descriptors: session.assembly.descriptors,
          validatePlugins: session.assembly.validatePlugins,
          pluginIds: session.assembly.pluginSettings.registry.ids);
      terminal.writeln(saved
          ? 'Settings saved. Changes apply on next launch.'
          : 'Settings unchanged.');
    } catch (_) {
      terminal.writeln(
          'Could not open settings. Check the config file and its permissions.');
    }
  };

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
  final console = consoleContextFor?.call(s, editor) ??
      ConsoleContext(screen: s, editor: editor);
  final attached = <ConsoleContribution>[];
  void repaintContributions() {
    for (final contribution in attached) {
      contribution.repaintConsole();
    }
  }

  void attachContribution(AgentPlugin plugin) {
    if (plugin is! ConsoleContribution) return;
    final contribution = plugin as ConsoleContribution;
    try {
      contribution.attachConsole(console);
      attached.add(contribution);
    } catch (_) {
      try {
        contribution.detachConsole();
      } catch (_) {}
      rethrow;
    }
  }

  void detachContribution(AgentPlugin plugin) {
    if (plugin is! ConsoleContribution) return;
    final contribution = plugin as ConsoleContribution;
    attached.remove(contribution);
    contribution.detachConsole();
  }

  session.assembly.pluginManager.onLoaded = attachContribution;
  session.assembly.pluginManager.onUnloading = detachContribution;

  var ownsTty = false;
  bool? previousEchoMode;
  bool? previousLineMode;
  try {
    for (final contribution in contributions) {
      attached.add(contribution);
      contribution.attachConsole(console);
    }
    // Raw mode only when this loop opened the real screen and there is
    // a controlling terminal; tolerantly skipped everywhere else — a
    // test harness drives events by hand and has no tty to change. An
    // injected screen still renders (alt screen below), it just never
    // touches the process's tty.
    ownsTty = screen == null && s.io.hasTerminal;
    if (ownsTty) {
      try {
        previousEchoMode = io.stdin.echoMode;
        previousLineMode = io.stdin.lineMode;
        io.stdin.echoMode = false;
        io.stdin.lineMode = false;
      } catch (_) {}
    }
    if (!s.passthrough) s.enterAltScreen();

    // First paint: what the assembly already knows — the config note it
    // read, the resumed log it seeded — then the status strip and the
    // empty input row, all in one frame.
    s.frame(() {
      s.redrawFrame();
      final note = session.assembly.configNote;
      if (note != null) s.chat.writeln(note);
      for (final e in session.host.session.loop.log) {
        final line = _entryLine(e);
        if (line != null) s.chat.writeln(line);
      }
      _paintStatus(s, session, busy: false);
      s.input.render(prompt: '› ', buffer: '', cursor: 0);
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
      _paintStatus(s, session, busy: busy);
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
      _paintStatus(s, session, busy: false);
      repaintContributions();
      final line =
          queued.isEmpty ? await editor.readLine('› ') : queued.removeFirst();
      if (line == null) break; // stdin closed
      if (line.isEmpty) continue;
      busy = true;
      _paintStatus(s, session, busy: true);
      editor.beginCancelMonitor(() {
        if (session.assembly.watchingTurn)
          session.host.session.loop.cancel('escape');
      }, onQueueSubmit: queued.addLast, queueCount: queued.length);
      try {
        await session.runLine(line, renderReply: false);
      } finally {
        busy = false;
        editor.endInputCaptureWindow();
        renderer.finishLine();
      }
      // Refresh frontend contributions before returning to the editor.
      repaintContributions();
    }
    return 0;
  } finally {
    await resizeSubscription?.cancel();
    session.host.session.loop.unsubscribe(logSubscription);
    session.assembly.onWatch = null;
    session.assembly.openSettings = null;
    session.assembly.pluginManager.onLoaded = null;
    session.assembly.pluginManager.onUnloading = null;
    editor.onDoubleEscape = null;
    for (final contribution in attached.reversed) {
      contribution.detachConsole();
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
    editor.close(reportLatency: false);
    s.dispose();
    if (!s.passthrough) s.leaveAltScreen();
    editor.reportInputLatency();
    session.close();
  }
}

/// The status strip: the mode word the tools plugin carries, then
/// the busy marker while a turn runs.
void _paintStatus(Screen s, TuiSession session, {required bool busy}) {
  final label = 'mode: ${session.modeWord}${busy ? '  ·  thinking…' : ''}';
  s.setModeLabel(label);
}

/// The one line a resumed log entry renders as — or null when the entry
/// is bookkeeping a restart need not replay (tool traffic, turn ends).
String? _entryLine(SessionEntry e) {
  if (e is InputRecordedEntry) return 'you: ${e.text}';
  if (e is MessageAppendedEntry && e.message.role == Role.assistant) {
    final text = [
      for (final b in e.message.content)
        if (b is TextBlock) b.text,
    ].join();
    return text.isEmpty ? null : 'tina: $text';
  }
  return null;
}

/// The real screen: size off the process's stdout, ANSI backend, no
/// menu bar — one chat panel, one status row, one input row. Without a
/// terminal there is no size to ask for (`terminalColumns` throws on a
/// pipe), so debug and CI runs fall back to a conventional 80×24.
Screen _newScreen({Theme? theme}) {
  var columns = 80;
  var lines = 24;
  if (io.stdout.hasTerminal) {
    columns = io.stdout.terminalColumns;
    lines = io.stdout.terminalLines;
  }
  return Screen(
    io: const _AppStdio(),
    theme: theme ?? const Theme.defaults(),
    layout: ScreenLayout.fromSize(columns, lines, split: false),
  );
}

/// This app has one input owner and performs no terminal probes. Let its
/// input backend cancel the actual stdin subscription on shutdown; the
/// shared LiveStdio relay deliberately outlives individual subscribers.
class _AppStdio extends LiveStdio {
  const _AppStdio();

  @override
  Stream<List<int>> get stdin => io.stdin;
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
Future<bool> runConfigEditor(String path) async {
  final screen = _newScreen();
  final editor = LineEditor(screen: screen);
  final panel = SettingsPanel(screen, editor);
  final echo = io.stdin.echoMode;
  final line = io.stdin.lineMode;
  StreamSubscription<io.ProcessSignal>? resize;
  try {
    io.stdin.echoMode = false;
    io.stdin.lineMode = false;
    screen.enterAltScreen();
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
        validatePlugins: registry.validate);
  } finally {
    await resize?.cancel();
    io.stdin.echoMode = echo;
    io.stdin.lineMode = line;
    editor.close(reportLatency: false);
    screen.dispose();
    screen.leaveAltScreen();
  }
}
