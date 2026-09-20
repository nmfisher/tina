import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:logging/logging.dart';

import 'package:tina_engine/tina_engine.dart';

import '../chat/chat_agent_sink.dart';
import '../chat/chat_transcript.dart';

final _log = Logger('tina.agent.bus');

/// The chip an approval prompt carries when this host cannot confine bash, or
/// null when it can. Extracted so the wording is testable on any host — the
/// host's own answer comes from [TuiConversationHost.sandboxOffReason].
String? sandboxOffChip(String? reason) => reason == null
    ? null
    : '[sandbox: off] bash is running unsandboxed ($reason)';

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
class TuiConversationHost with HostLifecycleAdapter implements HostInterface {
  TuiConversationHost({
    required this.conversationId,
    required this.chat,
    required this.screen,
    required this.spinner,
    this.editor,
    bool active = false,
    this.primary = true,
    this.panel,
    this.roleLabel = 'main',

    /// Why bash on this host runs unsandboxed, when it does — shown as a chip
    /// on every approval prompt. Null when the sandbox is on. Defaults to the
    /// host capability probe (missing bwrap, disabled user namespaces);
    /// callers pass the config's sandbox-off reason so `--no-sandbox` and
    /// `--yolo` get named, not just "off".
    String? sandboxOffReason,
  })  : sandboxOffReason = sandboxOffReason ?? sandboxPassThroughReason,
        _active = active {
    _logSub = _bus.events.listen(_onBusEvent);
  }

  final String conversationId;

  /// The role this conversation runs as — the same string the panel title is
  /// built from — so the transcript's gutter and the border name the agent
  /// identically.
  final String roleLabel;

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

  /// The conversation's policy, attached by the coordinator after
  /// construction ([SessionManager] builds the policy AFTER the host, and
  /// spawned/branch conversations build their policies outside the factory).
  /// Null when nobody attached one. Read at ask time so `/permissions` /
  /// Shift+Tab mode changes show up on the next ask's header chip (#51b);
  /// [setPermissionMode] already flips this same object per conversation.
  PermissionPolicy? policy;

  /// Why bash on this host runs unsandboxed, when it does — rendered as a chip
  /// on every approval prompt ([sandboxOffChip]). Null when the sandbox is on.
  /// Set at construction from the config (`--no-sandbox` / `--yolo` reasons)
  /// or the host capability probe.
  final String? sandboxOffReason;

  /// The current (or, between turns, most recent) assistant turn's raw
  /// markdown, byte-for-byte as the model sent it — the raw view behind the
  /// Ctrl+R viewer. Updated from the sink's [ChatAgentSink.onRawText]; reset
  /// when the user's next message opens a turn.
  String lastRawMarkdown = '';

  /// This conversation's transcript — the blocks behind what the chat shows.
  /// Read-only in intent: the coordinator folds through [ChatAgentSink]'s own
  /// methods rather than editing blocks.
  ChatAgentSink get transcript => _chatSink;

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

  /// The [ChatAgentSink] that renders this host's agent output. Held directly
  /// (besides the bus-composing [_sink]) for the turn-boundary hook.
  late final ChatAgentSink _chatSink = ChatAgentSink(
    chat,
    spinner,
    onRawText: (text) {
      lastRawMarkdown = text;
    },
    onStrip: (text, {required bool error}) =>
        screen.setErrorStrip(text, error: error),
    speaker: ChatSpeaker(id: conversationId, label: roleLabel),
  );

  /// Forwards [AgentSink] calls to the chat region (via [ChatAgentSink]) and,
  /// for the calls that carry an [AgentEvent], mirrors them on [eventBus] (via
  /// [BusSink]). Composing the two means this host renders identically to the
  /// old `ChatAgentSink` while also feeding the bus — no rendering logic
  /// duplicated here.
  late final AgentSink _sink = BusSink(_chatSink, _bus);

  @override
  AgentEventBus get eventBus => _bus;

  void _onBusEvent(AgentEvent agentEvent) {
    switch (agentEvent) {
      case ToolAgentEvent(:final event):
        switch (event) {
          case ToolStartEvent():
            _log.fine('[$conversationId] tool start: ${event.toolName}');
          case ToolCompleteEvent():
            _log.fine(
              '[$conversationId] tool complete: ${event.toolName} '
              '(error=${event.isError})',
            );
          case ToolOutputEvent():
            break; // every output chunk — too chatty to log
        }
      case NoticeAgentEvent(:final message, :final kind):
        _log.info('[$conversationId] notice [$kind]: $message');
      case TextAgentEvent():
        break; // streamed prose — too chatty
      case ReasoningAgentEvent():
        break; // streamed reasoning — too chatty
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
  void reasoning(String text, {bool startsBlock = false}) =>
      _sink.reasoning(text, startsBlock: startsBlock);

  @override
  void reasoningEnd({required bool complete}) =>
      _sink.reasoningEnd(complete: complete);

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
      // The refusal is nobody's decision — it is this conversation being in the
      // background — so the audit line says that rather than blaming the user.
      // The denial note must start its own row: streamed agent prose ends
      // mid-row (no trailing newline), and a plain write would glue this
      // onto it (#30).
      chat.ensureNewline();
      chat.dim('  ${p.toolName} denied — conversation in background\n');
      return const PermissionResponse(
        PermissionDecision.deny,
        decidedBy: 'background',
        note:
            'Non-interactive run: permission asks are auto-refused — '
            'rephrasing will not change this. Proceed without this tool or '
            'answer from what you have.',
      );
    }
    chat.ensureNewline();
    chat.yellow('  ${p.toolName}: ${p.key}\n');
    // The mode chip rides under the header (#51b) — the TUI has no
    // persistent footer, so each ask is the one place the active mode is
    // visible while its keys are being read.
    final policy = this.policy;
    if (policy != null) {
      chat.dim('  ${permissionModeChip(policy.mode)}\n');
    }
    // The mode chip says how calls are gated; this says whether they are
    // confined at all. Without it, a user on a host where bash cannot be
    // sandboxed answers every prompt believing the sandbox is there.
    final sandboxChip = sandboxOffChip(sandboxOffReason);
    if (sandboxChip != null) {
      chat.yellow('  $sandboxChip\n');
    }
    if (p.execution != null) {
      chat.dim(p.execution!.approvalDescription);
    }
    if (p.sandboxAccess != null || p.outsideSandbox) {
      chat.yellow(p.accessDescription);
    } else {
      // The ordinary prompt used to say only "always allow", which reads as
      // permanent and global. Say what a/d actually covers.
      chat.dim(p.alwaysScopeNote);
    }
    final preview = await previewToolCall(p.toolName, p.input, preparedEdit: p.preparedEdit);
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
    // The approval row is always the last thing shown, immediately above the
    // input field. It stays open across the readKey so the answer character
    // lands on the same line. The row is marked with an ownership token so a
    // background writer (e.g. the environment ceremony) streaming while the
    // approval pends starts its own row instead of merging its text onto the
    // prompt (tin-6a2f).
    final rowToken = Object();
    // The answers this prompt offers, from the engine: the row below, the keys
    // accepted, and the scope a remembered answer is filed under all read the
    // same list, so a key can no longer be advertised and then do nothing.
    final choices = p.choices;
    var selectedIndex = 0;
    // Written once and reused by the arrow redraw, so the two cannot diverge.
    void writeRow() => chat.write('  approve? ${p.approvalOptionsText} ‹ ',
        rowOwner: rowToken);
    writeRow();
    // If the user is mid-prompt (a readLine in flight WITH unsent content),
    // the approval must not steal their typing — the prompt's Enter would
    // answer this readKey as a deny (it is not y/a/d) and the prompt would
    // never be submitted. Wait for the readLine to submit before arming;
    // the approval's own row stays visible meanwhile. An EMPTY pending
    // readLine (the input loop always sits in one) must not wait — that
    // deadlocks the approval behind the user's next prompt (tin-8n7c).
    final pending = editor!.pendingLine;
    if (pending != null && editor!.editState.buffer.isNotEmpty) {
      if (p.cancelSignal == null) {
        await pending.catchError((_) => '');
      } else {
        final stopped = await Future.any([
          pending.then((_) => false, onError: (_) => false),
          p.cancelSignal!.then((_) => true),
        ]);
        if (stopped) return PermissionResponse.denyOnce;
      }
    }
    // globalKeys: panel-cycling shortcuts (Ctrl+G/Ctrl+W) and the ring's
    // other navigation keys must cycle panels here, not answer the prompt
    // (tin-c5nw — Ctrl+G used to land in this readKey as a deny).
    //
    // Approval is a selectable list: up/down arrows to choose, Enter to confirm.
    // Old y/n/a/d keys still work as shortcuts. Esc still denies — the
    // "get me out" key keeps its meaning.
    //
    // #51c: exactly ONE dimmed ack per ask — the first non-answer key proves
    // the prompt is alive (its keys are being swallowed); later ones stay
    // silent so a wheel spam can't flood the transcript. Keys the focus ring
    // consumes (panel cycling) never surface here and get no ack.
    var ackedIgnoredKey = false;
    while (true) {
      final event = await editor!.readKey(globalKeys: true, cancelSignal: p.cancelSignal);
      if (event is CharInput) {
        final choice = p.choiceForKey(event.text);
        if (choice != null) {
          // Echo the key the row advertises, then answer with the choice's
          // meaning — including the scope it lasts for.
          chat.write('${choice.key}\n', rowOwner: rowToken);
          return choice.response;
        }
      } else if (event is ArrowKey) {
        // Up/down arrows cycle through the approval options.
        if (event.direction == ArrowDirection.up) {
          if (selectedIndex > 0) selectedIndex--;
        } else if (event.direction == ArrowDirection.down) {
          if (selectedIndex < choices.length - 1) selectedIndex++;
        }
        // Redraw the approval row with updated selection.
        chat.write('\x1b[1A\x1b[2K', rowOwner: rowToken); // move up and clear
        writeRow();
      } else if (event is EscapeKey) {
        chat.write('esc\n', rowOwner: rowToken);
        return PermissionResponse.denyOnce;
      } else if (event is ControlKey && event.code == ControlCode.ctrlC) {
        chat.write('cancelled\n', rowOwner: rowToken);
        return PermissionResponse.denyOnce;
      } else if (event is ControlKey && event.code == ControlCode.enter) {
        // Enter confirms the highlighted choice, whatever it is: label, then the
        // newline that closes the row.
        final selected = choices[selectedIndex];
        chat.write('${selected.label}\n', rowOwner: rowToken);
        return selected.response;
      } else if (event is ControlKey && event.code == ControlCode.backtab) {
        // Cycle the permission mode while the approval pends — the strip's
        // mode label updates live; the answer keys are unaffected.
        editor!.onBackTab?.call();
      }
      // Not an answer key: ignored, keep listening. The FIRST one echoes a
      // one-shot dim ack on the same row (#51c); the rest stay silent.
      if (!ackedIgnoredKey) {
        ackedIgnoredKey = true;
        chat.write(ignoredKeyAck, rowOwner: rowToken);
      }
    }
  }

  @override
  void showPreview(List<PreviewEntry> preview) {
    // The TUI renders the preview inline as part of [askPermission]; this is a
    // hook for hosts that separate preview presentation from the prompt.
  }

  @override
  void showMessage(
    String message, {
    HostMessageStyle style = HostMessageStyle.normal,
  }) {
    final theme = screen.theme.hostMessage;
    switch (style) {
      case HostMessageStyle.normal:
        chat.write(message);
      case HostMessageStyle.user:
        // A new user message opens a new assistant turn: drop the previous
        // turn's raw markdown so the raw viewer tracks the live turn (and so
        // replayed history doesn't stack every past turn into one buffer).
        // Both halves: the sink's accumulator, and the already-published
        // [lastRawMarkdown].
        _chatSink.beginAssistantTurn();
        lastRawMarkdown = '';
        // The user has moved on: the error strip beneath the input had its
        // chance. A new notice re-renders it.
        screen.clearErrorStrip();
        // Its own transcript block, under the `you` speaker; the sink owns the
        // rendering (and keeps the legacy bullet line on a passthrough screen).
        _chatSink.userMessage(message);
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
      _chatSink.clearTranscript();
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
    _chatSink.clearTranscript();
    panel?.render();
  }

  @override
  void setActivity(bool active) {
    // Every conversation's busy cue is its frame's comet (primary and spawned
    // alike). Inverted from a typed panel back-reference into [onBusyChanged]
    // so the host never reaches into a [PanelFrame]. Falls back to the panel
    // back-reference while the coordinator hasn't bound a frame yet.
    //
    // The signal tracks this conversation's activity, not focus — see the
    // activity-state mapping on [HostInterface.setActivity] (tin-y4qn). A
    // host with neither callback nor panel (a background conversation with no
    // frame) no-ops; its work still progresses.
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
    if (active && hasActiveRuns) {
      setActivity(true);
      return;
    }
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
  void handleResize() {
    chat.handleResize();
    // The region re-flows its own rows at the new width, which breaks the
    // gutter alignment the transcript laid out for the old one. The transcript
    // is the source of truth, so repaint it.
    _chatSink.rerender();
  }

  @override
  Future<void> dispose() async {
    await _logSub?.cancel();
    _bus.dispose();
    spinner.dispose();
    chat.detach();
  }
}
