import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'panels_status.dart';
import 'prompt.dart';

/// UI-only workspace: session creation/execution is supplied by the app.
final class PanelsView
    implements ConsoleContribution, ConsoleWorkspace, ConsoleCommandHandler {
  PanelsView();
  ConsoleContext? _console;
  _Workspace? _workspace;
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    final panels = _console?.panels;
    if (panels == null) return null;
    return switch (name) {
      'spawn' =>
        panels.spawn(arguments.trim().isEmpty ? null : arguments.trim()),
      'close' => panels.closeFocused(),
      _ => null,
    };
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
      Future<ConsoleSessionView> Function(String? model) createSession,
      {ConsoleViewClosed? onViewClosed}) async {
    final workspace = _Workspace(context, initial, createSession, onViewClosed);
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
  final history = <String>[];
  final submissions = <Future<void>>{};
  void Function()? unbindQueueStatus, releaseActivity;
  bool closed = false, minimized = false;
}

final class _Workspace implements ConsolePanels {
  _Workspace(this.context, this.initial, this.createSession, this.onViewClosed);
  final ConsoleContext context;
  final ConsoleSessionView initial;
  final Future<ConsoleSessionView> Function(String? model) createSession;
  final ConsoleViewClosed? onViewClosed;
  final focus = FocusManager();
  final views = <_View>[];
  final done = Completer<void>();
  final closing = <Future<void>>[];
  Future<void> _spawns = Future.value();
  _View? active;
  bool painting = false, stopped = false, maximized = false;
  int width = -1, height = -1, visibleIndex = 0;
  int _nextPanel = 1;
  int _themeEpoch = -1;
  late final PanelsStatus panelStatus = PanelsStatus(
      context: context,
      choices: () => [
            for (final view in views)
              PanelChoice(
                  view.frame.label,
                  view.minimized
                      ? 'minimized'
                      : view.frame.isParked
                          ? 'hidden'
                          : maximized
                              ? 'maximized'
                              : 'visible',
                  hidden: view.minimized || view.frame.isParked)
          ],
      restore: (index) {
        final view = views[index];
        view.minimized = false;
        focus.focusPanel(view.frame);
      },
      minimize: _minimize,
      maximize: _maximize,
      onDismiss: () {
        for (final view in views) view.frame.render();
      });
  LineEditor get editor => context.input;
  Screen get screen => context.screen;

  Future<int> run() async {
    final previousFocus = editor.focusManager;
    final previousDoubleEscape = editor.onDoubleEscape;
    editor.onDoubleEscape = () {
      if (active?.session.canCancel != true) return false;
      active!.session.cancel();
      return true;
    };
    final removeKey = context.bindShortcut(_key);
    final releasePanelStatus =
        context.bindStatus(panelStatus.status, priority: -10);
    editor.focusManager = focus;
    try {
      _add(initial, screen.chat);
      await Future.any([editor.readLines('› ', onLine: _submit), done.future]);
      return 0;
    } finally {
      stopped = true;
      focus.unregister(panelStatus);
      panelStatus.dispose();
      releasePanelStatus();
      removeKey();
      editor.focusManager = previousFocus;
      editor.onDoubleEscape = previousDoubleEscape;
      for (final view in views.reversed) {
        closing.add(_closeView(view));
      }
      views.clear();
      screen.input.setBoundsOverride(null);
      // Late creations also release their view and notify its application
      // owner. Borrowed sessions never hold workspace teardown open.
      await _spawns;
      await Future.wait(closing);
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
      case '/close':
        unawaited(closeFocused());
      default:
        late final Future<void> work;
        work = target.session.submit(line).catchError((Object error) {
          if (!target.closed && !stopped)
            target.session.notice('Panel error: $error');
        }).whenComplete(() => target.submissions.remove(work));
        target.submissions.add(work);
    }
  }

  void _add(ConsoleSessionView session, ScrollingTextRegion chat) {
    final frame = PanelFrame(
        screen: screen,
        label: '${_nextPanel++}: ${session.label}',
        conversationId: session.id,
        border: false);
    final view = _View(session, frame, chat);
    if (session is ConsoleInputHistory) {
      view.history.addAll((session as ConsoleInputHistory).inputHistory);
    }
    view.context = context.forView(
        chat: chat,
        isActive: () => !stopped && !view.closed && identical(active, view),
        activate: () {
          if (!view.closed && !stopped) focus.focusPanel(frame);
        },
        panels: this);
    view.unbindQueueStatus = view.context.bindStatus(() {
      final count = session.pendingInputCount;
      return count == 0
          ? []
          : [
              RenderLine(align: StatusAlign.right, runs: [
                RenderRun(
                    '$count ${count == 1 ? 'message' : 'messages'} queued',
                    screen.theme.chat.yellow)
              ])
            ];
    }, priority: 0);
    frame.onFocus = () => _focus(view);
    frame.onHighlight = () {
      visibleIndex = views.indexOf(view);
      _layout();
    };
    frame.onScroll = (pages) => chat.scrollBy(pages * chat.usableHeight);
    frame.onWheel = chat.scrollBy;
    frame.inputPrompt = () {
      final shell = conversationInputPrefixLength(frame.inputBuffer) > 0;
      return '${session.label} ${shell ? '!' : '>'} ';
    };
    frame.hiddenInputPrefixLength = conversationInputPrefixLength;
    frame.onInputChanged = () => identical(active, view) && editor.isEditing;
    views.add(view);
    focus.register(frame);
    final previous = active;
    active ??= view;
    try {
      // Install scoped bindings before focus so the new model owns its prompt.
      session.attachConsole(view.context);
      view.releaseActivity = session.listenActivity(() {
        if (stopped || view.closed) return;
        final label = '${frame.label.split(':').first}: ${session.label}';
        if (frame.label != label) {
          frame.relabel(label);
          panelStatus.refresh();
          if (identical(active, view)) view.context.refreshInput();
        }
        frame.setBusy(session.busy);
        view.context.refreshStatus();
        if (session.quitRequested && !done.isCompleted) done.complete();
      });
      // Keep status controls after conversation/plugin views in the ring.
      focus.unregister(panelStatus);
      focus.register(panelStatus);
      _layout();
      focus.home ??= frame;
      focus.focusPanel(frame);
      _focus(view);
    } catch (_) {
      view.closed = true;
      views.remove(view);
      focus.unregister(frame);
      session.detachConsole();
      view.releaseActivity?.call();
      view.unbindQueueStatus?.call();
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
    view.minimized = false;
    final old = active;
    if (old != null && !identical(old, view) && editor.isEditing) {
      final draft = editor.editState;
      old.frame.inputBuffer = draft.buffer;
      old.frame.inputCursor = draft.cursor;
    }
    active = view;
    focus.home = view.frame;
    visibleIndex = views.indexOf(view);
    screen.setActiveChat(view.chat);
    editor.commandProvider = view.session.commandCompletion;
    editor.completionProvider = view.session.fileCompletion;
    editor.restoreHistory(view.history);
    _layout();
    // Returning from a plugin panel in this same conversation keeps the live
    // editor draft. Saved per-conversation drafts are for session switches.
    if (!identical(old, view)) {
      editor.loadEditState(view.frame.inputBuffer, view.frame.inputCursor);
    }
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
        final shown = views.where((v) => !v.minimized).toList();
        final slots = shown.length > 1 && width >= 100 && !maximized ? 2 : 1;
        final preview = views[visibleIndex.clamp(0, views.length - 1)];
        final first =
            shown.indexOf(preview).clamp(0, shown.length) ~/ slots * slots;
        for (final view in views) {
          view.chat.detach();
        }
        // Frames extend through the row below the normal input. Clear the
        // entire workspace so old rails and offscreen panels cannot survive
        // a layout change. The status strip is painted separately below it.
        for (var row = layout.chat.row; row < layout.stripRow; row++) {
          screen.eraseAtAbsolute(row: row, col: 0, n: width, moveCursor: false);
        }
        for (var i = 0; i < views.length; i++) {
          final view = views[i];
          final slot = shown.indexOf(view);
          final visible = slot >= first && slot < first + slots;
          final columnWidth = width ~/ slots;
          final rect = views.length == 1
              ? Rect(
                  row: layout.chat.row,
                  col: layout.chat.col,
                  width: layout.chat.width,
                  height: layout.inputRow - layout.chat.row + 1)
              : Rect(
                  row: layout.chat.row,
                  col: (slot - first) * columnWidth,
                  width: slot == first + slots - 1
                      ? width - columnWidth * (slots - 1)
                      : columnWidth,
                  height: layout.stripRow - layout.chat.row);
          view.frame.setBorder(views.length > 1 && height >= 8);
          view.frame.cycleWhenParked = !view.minimized;
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
          view.frame.relabel(
              '${view.frame.label.split(':').first}: ${view.session.label}');
          view.session.repaintConsole();
          view.frame.render();
        }
        panelStatus.refresh();
        context.refreshInput();
      });
    } finally {
      painting = false;
    }
  }

  void repaint() {
    if (painting || stopped) return;
    // _layout() re-renders every frame's chrome (labels, rails, borders) with
    // the current theme, so a theme change must go through it even though no
    // geometry changed — otherwise panel borders keep the old colors until
    // the next resize or panel switch.
    if (_themeEpoch != screen.themeEpoch) {
      _themeEpoch = screen.themeEpoch;
      _layout();
      return;
    }
    if (width != screen.layout.width || height != screen.layout.height)
      _layout();
  }

  void _minimize(int index) {
    final view = views[index];
    view.minimized = true;
    if (identical(view, active)) {
      final replacement = views.where((v) => !v.minimized).firstOrNull;
      if (replacement != null) {
        _focus(replacement);
        return;
      }
    }
    _layout();
  }

  void _maximize(int index) {
    final view = views[index];
    final wasMaximized =
        maximized && identical(view, active) && !view.minimized;
    maximized = !wasMaximized;
    view.minimized = false;
    _focus(view);
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
    if (event is EscapeKey &&
        !editor.isCompleting &&
        identical(focus.focused, active?.frame) &&
        active?.session.busy == true) {
      if (editor.editState.buffer.isNotEmpty)
        editor.loadEditState('', 0);
      else
        active!.session.cancel();
      return true;
    }
    return false;
  }

  @override
  Future<void> spawn([String? model]) {
    final source = active;
    final operation = _spawns.then((_) async {
      if (stopped) return;
      try {
        final session = await createSession(model);
        if (stopped) {
          await _releaseSession(session, Future.value());
          return;
        }
        final chat = ScrollingTextRegion(screen)..detach();
        try {
          _add(session, chat);
        } catch (_) {
          await _releaseSession(session, Future.value());
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
    final index = views.indexOf(view);
    views.remove(view);
    focus.unregister(view.frame);
    final close = _closeView(view);
    active = null;
    focus.home = views.first.frame;
    focus.focusPanel(views[index.clamp(0, views.length - 1)].frame);
    _layout();
    closing.add(close);
    await close;
  }

  Future<void> _closeView(_View view) async {
    view.closed = true;
    final pending = Future.wait<void>(view.submissions).then<void>((_) {});
    // The owner may choose not to wait. Submission handlers already
    // report failures while attached; retain no unhandled future on detach.
    pending.ignore();
    late final Future<void> released;
    try {
      released = _releaseSession(view.session, pending);
    } finally {
      view.unbindQueueStatus?.call();
      view.releaseActivity?.call();
      view.chat.detach();
      view.frame.dispose();
    }
    // Dispose presentation immediately, before awaiting application-owned work.
    return released;
  }

  Future<void> _releaseSession(
      ConsoleSessionView session, Future<void> pending) async {
    try {
      session.close();
    } finally {
      await onViewClosed?.call(session, pending);
    }
  }

  @override
  List<String> describe() => [
        for (final view in views)
          '${identical(view, active) ? '*' : ' '} ${view.frame.label} · ${view.session.busy ? 'running' : 'idle'} · ${view.session.id}'
      ];
}
