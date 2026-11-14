import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:tina_console/tina_console.dart';
import 'package:tina_layout/tina_layout.dart';
import 'panels_status.dart';
import 'prompt.dart';

/// UI-only workspace: session creation/execution is supplied by the app.
///
/// Since the image panel work it also opens [ImagePanelSpec] panels
/// (`/image <path>` or the [openImagePanel] helper plugins use).
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
      'image' => _openImageCommandLine(arguments),
      _ => null,
    };
  }

  Future<void>? _openImageCommandLine(String arguments) {
    final path = arguments.trim();
    if (path.isEmpty) return null;
    final panels = _console!.panels;
    if (panels case ImagePanelOpener opener) {
      final stem = path.split(RegExp(r'[\\/]')).last;
      return opener.openImagePanel(
          ImagePanelSpec(path: path, label: 'image: $stem'));
    }
    return null;
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

final class _ImagePanel {
  _ImagePanel(this.frame, this.content);
  final PanelFrame frame;
  final ImagePanelContent content;
}

final class _Workspace implements ConsolePanels, ImagePanelOpener {
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

  // -- Image panels -------------------------------------------------------

  final imagePanels = <_ImagePanel>[];
  final _decodedImages = <String, ConsoleImage?>{};

  static const _maxDecodedImages = 8;

  Future<void> openImagePanel(ImagePanelSpec spec) async {
    if (stopped) return;
    final path = spec.path;
    final Uint8List bytes;
    try {
      bytes = spec.bytes ?? await File(path!).readAsBytes();
    } catch (error) {
      active?.session.notice('Image panel: cannot read '
          '${path ?? '<bytes>'}: $error');
      return;
    }
    final cacheKey = path ?? 'bytes:${bytes.length}:${identityHashCode(bytes)}';
    var decoded = _decodedImages[cacheKey];
    if (decoded == null && !_decodedImages.containsKey(cacheKey)) {
      // Decode off the UI thread: package:image work on a multi-megapixel
      // file visibly janks the editor loop otherwise.
      decoded = await Isolate.run(() => ConsoleImage.decode(bytes));
      if (_decodedImages.length >= _maxDecodedImages) _decodedImages.clear();
      _decodedImages[cacheKey] = decoded;
    }
    if (stopped) return;
    if (decoded == null) {
      active?.session
          .notice('Image panel: ${path ?? 'bytes'} is not a decodable image.');
      return;
    }
    final content = ImagePanelContent(screen, label: spec.label);
    content.image = decoded;
    final frame = PanelFrame(
        screen: screen, label: spec.label, conversationId: 'image-panel');
    frame.onPanelKey = (event) {
      // q or Esc closes an image panel - it has no editor of its own.
      // Escape arrives as a raw 0x1b char in this input layer.
      if (event is CharInput &&
          (event.text == 'q' || event.text == '\x1b')) {
        closeImagePanel(frame);
        return true;
      }
      return false;
    };
    final panel = _ImagePanel(frame, content);
    imagePanels.add(panel);
    focus.register(frame);
    frame.onFocus = () {};
    _layoutImagePanels();
    content.fit(frame.interior, reserveInputRow: false);
    content.attach();
    focus.focusPanel(frame);
  }

  void closeImagePanel(PanelFrame frame) {
    final index = imagePanels.indexWhere((panel) => panel.frame == frame);
    if (index < 0) return;
    final panel = imagePanels.removeAt(index);
    final bounds = frame.bounds;
    focus.unregister(frame);
    screen.frame(() {
      panel.content.detach();
      for (var row = bounds.row; row < bounds.row + bounds.height; row++) {
        screen.eraseAtAbsolute(
            row: row, col: bounds.col, n: bounds.width, moveCursor: false);
      }
    });
    if (identical(focus.focused, frame)) {
      focus.focusPanel(active?.frame ?? panelStatus);
    }
    _layoutImagePanels();
  }

  /// Right-anchored overlay column over the chat box, one stacked panel per
  /// open image. Solved by the tina_layout grid: the panel column takes two
  /// fifths of the chat box (clamped 24..64 columns) and each panel's row
  /// track is sized from its image's aspect hint in square units, so the
  /// frame is proportional to the image it holds. When the stack cannot
  /// fit, the solver drops the oldest panels first (priority = age).
  void _layoutImagePanels() {
    if (stopped) return;
    if (imagePanels.isEmpty) return;
    // Panels the solver could not keep (tiny terminals, deep stacks). Built
    // inside the paint frame, closed after it — closing relayouts the
    // survivors, so this loop terminates (each pass removes one panel).
    final overflowed = <PanelFrame>[];
    screen.frame(() {
      final layout = screen.layout;
      final regionWidth = layout.chatRightCol - layout.chatLeftCol + 1;
      final bodyHeight = layout.stripRow - layout.chat.row;
      const metrics = CellMetrics.standard;
      final count = imagePanels.length;
      // Equal shares of the body below the chat box's top border row.
      final shareUnits = metrics.rowsToUnits(bodyHeight - 1) / count;
      final solution = LayoutStrategies.solve(
          GridSpec(
              columns: const [
                GridTrack.weighted(3),
                GridTrack.weighted(2, minUnits: 24, maxUnits: 64),
              ],
              rows: [
                const GridTrack.fixed(0.5), // chat box top border row
                for (var i = 0; i < count; i++) const GridTrack.auto(minUnits: 3),
              ],
              items: [
                for (var i = 0; i < count; i++)
                  GridItem(
                    id: 'panel$i',
                    column: const TrackSpan.at(1),
                    row: TrackSpan.at(i + 1),
                    minWidthUnits: 24,
                    minHeightUnits: 3,
                    maxHeightUnits: shareUnits,
                    // Square-unit aspect of the decoded image keeps the box
                    // proportional to the image it frames.
                    aspectHint: () {
                      final image = imagePanels[i].content.image;
                      return image == null
                          ? null
                          : metrics.aspectFromPixels(
                              image.width, image.height);
                    }(),
                    // Oldest panels are dropped first when space runs out.
                    priority: i,
                  ),
              ]),
          columns: regionWidth,
          rows: bodyHeight,
          metrics: metrics);
      for (var i = 0; i < count; i++) {
        final panel = imagePanels[i];
        final rect = solution.rectOf('panel$i');
        if (rect == null || rect.isEmpty) {
          overflowed.add(panel.frame);
          continue;
        }
        panel.frame.setBorder(true);
        panel.frame.setOuter(
            Rect(
              row: layout.chat.row + rect.row,
              col: layout.chatLeftCol + rect.col,
              width: rect.width,
              height: rect.height,
            ),
            parked: false);
        panel.content.fit(panel.frame.interior, reserveInputRow: false);
      }
    });
    for (final frame in overflowed) {
      closeImagePanel(frame);
    }
  }

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
    final previousCancelRequest = editor.onCancelRequest;
    final previousDoubleEscape = editor.onDoubleEscape;
    editor.onCancelRequest = editor.onDoubleEscape = () {
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
      editor.onCancelRequest = previousCancelRequest;
      editor.onDoubleEscape = previousDoubleEscape;
      for (final view in views.reversed) {
        closing.add(_closeView(view));
      }
      views.clear();
      for (final panel in imagePanels) {
        panel.content.detach();
        panel.frame.dispose();
      }
      imagePanels.clear();
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
      case '/image':
        if (parts.length < 2) {
          target.session.notice('usage: /image <file-path>');
        } else {
          unawaited(openImagePanel(ImagePanelSpec(
              path: parts.skip(1).join(' '),
              label: 'image: ${parts.skip(1).join(' ').split(RegExp(r'[\\\\/]')).last}')));
        }
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
        _layoutImagePanels();
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
    // An image panel focused? Close that, not the conversation behind it.
    final focused = focus.focused;
    final image = imagePanels
        .where((panel) => identical(panel.frame, focused))
        .firstOrNull;
    if (image != null) {
      closeImagePanel(image.frame);
      return;
    }
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
