import 'dart:async';
import 'dart:collection';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

/// UI-only workspace: session creation/execution is supplied by the app.
final class PanelsTuiPlugin extends AgentPlugin
    implements ConsoleContribution, ConsoleWorkspace {
  PanelsTuiPlugin({required this.terminal});
  final Terminal terminal;
  @override
  String get id => 'tina/panels-tui';
  ConsoleContext? _console;
  _Workspace? _workspace;
  @override
  List<Command> get commands => [
        Command(
            name: 'spawn',
            description: 'open a conversation panel [/spawn provider/model]',
            handler: (argument) async => _panels
                ?.spawn(argument.trim().isEmpty ? null : argument.trim())),
        Command(
            name: 'panels',
            description: 'list conversation panels (Ctrl+G / Ctrl+W cycles)',
            handler: (_) {
              for (final line in _panels?.describe() ?? const <String>[]) {
                terminal.writeln(line);
              }
            }),
        Command(
            name: 'close',
            description: 'close the focused panel (Ctrl+X)',
            handler: (_) async => _panels?.closeFocused()),
      ];
  ConsolePanels? get _panels {
    final panels = _console?.panels;
    if (panels == null)
      terminal.writeln('Panels require the interactive console.');
    return panels;
  }

  @override
  void attachConsole(ConsoleContext context) {
    _console = context;
  }

  @override
  void detachConsole() {
    _console = null;
  }

  @override
  void repaintConsole() => _workspace?.repaint();
  @override
  Future<int> runConsole(ConsoleContext context, ConsoleSessionView initial,
      Future<ConsoleSessionView> Function(String? model) createSession) async {
    final workspace = _Workspace(context, initial, createSession);
    _workspace = workspace;
    try {
      return await workspace.run();
    } finally {
      _workspace = null;
    }
  }
}

final class _View {
  _View(this.session, this.frame, this.chat);
  final ConsoleSessionView session;
  final PanelFrame frame;
  final ScrollingTextRegion chat;
  late ConsoleContext context;
  final queue = Queue<String>();
  final history = <String>[];
  Future<void>? task;
  bool closed = false;
}

final class _Workspace implements ConsolePanels {
  _Workspace(this.context, this.initial, this.createSession);
  final ConsoleContext context;
  final ConsoleSessionView initial;
  final Future<ConsoleSessionView> Function(String? model) createSession;
  final focus = FocusManager();
  final views = <_View>[];
  final done = Completer<void>();
  final closing = <Future<void>>[];
  Future<void> _spawns = Future.value();
  _View? active;
  bool painting = false, stopped = false, maximized = false;
  int width = -1, height = -1, visibleIndex = 0;
  int _nextPanel = 1;
  LineEditor get editor => context.input;
  Screen get screen => context.screen;

  Future<int> run() async {
    final previousFocus = editor.focusManager;
    final removeKey = context.bindShortcut(_key);
    editor.focusManager = focus;
    try {
      _add(initial, screen.chat);
      await Future.any([editor.readLines('› ', onLine: _submit), done.future]);
      return 0;
    } finally {
      stopped = true;
      removeKey();
      editor.focusManager = previousFocus;
      for (final view in views) {
        view.queue.clear();
        view.session.cancel();
      }
      await _spawns;
      await Future.wait([
        for (final view in views)
          if (view.task != null) view.task!,
        ...closing
      ]);
      for (final view in views.reversed) {
        view.session.detachConsole();
        view.chat.detach();
        view.frame.dispose();
        if (!identical(view.session, initial)) view.session.close();
      }
      views.clear();
      screen.input.setBoundsOverride(null);
    }
  }

  void _submit(String line) {
    final target = active;
    if (stopped || target == null || target.closed || line.isEmpty) return;
    target.frame.inputBuffer = '';
    target.frame.inputCursor = 0;
    target.history.add(line);
    final parts = line.trim().split(RegExp(r'\s+'));
    switch (parts.first) {
      case '/spawn':
        unawaited(spawn(parts.length > 1 ? parts.skip(1).join(' ') : null));
      case '/panels':
        for (final description in describe()) {
          target.session.notice(description);
        }
      case '/close':
        unawaited(closeFocused());
      default:
        target.queue.add(line);
        target.task ??= _drain(target);
    }
  }

  void _add(ConsoleSessionView session, ScrollingTextRegion chat) {
    final frame = PanelFrame(
        screen: screen,
        label: '${_nextPanel++}: ${session.label}',
        conversationId: session.id,
        border: false);
    final view = _View(session, frame, chat);
    view.context = context.forView(
        chat: chat,
        isActive: () => !stopped && !view.closed && identical(active, view),
        activate: () {
          if (!view.closed && !stopped) focus.focusPanel(frame);
        },
        panels: this);
    frame.onFocus = () => _focus(view);
    frame.onHighlight = () {
      visibleIndex = views.indexOf(view);
      _layout();
    };
    frame.onScroll = (pages) => chat.scrollBy(pages * chat.usableHeight);
    frame.onWheel = chat.scrollBy;
    frame.inputPrompt = () => '${session.label} > ';
    frame.onInputChanged = () => identical(active, view) && editor.isEditing;
    views.add(view);
    focus.register(frame);
    final previous = active;
    active ??= view;
    try {
      // Install scoped bindings before focus so the new model owns its prompt.
      session.attachConsole(view.context);
      _layout();
      focus.home ??= frame;
      focus.focusPanel(frame);
      _focus(view);
    } catch (_) {
      view.closed = true;
      views.remove(view);
      focus.unregister(frame);
      session.detachConsole();
      chat.detach();
      frame.dispose();
      active = previous;
      if (previous != null) {
        visibleIndex = views.indexOf(previous);
        screen.setActiveChat(previous.chat);
        _layout();
      }
      rethrow;
    }
  }

  void _focus(_View view) {
    if (stopped || view.closed) return;
    final old = active;
    if (old != null && !identical(old, view) && editor.isEditing) {
      final draft = editor.editState;
      old.frame.inputBuffer = draft.buffer;
      old.frame.inputCursor = draft.cursor;
    }
    active = view;
    visibleIndex = views.indexOf(view);
    screen.setActiveChat(view.chat);
    editor.commandProvider = view.session.commandCompletion;
    editor.completionProvider = view.session.fileCompletion;
    editor.restoreHistory(view.history);
    _layout();
    editor.loadEditState(view.frame.inputBuffer, view.frame.inputCursor);
    context.refreshStatus();
  }

  void _layout() {
    if (painting || stopped || views.isEmpty) return;
    painting = true;
    try {
      screen.frame(() {
        final layout = screen.layout;
        width = layout.width;
        height = layout.height;
        final slots = views.length > 1 && width >= 100 && !maximized ? 2 : 1;
        final first = visibleIndex.clamp(0, views.length - 1) ~/ slots * slots;
        for (final view in views) {
          view.chat.detach();
        }
        screen.eraseChatArea();
        screen.input.erase();
        for (var i = 0; i < views.length; i++) {
          final view = views[i];
          final visible = i >= first && i < first + slots;
          final columnWidth = width ~/ slots;
          final rect = views.length == 1
              ? Rect(
                  row: layout.chat.row,
                  col: layout.chat.col,
                  width: layout.chat.width,
                  height: layout.inputRow - layout.chat.row + 1)
              : Rect(
                  row: layout.chat.row,
                  col: (i - first) * columnWidth,
                  width: i == first + slots - 1
                      ? width - columnWidth * (slots - 1)
                      : columnWidth,
                  height: layout.stripRow - layout.chat.row);
          view.frame.setBorder(views.length > 1 && height >= 8);
          view.frame.setOuter(rect, parked: !visible);
          view.frame.setReservesInput(true);
          ChatRegionPanelContent(view.chat)
              .fit(view.frame.interior, reserveInputRow: true);
          if (visible) view.chat.attach();
        }
        final selected = active!;
        screen.input.setBoundsOverride(
            selected.frame.isParked ? Rect.empty : selected.frame.inputRect);
        for (final view in views) {
          view.session.repaintConsole();
          view.frame.render();
        }
        context.refreshStatus();
        context.refreshInput();
      });
    } finally {
      painting = false;
    }
  }

  void repaint() {
    if (painting || stopped) return;
    if (width != screen.layout.width || height != screen.layout.height)
      _layout();
  }

  bool _key(InputEvent event) {
    if (editor.isReadingKey) return false;
    if (focus.isCycling &&
        (event is EscapeKey ||
            event is ControlKey &&
                (event.code == ControlCode.ctrlG ||
                    event.code == ControlCode.ctrlW))) {
      focus.cancel();
      visibleIndex = views.indexOf(active!);
      _layout();
      return true;
    }
    if (event is ControlKey && event.code == ControlCode.ctrlX) {
      unawaited(closeFocused());
      return true;
    }
    if (event is ControlKey && event.code == ControlCode.ctrlO) {
      maximized = !maximized;
      _layout();
      return true;
    }
    if (focus.isCycling) return false;
    if (event is EscapeKey && !editor.isCompleting && active?.task != null) {
      if (editor.editState.buffer.isNotEmpty)
        editor.loadEditState('', 0);
      else
        active!.session.cancel();
      return true;
    }
    return false;
  }

  Future<void> _drain(_View view) async {
    view.frame.setBusy(true);
    try {
      while (!stopped && !view.closed && view.queue.isNotEmpty) {
        await view.session.submit(view.queue.removeFirst());
        if (view.session.quitRequested) {
          if (!done.isCompleted) done.complete();
          break;
        }
      }
    } catch (error) {
      if (!view.closed && !stopped) view.session.notice('Panel error: $error');
    } finally {
      view.task = null;
      view.frame.setBusy(false);
      if (!view.closed && !stopped) view.session.repaintConsole();
    }
  }

  @override
  Future<void> spawn([String? model]) {
    final source = active;
    final operation = _spawns.then((_) async {
      if (stopped) return;
      try {
        final session = await createSession(model ?? source?.session.label);
        if (stopped) {
          session.close();
          return;
        }
        final chat = ScrollingTextRegion(screen)..detach();
        try {
          _add(session, chat);
        } catch (_) {
          session.close();
          rethrow;
        }
      } catch (error) {
        if (!stopped && source?.closed == false)
          source!.session.notice('Could not open panel: $error');
      }
    });
    _spawns = operation;
    return operation;
  }

  @override
  Future<void> closeFocused() async {
    final view = active;
    if (view == null || view.closed || stopped) return;
    if (views.length == 1) {
      view.session.notice('This is the last panel. Use /quit to exit.');
      return;
    }
    view.closed = true;
    view.queue.clear();
    view.session.cancel();
    final index = views.indexOf(view);
    views.remove(view);
    focus.unregister(view.frame);
    view.chat.detach();
    view.frame.dispose();
    active = null;
    focus.home = views.first.frame;
    focus.focusPanel(views[index.clamp(0, views.length - 1)].frame);
    _layout();
    final close = () async {
      await view.task;
      view.session.detachConsole();
      if (!identical(view.session, initial)) view.session.close();
    }();
    closing.add(close);
    await close;
  }

  @override
  List<String> describe() => [
        for (final view in views)
          '${identical(view, active) ? '*' : ' '} ${view.frame.label} · ${view.task == null ? 'idle' : 'running'} · ${view.session.id}'
      ];
}
