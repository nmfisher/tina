import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:logging/logging.dart';

import 'package:tina_engine/tina_engine.dart';

import '../chat_agent_sink.dart';

final _log = Logger('tina.agent.bus');

/// The terminal [HostInterface]: one per conversation. It owns the
/// conversation's [ScrollingTextRegion] and [Spinner], routes agent output to them
/// (reusing [ChatAgentSink]) while also mirroring every call on [eventBus],
/// and renders the interactive permission modal via the shared [LineEditor].
///
/// This is the only [HostInterface] that imports `tina_console`; it is the
/// TUI composition root's per-conversation widget. A conversation that is not
/// on screen is constructed the same way — its [ScrollingTextRegion] starts detached
/// and buffered — and [setActive] is what routes it onto the [Screen]. While a
/// conversation is in the background ([_active] is false) its [askPermission]
/// auto-denies, exactly as the old per-session asker did.
class TuiConversationHost implements HostInterface {
  TuiConversationHost({
    required this.conversationId,
    required this.chat,
    required this.screen,
    required this.spinner,
    this.editor,
    bool active = false,
    this.primary = true,
    this.panel,
  }) : _active = active {
    _logSub = _bus.events.listen(_onBusEvent);
  }

  final String conversationId;
  final ScrollingTextRegion chat;
  final Spinner spinner;
  final Screen screen;

  /// The shared line editor, used to read a single keystroke for the permission
  /// modal. Every conversation shares one editor; only an [_active]
  /// conversation's [askPermission] actually reads from it.
  final LineEditor? editor;

  /// Primary hosts own the `screen.chat` slot and route onto it via [setActive]
  /// (the session-switch path). Secondary hosts (spawned conversations) own a
  /// bounded column-slot [ScrollingTextRegion] that stays attached and renders
  /// continuously; their [setActive] is render-neutral.
  final bool primary;

  /// Tool calls whose streamed output was capped in the chat — the full text
  /// lives here for the `/output` viewer. Newest first; bounded to the last 10.
  /// Populated from the sink's [ChatAgentSink.onCapped].
  final List<CappedToolOutput> cappedOutputs = [];

  /// The [PanelFrame] that frames this host's region. Still used by [clear]
  /// (repaint the chrome after erasing a column slot) and by the coordinator's
  /// relabel path (`/model`). The busy *cue* no longer goes through here — it is
  /// inverted into [onBusyChanged] so the host never reaches into a frame just
  /// to drive its comet. Set after construction for the primary host (its panel
  /// is built after the host); passed at construction for secondary hosts.
  PanelFrame? panel;

  /// Set by the coordinator while spawned panels share the screen. When true,
  /// a primary host's [setActive](false) leaves its region attached and
  /// visible — focus has merely moved to a side panel — instead of detaching
  /// it (the session-switch behavior). Secondary hosts ignore this; their
  /// region is always attached.
  bool stayAttachedWhenInactive = false;

  /// Inverted busy-cue dependency. The coordinator sets this when it binds this
  /// host to a frame; [setActivity]/[setIdle] call it instead of reaching into a
  /// [PanelFrame] directly. null when the host has no frame yet (during the
  /// brief construction gap before the coordinator binds it).
  void Function(bool busy)? onBusyChanged;

  /// Fired when this conversation produces visible output ([text]/[notice])
  /// while in the background (not routed to the screen). The coordinator uses it
  /// to bump the owning session's unread badge (and optionally ring the bell).
  /// null on hosts that don't care (e.g. tests).
  void Function()? onBackgroundActivity;

  bool _active;

  /// Whether this conversation is currently routed to the screen (and thus
  /// entitled to an interactive permission modal). Flipped by [setActive].
  bool get isActive => _active;

  final AgentEventBus _bus = AgentEventBus();

  /// Logs tool lifecycle + notices off the bus so a run is reconstructable
  /// from ~/.tina/tina.log without re-reading the chat. Cancelled in
  /// [dispose].
  StreamSubscription<AgentEvent>? _logSub;

  /// Forwards [AgentSink] calls to the chat region (via [ChatAgentSink]) and,
  /// for the calls that carry an [AgentEvent], mirrors them on [eventBus] (via
  /// [BusSink]). Composing the two means this host renders identically to the
  /// old `ChatAgentSink` while also feeding the bus — no rendering logic
  /// duplicated here.
  late final AgentSink _sink = BusSink(
    ChatAgentSink(chat, spinner, onCapped: (o) {
      cappedOutputs.insert(0, o);
      if (cappedOutputs.length > 10) cappedOutputs.removeLast();
    }),
    _bus,
  );

  @override
  AgentEventBus get eventBus => _bus;

  void _onBusEvent(AgentEvent agentEvent) {
    switch (agentEvent) {
      case ToolAgentEvent(:final event):
        switch (event) {
          case ToolStartEvent():
            _log.fine('[$conversationId] tool start: ${event.toolName}');
          case ToolCompleteEvent():
            _log.fine('[$conversationId] tool complete: ${event.toolName} '
                '(error=${event.isError})');
          case ToolOutputEvent():
            break; // every output chunk — too chatty to log
        }
      case NoticeAgentEvent(:final message, :final kind):
        _log.info('[$conversationId] notice [$kind]: $message');
      case TextAgentEvent():
        break; // streamed prose — too chatty
      case JobAgentEvent():
        break; // sub-agent wrapper; not emitted on this host's own bus
    }
  }

  // --- AgentSink: delegate to the composing sink --------------------------

  @override
  void text(String s) {
    _sink.text(s);
    if (!_active) onBackgroundActivity?.call();
  }

  @override
  void newline() => _sink.newline();

  @override
  void toolStart(ToolStartEvent event) => _sink.toolStart(event);

  @override
  void toolOutput(ToolOutputEvent event) => _sink.toolOutput(event);

  @override
  void toolComplete(ToolCompleteEvent event) => _sink.toolComplete(event);

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {
    _sink.notice(message, kind: kind);
    if (!_active) onBackgroundActivity?.call();
  }

  @override
  void activityStart() => _sink.activityStart();

  @override
  void activityStop() => _sink.activityStop();

  // --- HostInterface ------------------------------------------------------

  @override
  Future<PermissionResponse> askPermission(PermissionPrompt p) async {
    // A background conversation can't take over the terminal for a modal, so
    // refuse (with a dim note) — matching the old per-session asker. Policy
    // allow/deny rules short-circuit before the asker is ever called.
    if (!_active) {
      chat.dim('  ${p.toolName} denied — conversation in background\n');
      return PermissionResponse.denyOnce;
    }
    chat.yellow('  ${p.toolName}: ${p.key}\n');
    final preview = await previewToolCall(p.toolName, p.input);
    for (final entry in preview) {
      switch (entry) {
        case PreviewHeader(:final text):
          chat.dim('  $text\n');
        case PreviewAdded(:final text):
          chat.green('  + $text\n');
        case PreviewRemoved(:final text):
          chat.red('  - $text\n');
        case PreviewContext(:final text):
          chat.dim('    $text\n');
        case PreviewSeparator():
          chat.dim('  ⋯\n');
      }
    }
    // The prompt row stays open across the readKey so the answer character
    // lands on the same line. The row is marked with an ownership token so a
    // background writer (e.g. the environment ceremony) streaming while the
    // approval pends starts its own row instead of merging its text onto the
    // prompt (tin-6a2f).
    final rowToken = Object();
    chat.write('  approve? [y/n/a/d]  '
        '(a/d remember "${p.alwaysPattern}") › ',
        rowOwner: rowToken);
    final event = await editor!.readKey();
    final ch = event is CharInput ? event.text.toLowerCase() : '';
    chat.write('$ch\n', rowOwner: rowToken);
    switch (ch) {
      case 'y':
        return PermissionResponse.allowOnce;
      case 'a':
        return PermissionResponse.allowAlways;
      case 'd':
        return PermissionResponse.denyAlways;
      default:
        return PermissionResponse.denyOnce;
    }
  }

  @override
  void showPreview(List<PreviewEntry> preview) {
    // The TUI renders the preview inline as part of [askPermission]; this is a
    // hook for hosts that separate preview presentation from the prompt.
  }

  @override
  void showMessage(String message,
      {HostMessageStyle style = HostMessageStyle.normal}) {
    final theme = screen.theme.hostMessage;
    switch (style) {
      case HostMessageStyle.normal:
        chat.write(message);
      case HostMessageStyle.user:
        // Policy layer picks the bar code; the surface owns the fallback.
        chat.writeStyledLine(message, screen.theme.chat.userBar);
      case HostMessageStyle.dim:
        chat.write(screen.colorize(theme.dim, message));
      case HostMessageStyle.success:
        chat.write(screen.colorize(theme.success, message));
      case HostMessageStyle.warning:
        chat.write(screen.colorize(theme.warning, message));
      case HostMessageStyle.error:
        chat.write(screen.colorize(theme.error, message));
    }
  }

  @override
  void showSeparator() => chat.separator();

  @override
  void clear() {
    if (primary) {
      screen.clearChat();
      chat.scrollToTail();
      return;
    }
    // Secondary: erase this region's column slot and reset its row buffer,
    // then repaint the panel chrome.
    final b = chat.bounds;
    for (var r = 0; r < b.height; r++) {
      screen.eraseAtAbsolute(
        row: b.row + r,
        col: b.col,
        n: b.width,
        moveCursor: false,
      );
    }
    chat.resetAfterClear();
    chat.scrollToTail();
    panel?.render();
  }

  @override
  void setActivity(bool active) {
    // Every conversation's busy cue is its frame's comet (primary and spawned
    // alike). Inverted from a typed panel back-reference into [onBusyChanged]
    // so the host never reaches into a [PanelFrame]. Falls back to the panel
    // back-reference while the coordinator hasn't bound a frame yet.
    final cue = onBusyChanged;
    if (cue != null) {
      cue(active);
    } else {
      panel?.setBusy(active);
    }
    active ? spinner.start() : spinner.stop();
  }

  @override
  void setIdle(bool active) {
    // idle ≡ not busy: clear this conversation's busy cue so switching to an
    // idle conversation doesn't leave a stale signal from the previous one
    // (_present calls this on the incoming conversation when it isn't running).
    final cue = onBusyChanged;
    if (cue != null) {
      if (active) cue(false);
    } else if (active) {
      panel?.setBusy(false);
    }
    active ? spinner.startIdle() : spinner.stop();
  }

  /// Route this conversation onto ([active] is true) or off the screen.
  ///
  /// **Primary**: on activation, hand its region to the screen and bind its
  /// spinner to the status row; erase the stale pixels and (re)attach only if
  /// the region was actually hidden (detached) — otherwise it's already
  /// visible (focus returning to a side-panel-shared screen) and an
  /// erase+redraw would just flicker. On deactivation, detach and unbind —
  /// *unless* [stayAttachedWhenInactive] is set, in which case the region
  /// stays visible (focus has moved to a side panel).
  ///
  /// **Secondary**: the region is always attached in its column slot, so this
  /// only flips the [_active] flag (input/permission routing). Rendering is
  /// continuous and owned by the [panel].
  @override
  void setActive(bool active) {
    _active = active;
    if (!primary) return; // secondary: render-neutral
    if (active) {
      screen.setActiveChat(chat);
      // The erase+attach recovers the chat pixels when this region was hidden
      // (detached) while another conversation or modal was active. Once a side
      // panel shares the screen, stayAttachedWhenInactive keeps this region
      // attached and continuously visible — so on a focus return its pixels are
      // already correct, and an erase+redraw only buys a blank-frame flicker.
      // Skip it. (Same guard ConversationPanel.setOuter uses at attach time.)
      if (chat.isDetached) {
        screen.eraseChatArea();
        chat.attach();
      }
      spinner.attachRegion(screen.status);
    } else if (!stayAttachedWhenInactive) {
      chat.detach();
      spinner.attachRegion(null);
    }
  }

  @override
  void handleResize() => chat.handleResize();

  @override
  Future<void> dispose() async {
    await _logSub?.cancel();
    _bus.dispose();
    spinner.dispose();
    chat.detach();
  }
}
