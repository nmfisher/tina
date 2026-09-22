import 'dart:async';
import 'dart:io';

import 'backend/ansi_input_backend.dart';
import 'backend/input_backend.dart';
import 'package:fuzzy_ranker/fuzzy_ranker.dart';
import 'completion_picker.dart';
import 'confirm_dialog.dart';
import 'focus_manager.dart';
import 'input_event.dart';
import 'input_latency.dart';
import 'input_log.dart';
import 'paste_audit.dart';
import 'text_line_input.dart';
import 'menu_bar.dart';
import 'modal_surface.dart';
import 'panel_input.dart';
import 'rect.dart';
import 'screen.dart';

/// Async raw-mode line editor. Renders into [Screen.input] (an
/// [InputRegion]); overlays for the picker and Ctrl-C dialog are owned by
/// helper objects, each backed by its own [OverlayRegion]. The editor
/// itself never emits ANSI directly — every change goes through the
/// screen's clipping primitives.
class LineEditor {
  final Screen screen;

  /// When true, log parsed events to stderr for debugging input issues
  /// (e.g. Alt/Option key handling). Enable with `COCOON_DEBUG_KEYS=1`.
  final bool debugKeys;

  final InputBackend _input;

  /// True when the input backend was constructed by this editor and must be
  /// disposed by [close]. An externally-provided backend (e.g. the notcurses
  /// backend supplied by the coordinator) is owned by its creator, which
  /// disposes it explicitly via [disposeInput] during teardown.
  final bool _ownsInput;

  // Mutable slot holding the current immutable [TextLineInput] value; each
  // edit reassigns it (the model itself is never mutated in place).
  TextLineInput _edit = TextLineInput();
  late final ConfirmDialog _dialog;
  late final CompletionPicker _picker;
  // A second picker for `/`-command completion (opens only at the start of an
  // empty line; accepts the command plus a trailing space). At most one of
  // [_picker] and [_commandPicker] is active at a time.
  late final CompletionPicker _commandPicker;

  StreamSubscription<InputEvent>? _sub;
  String _prompt = '';

  /// How many key events have reached the editor. A rising count with no new
  /// presentation is what the stuck check looks for.
  int _keyCount = 0;

  /// Extra state the app wants recorded beside the editor's own — session id,
  /// whether the agent is busy, queued messages, whether a permission question
  /// is waiting. Set once by whoever wires the editor; null in tests and
  /// headless runs, where the editor-only fields still get logged.
  Map<String, Object?> Function()? describeState;

  /// Key events seen so far. Read by the stuck check.
  int get keyCount => _keyCount;

  Completer<String?>? _completer;
  Completer<InputEvent>? _keyCompleter;
  // Whether the armed [_keyCompleter] yields to the focus ring's global keys
  // (see [readKey]). Cleared with the completer it belongs to.
  bool _keyCompleterGlobal = false;
  bool _keyPanelNavigation = true;
  void Function()? _restoreKeyMonitor;
  // Turn token serializing concurrent [readKey] callers. readKey overwrites
  // [_keyCompleter] with no save/restore, so without serialization a second
  // caller would orphan the first (it would never complete). Non-null while a
  // readKey call owns the input; later callers await it.
  Completer<void>? _readKeyTurn;
  void Function()? _cancelHandler;

  // Queue-mode state (active during cancel monitoring when queue params set).
  String _qBuf = '';
  ({String buffer, int cursor})? _capturedDraft;
  int _qCursor = 0;
  void Function(String)? _onQueueSubmit;
  int _qCount = 0;
  bool _queueModeActive = false;

  /// Optional menu bar that intercepts Alt+letter and F10 keys.
  MenuBar? _menuBar;
  set menuBar(MenuBar? bar) {
    _menuBar = bar;
    // Activating the menu via F10/Alt also makes it the focused panel.
    if (bar != null) {
      bar.onRequestFocus = () {
        final fm = _focusManager;
        if (fm != null) fm.focusPanel(bar);
      };
    }
  }

  /// Optional focus manager. Ctrl+G enters panel cycling; prompts and modal
  /// overlays take priority over panel input. An exclusive [PanelInputTarget]
  /// receives other keys before app shortcuts or shared editing.
  FocusManager? _focusManager;
  set focusManager(FocusManager? fm) => _focusManager = fm;
  FocusManager? get focusManager => _focusManager;

  /// Modal overlays registered for first-claim input dispatch. While a
  /// surface's [ModalSurface.isActive] is `true`, it sees every event before
  /// the focus ring, menu bar, focused panel, or the editor — letting an open
  /// overlay capture keys (arrows, Esc) those layers would otherwise consume.
  /// First active surface to return `true` wins; later surfaces are skipped.
  /// See [registerModal].
  final List<ModalSurface> _modals = [];

  /// Register [surface] to receive first-claim input dispatch while it is
  /// active. Order matters: surfaces are offered events in registration order.
  void registerModal(ModalSurface surface) => _modals.add(surface);

  /// Remove [surface] from first-claim dispatch. No-op if not registered.
  void unregisterModal(ModalSurface surface) => _modals.remove(surface);

  /// Handle a single Esc that reaches the chat input.
  bool Function()? onEscape;

  /// Cancel pending work on rapid Esc-Esc, before any panel or prompt can
  /// consume it. The editor also releases pending key reads, dismisses input
  /// overlays, returns focus home, and clears the draft.
  bool Function()? onDoubleEscape;

  /// Cancel running work on Ctrl+C, including while a global approval is
  /// open. Return false when idle to keep normal input-clear/quit behavior.
  /// Local overlays retain their own Ctrl+C handling. A global readKey still
  /// receives Ctrl+C after cancellation so its prompt can settle as denied.
  @Deprecated('Ctrl+C clears input or confirms quit; this hook is never called')
  bool Function()? onInterrupt;

  /// Called for Ctrl+O — the panel-maximize toggle. Offered after the
  /// modal layer but before the focus ring (so it works both while cycling —
  /// for the *highlighted* panel — and on the focused panel). Return `true`
  /// to consume the event (a panel was maximized), `false` to let it fall
  /// through. Lets the app layer render the highlighted panel as a popup
  /// without adding app-specific keys to the editor's core dispatch.
  bool Function()? onMaximizeToggle;

  /// Called for Ctrl+R — offered at the same dispatch rank as
  /// [onMaximizeToggle] (after the modal layer, before the focus ring), so
  /// the app-level viewer it opens works from any focus. Return `true` to
  /// consume the event (the viewer opened), `false` to let it fall through.
  bool Function()? onRawView;

  /// The Ctrl+B app hook (tina: the transcript block cursor). Same dispatch
  /// rank as the raw-view hook: it must work from any focus, including while an
  /// approval prompt has an armed readKey, so the cursor cannot be swallowed by
  /// whatever happens to own the keyboard. True when the hook consumed the key.
  bool Function()? onBlockCursor;

  /// Called for an Alt+key event the editor doesn't bind internally (anything
  /// other than Alt+b/d/f word editing). Return `true` to consume the event,
  /// `false` to let it fall through and be ignored. Lets the app layer bind
  /// Alt+number / Alt+letter shortcuts (e.g. session switching) without adding
  /// app-specific keys to the editor's core dispatch.
  bool Function(AltKey key)? onAltKey;

  /// Called for Shift+Tab (backtab). Offered at the same dispatch rank as
  /// [onMaximizeToggle] — after the modal layer, before the focus ring — and
  /// in queue mode alongside it, so the app-level binding works from any
  /// focus and while a turn is running. Return `true` to consume the event,
  /// `false` to let it fall through (the editor binds nothing for backtab, so
  /// a declining hook means the key is dropped, never typed).
  bool Function()? onBackTab;

  /// Timestamp of the last standalone ESC at the prompt, for double-Esc
  /// detection. Null after a double completes or the window elapses.
  DateTime? _lastEsc;
  DateTime? _lastGlobalEsc;
  Completer<void> _cancelKeyReads = Completer<void>();

  /// [debugDoubleEscWindow] overrides it in tests: a fresh kernel compile
  /// reshuffles async timing enough to overflow a fixed window
  /// nondeterministically (the coordinator's double-Esc test flips per
  /// compile without this seam).
  static const Duration _doubleEscWindow = Duration(milliseconds: 450);
  static Duration? debugDoubleEscWindow;
  static Duration get _activeDoubleEscWindow =>
      debugDoubleEscWindow ?? _doubleEscWindow;

  /// Called when a non-fatal error is caught (e.g. a [CompletionProvider]
  /// that throws).
  final void Function(Object error, StackTrace stack)? onError;

  /// Source of `@` completion suggestions. Delegates to the [CompletionPicker].
  CompletionProvider? get completionProvider => _picker.provider;
  set completionProvider(CompletionProvider? p) => _picker.provider = p;

  /// Source of `/` command suggestions for the command palette. Null (the
  /// default) leaves the `/` picker inert — set by the host (e.g. the TUI
  /// coordinator) to enable slash autocompletion.
  CompletionProvider? get commandProvider => _commandPicker.provider;
  set commandProvider(CompletionProvider? p) => _commandPicker.provider = p;

  /// When true, macOS Option+letter characters are mapped to [AltKey] events
  /// so menus work without "Use Option as Meta" enabled in the terminal.
  final bool macosOptionAsMeta;

  LineEditor({
    required this.screen,
    InputBackend? input,
    this.onError,
    this.macosOptionAsMeta = false,
    this.debugKeys = false,
    Duration escapeTimeout = const Duration(milliseconds: 150),
  })  : _input = input ??
            AnsiInputBackend(
              io: screen.io,
              macosOptionAsMeta: macosOptionAsMeta,
              escapeTimeout: escapeTimeout,
            ),
        _ownsInput = input == null {
    _picker = CompletionPicker(screen, onError: onError);
    _commandPicker = CompletionPicker.commandPicker(screen, onError: onError);
    _dialog = ConfirmDialog(screen);
  }

  /// The input backend this editor reads from. Exposed so the host (e.g.
  /// `bin/tina.dart`) can pass it to other components that synthesize key
  /// events.
  InputBackend get input => _input;

  // -- Public API ---------------------------------------------------------

  Future<String?> readLine(String prompt) async {
    await _input.ready;
    _prompt = prompt;
    _edit = _edit.clear().resetNavigation();
    final draft = _capturedDraft;
    _capturedDraft = null;
    if (draft != null) _edit = _edit.loadState(draft.buffer, draft.cursor);
    _dialog.reset();
    _picker.reset();
    _commandPicker.reset();
    _completer = Completer<String?>();
    _redraw();
    _ensureListening();
    return _completer!.future;
  }

  /// Snapshot of the next emergency cancellation. Capture once for an entire
  /// interaction, so nested dialogs cannot reopen after double-Esc.
  Future<void> get inputCancelled => _cancelKeyReads.future;

  Future<InputEvent> Function() captureKeyReader({bool globalKeys = false}) {
    final cancel = inputCancelled;
    return () => readKey(globalKeys: globalKeys, cancelSignal: cancel);
  }

  /// Wait for the next input event. Suspends any active cancel-monitor for
  /// the duration so a Y/N prompt can read its keystroke without ESC
  /// triggering a cancellation in the parent agent loop.
  ///
  /// Serialized: if another [readKey] is already in flight, this call waits
  /// for it to finish before claiming the key stream. Without serialization a
  /// second caller would overwrite [_keyCompleter] and orphan the first (it
  /// would never complete) — which matters because a background sub-agent
  /// spend-trip can fire the pause dialog's readKey while askPermission or
  /// /settings already holds one.
  ///
  /// With [globalKeys], the focus ring's navigation keys (Ctrl+G/Ctrl+W panel
  /// cycling, Esc return-home, and every key while cycling is engaged) are
  /// handled by the editor instead of being delivered here — a global
  /// shortcut must never become prompt input (tin-c5nw: Ctrl+G at an open
  /// approval used to answer it as a deny). Approval and gate prompts pass
  /// `true`; overlays that own the whole screen keep the default.
  /// Set [panelNavigation] to false when arrows select an answer even while
  /// another panel is focused.
  /// [cancelSignal] releases this read as Ctrl+C, including while queued behind
  /// another reader. A late signal never cancels a subsequent reader.
  Future<InputEvent> readKey({bool globalKeys = false, bool panelNavigation = true, Future<void>? cancelSignal}) async {
    var cancelled = false;
    final cancellation = _cancelKeyReads;
    final stop = Future.any([
      cancellation.future,
      if (cancelSignal != null) cancelSignal,
    ]).then((_) { cancelled = true; });
    // Overflow chars from a paste are drained to the next readKey ONLY while
    // the burst window is still open (the paste is still arriving). Once the
    // window has expired the queued chars are stale — they must never answer
    // a later readKey such as an approval prompt, or the approval consumes a
    // leftover paste char (not y/a/d) as a deny. Drop them instead.
    final burstOpen = _burstTimer != null;
    _burstTimer?.cancel();
    _burstTimer = null;
    if (burstOpen && _pending.isNotEmpty) {
      if (PasteAudit.enabled) {
        PasteAudit.log(
          'readKey: burst window open, handing off first of '
          '${_pending.length} pending overflow events',
        );
      }
      return _pending.removeAt(0);
    }
    if (PasteAudit.enabled && _pending.isNotEmpty) {
      PasteAudit.log(
        'readKey: burst window EXPIRED, DROPPING ${_pending.length} '
        'pending overflow events '
        '(${_pendingChars()} chars)',
      );
    }
    _pending.clear();

    while (_readKeyTurn != null) {
      await Future.any([_readKeyTurn!.future, stop]);
      if (cancelled) return ControlKey(ControlCode.ctrlC);
    }
    if (cancelled || !identical(cancellation, _cancelKeyReads)) {
      return ControlKey(ControlCode.ctrlC);
    }
    final turn = Completer<void>();
    _readKeyTurn = turn;
    try {
      return await _readKeyOnce(globalKeys, panelNavigation, stop);
    } finally {
      _readKeyTurn = null;
      turn.complete();
    }
  }

  /// True while a [readKey] is awaiting a keystroke.
  bool get isReadingKey => _keyCompleter != null;

  Future<InputEvent> _readKeyOnce(bool globalKeys, bool panelNavigation, Future<void>? stop) {
    final c = Completer<InputEvent>();
    final savedCancel = _cancelHandler;
    final savedQueueSubmit = _onQueueSubmit;
    _cancelHandler = null;
    _onQueueSubmit = null;
    _keyCompleter = c;
    _keyCompleterGlobal = globalKeys;
    _keyPanelNavigation = panelNavigation;
    var restored = false;
    void restoreMonitor() {
      if (restored) return;
      restored = true;
      _cancelHandler = savedCancel;
      _onQueueSubmit = savedQueueSubmit;
      _restoreKeyMonitor = null;
    }
    _restoreKeyMonitor = restoreMonitor;
    stop?.then((_) {
      // A late cancellation must not settle a newer modal's read.
      if (identical(_keyCompleter, c)) {
        _keyCompleter = null;
        c.complete(ControlKey(ControlCode.ctrlC));
        _scheduleHeldPasteDelivery();
      }
    });
    _ensureListening();
    if (debugKeys) {
      stderr.writeln('[readkey] armed');
    }
    return c.future.whenComplete(() {
      restoreMonitor();
      _keyCompleterGlobal = false;
      if (debugKeys) {
        stderr.writeln('[readkey] completed');
      }
    });
  }

  /// Keep the stdin subscription active while the agent is running so that a
  /// single-byte ESC press (not the prefix of an escape sequence) fires
  /// [onCancel]. When [onQueueSubmit] is provided, keystrokes during agent
  /// processing are echoed in the input region and submitted on Enter.
  void beginCancelMonitor(
    void Function() onCancel, {
    void Function(String)? onQueueSubmit,
    int queueCount = 0,
  }) {
    _cancelHandler = onCancel;
    _onQueueSubmit = onQueueSubmit;
    _qBuf = '';
    _qCursor = 0;
    _qCount = queueCount;
    _queueModeActive = onQueueSubmit != null;
    if (_queueModeActive) _renderQueueDisplay();
    _ensureListening();
  }

  void endCancelMonitor() {
    _cancelHandler = null;
    if (_queueModeActive) screen.input.clear();
    _queueModeActive = false;
    _onQueueSubmit = null;
    _qBuf = '';
    _qCursor = 0;
    _qCount = 0;
  }

  /// While a slow command dispatch runs (e.g. `/compact` summarizing through
  /// an LLM call), no [readLine] is armed — pre-tin-y8kh, keystrokes in that
  /// window were dropped on the floor and the user had to retype. This arms
  /// the same queue-mode capture used mid-turn: keystrokes are echoed in the
  /// input region and handed to [onSubmit] on Enter (multi-entry works —
  /// Enter does not end the capture). Cancel stays inert; Ctrl+C clears the
  /// draft or confirms quit, as in queue mode. Pairs with
  /// [endInputCaptureWindow]; [readKey] save/restores the monitor around an
  /// approval prompt, so a nested prompt during the window is safe. No-op to
  /// end when nothing is armed (the window never spans a [readLine], so the
  /// monitor cannot be someone else's).
  void beginInputCaptureWindow(void Function(String) onSubmit,
      {int queueCount = 0}) {
    beginCancelMonitor(() {}, onQueueSubmit: onSubmit, queueCount: queueCount);
  }

  void endInputCaptureWindow() {
    if (!_queueModeActive) return;
    // A replacement instruction may already be partly typed while a cancelled
    // command unwinds. Hand that draft to readLine instead of erasing it.
    if (_qBuf.isNotEmpty) _capturedDraft = (buffer: _qBuf, cursor: _qCursor);
    endCancelMonitor();
  }

  void pause() => _sub?.pause();
  void resume() => _sub?.resume();

  /// Re-render the current input line. Use after the screen was repainted
  /// underneath an active [readLine] (e.g. a session switch erased and
  /// redrew the chat area).
  void refresh() {
    if (_completer == null && !_queueModeActive) return;
    if (_queueModeActive) {
      _renderQueueDisplay();
    } else {
      _redraw();
    }
  }

  /// Snapshot the current edit state so the coordinator can save/restore
  /// per-panel input buffers.
  ({String buffer, int cursor}) get editState =>
      (buffer: _edit.buffer, cursor: _edit.cursor);

  /// Stop the input backend's event source (polling timer, stdin listener)
  /// without tearing down the rest of the editor. Used during teardown so the
  /// backend doesn't outlive the screen / notcurses context.
  void disposeInput() => _input.dispose();

  /// Whether the editor is actively accepting input (a [readLine] is in
  /// flight or queue mode is on). When false, [_edit] is either empty or
  /// stale, and the per-panel saved state is authoritative.
  bool get isEditing => _completer != null || _queueModeActive;

  /// The pending conversation input. Modal key reads preserve its draft.
  Future<String?>? get pendingLine => _completer?.future;

  /// Load edit state from a panel and render the input line, even when no
  /// [readLine] is active — unlike [refresh], this always paints.
  void loadEditState(String buffer, int cursor) {
    // Saved state carries only real text; any prior placeholder spans no
    // longer apply.
    _edit = _edit.loadState(buffer, cursor);
    screen.input.render(prompt: _prompt, buffer: buffer, cursor: cursor);
  }

  /// Seed Up/Down recall from a restored conversation's user messages.
  /// Transcript rendering is separate from the editor's command history.
  void restoreHistory(Iterable<String> lines) {
    var restored = _edit.copyWith(history: const []).resetNavigation();
    for (final line in lines) {
      restored = restored.addHistory(line);
    }
    _edit = restored;
  }

  /// Overflow CharInput events from a paste burst, queued between readKey
  /// calls so they reach the overlay instead of _dispatchEvent.
  final List<InputEvent> _pending = [];
  Timer? _burstTimer;

  /// PasteInputs held while a global readKey (approval / gate prompt) is
  /// armed — tin-w8dl. Delivered through [_onEventInner] once the prompt's
  /// readKey completes; a chained prompt re-arms first and re-holds them.
  /// Emergency cancellation and quit discard these with the pending draft.
  final List<PasteInput> _heldPastes = [];

  /// Deliver held pastes one microtask after a readKey completes — after the
  /// completer's awaiter runs, so a prompt that chains into the next readKey
  /// re-holds rather than races. Re-entry safe: empty list is a no-op.
  void _scheduleHeldPasteDelivery() {
    if (_heldPastes.isEmpty) return;
    if (PasteAudit.enabled) {
      PasteAudit.log('delivering ${_heldPastes.length} held paste(s)');
    }
    scheduleMicrotask(() {
      if (_heldPastes.isEmpty) return;
      final deliver = List<PasteInput>.of(_heldPastes);
      _heldPastes.clear();
      for (final paste in deliver) {
        _onEventInner(paste);
      }
    });
  }

  /// How long (in ms) after completing a readKey we continue to intercept
  /// CharInput events. Paste bytes arrive within microseconds; normal typing
  /// has 30+ ms between key events.
  static const _burstWindowMs = 10;

  /// Release input and UI resources while the screen is still alive. Hosts
  /// leaving an alternate screen can defer diagnostics until normal stdout
  /// is restored by passing false and then calling [reportInputLatency].
  void close({bool reportLatency = true}) {
    // tin-w8dl: pastes still held behind an open readKey must reach the
    // buffer before the input stream dies, or a shutdown mid-prompt drops
    // them. Direct dispatch — no readKey can usefully complete at close.
    if (_heldPastes.isNotEmpty) {
      final deliver = List<PasteInput>.of(_heldPastes);
      _heldPastes.clear();
      for (final paste in deliver) {
        _dispatchEvent(paste);
      }
    }
    _sub?.cancel();
    _sub = null;
    _burstTimer?.cancel();
    _burstTimer = null;
    if (_ownsInput) _input.dispose();
    _dialog.dispose();
    _picker.dispose();
    _commandPicker.dispose();
    if (reportLatency) reportInputLatency();
  }

  /// Print optional latency diagnostics after the terminal has been restored.
  void reportInputLatency() {
    if (InputLatency.enabled) {
      final s = InputLatency.snapshot();
      stderr.writeln(
        '[input-latency] count=${s.count} '
        'p50=${s.p50Millis.toStringAsFixed(3)}ms '
        'p95=${s.p95Millis.toStringAsFixed(3)}ms '
        'p99=${s.p99Millis.toStringAsFixed(3)}ms '
        'max=${s.maxMillis.toStringAsFixed(3)}ms',
      );
    }
  }

  /// What the editor is doing right now, as plain `name=value` pairs, for the
  /// input log. These are the fields that decide where a key can go and whether
  /// anything can be drawn: if the screen ever freezes again, this says whether
  /// a prompt owned the keyboard, whether the input row had any size, and which
  /// owner the app was in.
  ///
  /// Null values are omitted by [InputLog.format], so a field only appears when
  /// it is meaningful (`chat_prompt_open=true` but `queued_lines` absent).
  Map<String, Object?> currentState() {
    final focused = _focusManager?.focused;
    return {
      // The normal case: a prompt is waiting for you and typing reaches it.
      'chat_prompt_open': _completer != null,
      // A prompt is waiting for a key — a permission question, a gate, or an
      // overlay. Typing answers it and never reaches the chat input.
      'answering_prompt': _keyCompleter != null,
      'prompt_is_global': _keyCompleter != null ? _keyCompleterGlobal : null,
      // A second prompt is waiting behind the first (readKey serialization).
      'prompt_serialized': _readKeyTurn != null,
      // Typed while the agent is busy: goes to the queued-message line.
      'typing_while_busy': _queueModeActive,
      'queued_lines': _qCount > 0 ? _qCount : null,
      'held_pastes': _heldPastes.isNotEmpty ? _heldPastes.length : null,
      'paste_overflow': _pending.isNotEmpty ? _pending.length : null,
      'confirm_visible': _dialog.isVisible,
      'picker_open': _activePicker != null,
      // The other silent trap: a hidden input row paints nowhere.
      'input_row_hidden': screen.input.bounds.isEmpty,
      'focused_panel': focused == null ? 'none' : '${focused.runtimeType}',
      'input_backend': '${_input.runtimeType}',
      'frames_open': screen.openFrames,
      ...?describeState?.call(),
    };
  }

  /// Inject a synthetic input event. Used by the SIGINT handler to deliver
  /// `ControlKey(ControlCode.ctrlC)` so the editor's own logic runs.
  void inject(InputEvent event) => _input.inject(event);

  /// Called by the host's SIGWINCH handler *after* [Screen.resize] has
  /// already laid out the new dimensions. Re-renders the current state.
  void handleResize() {
    if (_completer == null && !_queueModeActive) return;
    if (_queueModeActive) {
      _renderQueueDisplay();
    } else {
      _redraw();
    }
  }

  // -- Input dispatch -----------------------------------------------------

  bool get _exclusivePanelFocused {
    final target = _focusManager?.focused;
    return target is PanelInputTarget &&
        target.inputMode == PanelInputMode.exclusive;
  }

  /// Panel-owned input bypasses chat editing, cancellation and app shortcuts.
  /// A readKey still owns the keyboard. Registered overlays sit above panels;
  /// even an unhandled modal key must not reach the background panel.
  bool _routeExclusivePanelInput(InputEvent event) {
    if (_keyCompleter != null ||
        (_burstTimer != null && event is CharInput) ||
        !_exclusivePanelFocused) return false;
    var modalActive = false;
    for (final modal in _modals) {
      if (!modal.isActive) continue;
      modalActive = true;
      if (modal.handleEvent(event)) {
        _redraw();
        return true;
      }
    }
    if (modalActive) return true;
    final fm = _focusManager!;
    _lastEsc = null;
    if (fm.isCycling ||
        (event is ControlKey && event.code == ControlCode.ctrlG)) {
      fm.handleEvent(event);
      _redraw();
    } else {
      // Ownership, rather than the handler's return value, prevents fallback.
      fm.focused!.handleEvent(event);
    }
    return true;
  }

  /// Hide editor-only overlays when a panel takes over the keyboard. Drafts
  /// and command history remain intact for the next conversation focus.
  void suspendSharedInput() {
    _activePicker?.closeState();
    _dialog.dismiss();
    _lastEsc = null;
    screen.input.setBoundsOverride(Rect.empty);
  }

  void _ensureListening() {
    _sub ??= _input.events.listen(_onEvent);
  }

  void _onEvent(InputEvent event) {
    InputLatency.handlerEntered(event);
    _keyCount++;
    KeyHandledBy who;
    try {
      who = _onEventInner(event);
    } finally {
      InputLatency.complete(event);
    }
    InputLog.key(event, who, currentState);
  }

  /// Handle [event] and report where it ended up: the chat input, a panel, a
  /// waiting prompt, or nowhere at all. That value is what [InputLog] records,
  /// so a key that does nothing visible can name who took it.
  KeyHandledBy _onEventInner(InputEvent event) {
    if (debugKeys) {
      stderr.writeln('[keys] event: $event');
    }
    if (event is EscapeKey) {
      final now = DateTime.now();
      final isDouble = _lastGlobalEsc != null &&
          now.difference(_lastGlobalEsc!) <= _activeDoubleEscWindow;
      _lastGlobalEsc = isDouble ? null : now;
      _lastEsc = isDouble ? null : now;
      if (isDouble) {
        _forceCancelInput();
        return KeyHandledBy.appShortcut;
      }
    } else {
      _lastGlobalEsc = null;
    }
    // Ctrl+C clears the shared input first. With an empty input, it arms the
    // quit confirmation; another press quits. Running work and pending
    // approvals are unaffected by clearing the draft. A quit while a readKey
    // (approval / overlay prompt) is armed completes it with ctrlC so the
    // awaiting code settles as cancelled instead of hanging.
    if (event is ControlKey && event.code == ControlCode.ctrlC) {
      final hasDraft =
          _queueModeActive ? _qBuf.isNotEmpty : _edit.buffer.isNotEmpty;
      if (!_dialog.isVisible && !_exclusivePanelFocused && hasDraft) {
        _activePicker?.closeState();
        _lastEsc = null;
        _capturedDraft = null;
        if (_queueModeActive) {
          _qBuf = '';
          _qCursor = 0;
          _renderQueueDisplay();
          return KeyHandledBy.queuedInput;
        }
        _edit = _edit.clear().resetNavigation();
        _redraw();
        return KeyHandledBy.chatBox;
      }
      final modalActive = _modals.any((m) => m.isActive);
      if (_exclusivePanelFocused &&
          !modalActive &&
          _keyCompleter == null &&
          !_dialog.isVisible) {
        // An exclusive panel owns every key, Ctrl+C included: the arming
        // press is still forwarded so the panel's key stream stays complete.
        // With a modal open the gate alone handles the press (overlays sit
        // above panels), an armed readKey means an overlay owns the screen,
        // and the confirming press (dialog already visible) belongs to the
        // gate alone everywhere.
        _routeExclusivePanelInput(event);
        if (_dialog.trigger()) _quitNow();
        return KeyHandledBy.quit;
      }
      if (_dialog.trigger()) {
        _quitNow();
      } else {
        _redraw();
      }
      return KeyHandledBy.quit;
    }
    if (_routeExclusivePanelInput(event)) return KeyHandledBy.panel;
    // An armed quit-confirm yields to the key's real owner above (exclusive
    // panels, modals). Any other key dismisses it on the way to its normal
    // handling. A standalone ESC is absorbed by the dismissal — it must not
    // answer an open prompt as a deny — but only when the chat prompt owns
    // the keyboard: with no readLine armed (an overlay/approval screen) Esc
    // keeps its prompt meaning and flows through, and with a cancel monitor
    // armed it stays the cancel gesture.
    if (_dialog.isVisible) {
      final promptOwnsEsc = _completer != null && _cancelHandler == null;
      _dialog.dismiss();
      if (event is EscapeKey && promptOwnsEsc) return KeyHandledBy.modal;
    }
    if (_keyCompleterGlobal && event is PasteInput) {
      // tin-w8dl: a paste arriving while a GLOBAL readKey (approval / gate
      // prompt) is armed must not land in the editor buffer underneath the
      // prompt — the user's next Enter then answers the prompt and the paste
      // is stranded with no Enter left to submit it. An existing draft stays in the
      // editor while the approval owns answer keys. Held, never dropped;
      // delivered through the full pipeline once the prompt resolves (a
      // chained prompt re-arms first and simply re-holds).
      //
      // Scoped to global readKeys only: a non-global readKey (an overlay
      // that owns the screen) keeps the long-pinned behavior of pasting
      // straight into the buffer (see line_editor_test's 'paste burst flush
      // never answers a readKey').
      _heldPastes.add(event);
      if (PasteAudit.enabled) {
        PasteAudit.log(
          'PasteInput HELD while global readKey armed '
          '(held=${_heldPastes.length})',
        );
      }
      return KeyHandledBy.heldPaste;
    }
    if (_keyCompleter != null &&
        (event is! PasteInput || !_keyCompleterGlobal)) {
      // A non-global readKey is an overlay that owns the screen (settings,
      // prompts, spawn, pickers) — a paste belongs to ITS focused text field,
      // not the conversation buffer hidden underneath, so it answers the
      // readKey like any typed char. Global readKeys (approval / gate
      // prompts) never see pastes: those are held above and delivered to the
      // buffer once the prompt resolves.
      // A global readKey (an approval or gate prompt) still yields to the
      // focus ring: Ctrl+G/Ctrl+W cycle panels, and while cycling the ring is
      // modal over every key. Consumed here, the key never answers the prompt
      // — pre-fix, Ctrl+G at an open approval landed in the prompt's readKey
      // and answered it as a deny (tin-c5nw).
      if (_keyCompleterGlobal && _handleFocusRingKeys(event)) {
        return KeyHandledBy.focusRing;
      }
      // The prompt owns answer keys, even on a read-only panel. Only
      // navigation is offered to the focused view while an approval is open.
      if (_keyCompleterGlobal &&
          _keyPanelNavigation &&
          !_exclusivePanelFocused &&
          (event is ArrowKey || event is ScrollEvent) &&
          (_focusManager?.focused?.handleEvent(event) ?? false)) {
        return KeyHandledBy.panel;
      }
      final c = _keyCompleter!;
      _keyCompleter = null;
      if (PasteAudit.enabled) {
        PasteAudit.log(
          'readKey ANSWERED by $event (global=$_keyCompleterGlobal)',
        );
      }
      c.complete(event);
      // After completing a readKey, open a short burst window during which
      // overflow CharInput events (from a paste) are queued rather than
      // dispatched to the editor buffer. The window is well below normal
      // typing speed (~30ms between keystrokes) so only paste bursts are
      // intercepted.
      _burstTimer?.cancel();
      _burstTimer = Timer(
          Duration(milliseconds: _burstWindowMs), () => _burstTimer = null);
      _scheduleHeldPasteDelivery();
      return KeyHandledBy.openPrompt;
    }
    // Overflow CharInput from a paste burst that arrived before readKey
    // could re-arm _keyCompleter.
    if (_burstTimer != null && event is CharInput) {
      _pending.add(event);
      if (PasteAudit.enabled && _pending.length == 1) {
        PasteAudit.log(
          'overflow CharInput queued to _pending (first; window open)',
        );
      }
      return KeyHandledBy.pasteOverflow;
    }
    if (_cancelHandler != null) {
      if (_handleFocusRingKeys(event)) return KeyHandledBy.focusRing;
      if (_focusManager?.focused?.handleEvent(event) ?? false) {
        return KeyHandledBy.panel;
      }
      // Ctrl+C never reaches here (the quit gate consumes it first); the
      // monitor is Esc-driven now — cancel is Esc's job. In queue mode the
      // ESC is the queue's first: it clears queued text, and only cancels
      // once the buffer is already empty.
      if (event is EscapeKey && _queueModeActive) {
        _handleQueueEvent(event);
      } else if (event is EscapeKey) {
        _cancelHandler!();
      } else if (_queueModeActive) {
        _handleQueueEvent(event);
      }
      return KeyHandledBy.queuedInput;
    }
    // Standalone ESC dismisses an open picker without firing escape logic.
    final openPicker = _activePicker;
    if (openPicker != null && event is EscapeKey) {
      openPicker.closeState();
      _redraw();
      return KeyHandledBy.modal;
    }

    if (PasteAudit.enabled && event is PasteInput) {
      PasteAudit.log(
        'PasteInput dispatched: chars='
        '${event.text.length} readKeyArmed=${_keyCompleter != null} '
        'queueMode=$_queueModeActive editing=${_completer != null}',
      );
    }
    return _dispatchEvent(event);
  }

  void _forceCancelInput() {
    // Release both the current prompt and readers queued behind it. A new
    // prompt belongs to a new cancellation generation.
    final reads = _cancelKeyReads;
    _cancelKeyReads = Completer<void>();
    reads.complete();
    final key = _keyCompleter;
    _keyCompleter = null;
    _keyCompleterGlobal = false;
    key?.complete(EscapeKey());
    _restoreKeyMonitor?.call();
    _burstTimer?.cancel();
    _burstTimer = null;
    _pending.clear();
    _heldPastes.clear();
    _dialog.dismiss();
    _activePicker?.closeState();
    for (final modal in _modals.toList()) {
      if (modal.isActive) modal.handleEvent(EscapeKey());
    }
    _menuBar?.deactivate();
    _focusManager?.cancel();
    _focusManager?.returnHome();
    _edit = _edit.clear().resetNavigation();
    _capturedDraft = null;
    _qBuf = '';
    _qCursor = 0;
    if (onDoubleEscape != null) {
      onDoubleEscape!();
    } else {
      _cancelHandler?.call();
    }
    _redraw();
  }

  int _pendingChars() =>
      _pending.fold(0, (n, e) => n + (e is CharInput ? e.text.length : 0));

  /// macOS Option+Arrow fallback. When ESC arrived as a standalone event and a
  /// letter follows within 150ms, treat the pair as an Alt+letter word-motion
  /// shortcut instead of literal text. Returns true when consumed.
  bool _handleEscFollowUp(InputEvent event) {
    if (_lastEsc == null) return false;
    // EscapeKey is the editor's own concern (double-Esc clear), not a macOS
    // Option+letter follow-up — defer to the EscapeKey case in _dispatchEvent.
    // Without this guard the second Esc of a double-Esc would null _lastEsc
    // here, so the 450ms window would never see a pair and the buffer wouldn't
    // clear.
    if (event is EscapeKey) return false;
    final age = DateTime.now().difference(_lastEsc!);
    if (age > const Duration(milliseconds: 150)) return false;
    // Consumed — clear the Esc timestamp so subsequent chars type normally.
    _lastEsc = null;
    switch (event) {
      case CharInput(:final text):
        final ch = text.codeUnitAt(0);
        switch (ch) {
          case 0x62: // b → word left
            _edit = _edit.moveWordLeft();
            _redraw();
            return true;
          case 0x66: // f → word right
            _edit = _edit.moveWordRight();
            _redraw();
            return true;
          case 0x64: // d → delete word forward
            _edit = _edit.killWordForward();
            _redraw();
            return true;
        }
      case ControlKey(:final code) when code == ControlCode.backspace:
        // ESC then backspace → delete word backward.
        _edit = _edit.killWordBackward();
        _redraw();
        return true;
      default:
        break;
    }
    return false;
  }

  /// Offer [event] to the focus ring — steps 2 and 3 of [_dispatchEvent], the
  /// global navigation layer. True when the ring consumed it (engaged or moved
  /// cycling, or Esc returned focus home), meaning no other surface — a
  /// focused panel, the editor, or an armed global [readKey] — should see it.
  bool _handleFocusRingKeys(InputEvent event) {
    // The maximize toggle outranks the ring here too: an armed global readKey
    // (an approval prompt) yields focus-layer keys to this seam, so Ctrl+O
    // must work there — otherwise it would answer the prompt instead.
    if (_handleMaximizeToggle(event)) return true;
    if (_handleRawView(event)) return true;
    if (_handleBlockCursor(event)) return true;
    final fm = _focusManager;
    if (fm == null) return false;
    // Not cycling, the ring only claims its entry keys (Ctrl+G/Ctrl+W) and
    // Esc-return-home; everything else falls through (returns false).
    if (fm.handleEvent(event)) {
      _redraw();
      return true;
    }
    return false;
  }

  /// The Ctrl+O maximize toggle, shared by every input path: normal dispatch,
  /// the armed-global-readKey seam, and queue mode. True when the hook
  /// consumed the key (a panel was maximized).
  bool _handleMaximizeToggle(InputEvent event) {
    final maximize = onMaximizeToggle;
    if (maximize == null) return false;
    if (event is! ControlKey || event.code != ControlCode.ctrlO) return false;
    if (!maximize()) return false;
    _redraw();
    return true;
  }

  /// The Ctrl+R app hook (tina: raw-markdown viewer), at the same dispatch
  /// rank as the maximize toggle. True when the hook consumed the key.
  bool _handleRawView(InputEvent event) {
    final rawView = onRawView;
    if (rawView == null) return false;
    if (event is! ControlKey || event.code != ControlCode.ctrlR) return false;
    if (!rawView()) return false;
    _redraw();
    return true;
  }

  /// The Ctrl+B app hook, at the same dispatch rank as the raw-view hook.
  bool _handleBlockCursor(InputEvent event) {
    final cursor = onBlockCursor;
    if (cursor == null) return false;
    if (event is! ControlKey || event.code != ControlCode.ctrlB) return false;
    if (!cursor()) return false;
    _redraw();
    return true;
  }

  /// The Shift+Tab app hook (tina: permission-mode cycling), at the same
  /// dispatch rank as the maximize toggle. True when the hook consumed the
  /// key.
  bool _handleBackTab(InputEvent event) {
    final backTab = onBackTab;
    if (backTab == null) return false;
    if (event is! ControlKey || event.code != ControlCode.backtab) return false;
    if (!backTab()) return false;
    _redraw();
    return true;
  }

  KeyHandledBy _dispatchEvent(InputEvent event) {
    // Held pastes also enter here after a prompt releases input ownership.
    if (_routeExclusivePanelInput(event)) return KeyHandledBy.panel;
    if (debugKeys) {
      stderr.writeln('[keys] event: $event');
    }
    // 1. Registered modal overlays get first dibs while active — ahead of the
    //    focus ring, menu, focused panel, and the editor. An open overlay must
    //    intercept its own keys (e.g. arrows to scroll, Esc to close) even when
    //    the strip or menu is focused, so it preempts them all. First active
    //    surface to consume the event wins.
    for (final modal in _modals) {
      if (modal.isActive && modal.handleEvent(event)) {
        _redraw();
        return KeyHandledBy.modal;
      }
    }
    // 2. Ctrl+O: the app's panel-maximize toggle. Ahead of the focus
    //    ring so it fires both while cycling (the highlighted panel) and on
    //    the focused panel. The hook decides whether a panel qualifies.
    if (_handleMaximizeToggle(event)) {
      return KeyHandledBy.appShortcut;
    }
    // Ctrl+R rides at the same rank (the app's raw-view overlay opens from
    // any focus), and Ctrl+B with it (the block cursor).
    if (_handleRawView(event)) {
      return KeyHandledBy.appShortcut;
    }
    if (_handleBlockCursor(event)) {
      return KeyHandledBy.appShortcut;
    }
    // Shift+Tab rides at the same rank (the app cycles permission modes from
    // any focus).
    if (_handleBackTab(event)) {
      return KeyHandledBy.appShortcut;
    }
    // 3. Modal cycling: the focus manager owns all keys (arrows/Tab move the
    //    highlight, Enter commits, Esc cancels). Nothing reaches a panel.
    if (_focusManager != null && _focusManager!.isCycling) {
      _focusManager!.handleEvent(event);
      _redraw();
      return KeyHandledBy.focusRing;
    }
    // 4. Esc / entry keys: engage cycling or return home. Returns false when
    //    already home, so the editor's double-Esc clear runs in the switch.
    if (_focusManager != null && _focusManager!.handleEvent(event)) {
      _redraw();
      return KeyHandledBy.focusRing;
    }
    // 5. Menu bar — F10/Alt activation (from any focus) and arrow navigation
    //    when the menu is the focused panel.
    if (_menuBar != null && _menuBar!.handleEvent(event)) {
      _redraw();
      return KeyHandledBy.menu;
    }
    // 6. The focused panel handles the event (chat declines → editor; info
    //    swallows). The menu is handled in step 4.
    final focused = _focusManager?.focused;
    if (focused != null && focused.handleEvent(event)) {
      return KeyHandledBy.panel;
    }
    // macOS Option+Arrow fallback: ESC and the letter arrive in separate
    // stdin chunks. When EscapeKey was just received, intercept b/f/d as
    // word-motion and backspace as delete-word-backward.
    if (_handleEscFollowUp(event)) return KeyHandledBy.chatBox;

    // Ownerless keyboard: no [readLine] is armed (the caller is mid-dispatch
    // — e.g. /compact awaiting its LLM summarization), no [readKey] holds the
    // stream, and queue mode is off. The steps above stay live so modals,
    // panel cycling and menu keys keep working, but chat editing must not
    // run: its mutations would land in _edit and be painted, while [isEditing]
    // is false and the next [readLine] clears the buffer (see its doc) —
    // silently wiping text the user just watched themselves type (tin-y27w).
    // Escape is deliberately left through: with neither onEscape nor
    // onDoubleEscape wired it only reaches the double-Esc clear, which is a
    // no-op on an untouched buffer; when those hooks are wired, cancel must
    // keep working mid-dispatch.
    final ownerless =
        _completer == null && !_queueModeActive && _keyCompleter == null;
    if (ownerless &&
        (event is CharInput ||
            event is PasteInput ||
            event is ArrowKey ||
            event is EditingKey ||
            event is AltKey ||
            event is ControlKey)) {
      return KeyHandledBy.nobody;
    }

    switch (event) {
      // The mouse wheel is routed to the focused panel's scrollback (it had
      // first claim above); an unclaimed wheel is dropped, never typed.
      case ScrollEvent():
        return KeyHandledBy.nobody;
      case CharInput(:final text):
        _dialog.dismiss();
        final code = text.codeUnitAt(0);
        final trigger = _activePicker == null
            ? _pickerForTrigger(code, _edit.buffer, _edit.cursor)
            : null;
        if (trigger != null) {
          _edit = _edit.insert(text);
          trigger.open(_edit.cursor - 1);
          _redraw();
          // Fire-and-forget; refresh schedules its own redraw.
          unawaited(trigger.refresh(_edit.buffer, _edit.cursor));
        } else {
          _edit = _edit.insert(text);
          _redraw();
          final active = _activePicker;
          if (active != null) {
            unawaited(active.refresh(_edit.buffer, _edit.cursor));
          }
        }

      case ControlKey(:final code):
        switch (code) {
          case ControlCode.ctrlC:
            // Unreachable: _onEventInner handles Ctrl+C before dispatch
            // (clear draft → quit confirm → quit).
          case ControlCode.ctrlD:
            if (_edit.buffer.isEmpty) {
              _complete(null);
            } else {
              _edit = _edit.deleteForward();
              _redraw();
            }
          case ControlCode.enter:
            final enterActive = _activePicker;
            if (enterActive != null) {
              final wasCommand = identical(enterActive, _commandPicker);
              _acceptPicker(enterActive);
              if (wasCommand) {
                // Accepting a command replaces the buffer with the command
                // text. Submit immediately — no second Enter needed.
                final result = _edit.buffer;
                _edit = _edit.addHistory(result).clear();
                _redraw();
                _complete(result);
              }
              return KeyHandledBy.chatBox;
            }
            final result = _edit.buffer;
            // Clear immediately: the submitted line must not sit in the input
            // region while the command's dispatch runs (a /index confirm +
            // fleet run can take minutes). The next readLine clears anyway;
            // clearing here makes the window invisible.
            _edit = _edit.addHistory(result).clear();
            // Repaint now: clearing state alone leaves the old text as stale
            // pixels whenever dispatch is slow (e.g. /compact summarizes
            // through an LLM call) — the next readLine's repaint only lands
            // after that await returns.
            _redraw();
            _complete(result);
          case ControlCode.tab:
            final tabActive = _activePicker;
            if (tabActive != null) _acceptPicker(tabActive);
          case ControlCode.backspace:
            _dialog.dismiss();
            _edit = _edit.backspace();
            final bsActive = _activePicker;
            if (bsActive != null && _edit.cursor <= bsActive.anchor) {
              bsActive.closeState();
            }
            _redraw();
            final bsStillActive = _activePicker;
            if (bsStillActive != null) {
              unawaited(bsStillActive.refresh(_edit.buffer, _edit.cursor));
            }
          case ControlCode.ctrlL:
            screen.clearChat();
            _redraw();
          case ControlCode.ctrlB:
          case ControlCode.ctrlW:
          case ControlCode.ctrlG:
          case ControlCode.ctrlS:
          case ControlCode.ctrlO:
          case ControlCode.ctrlR:
          case ControlCode.backtab:
            // Handled upstream by FocusManager when a panel exists; when no
            // panel is registered they fall through to here as a no-op.
            // ctrlS ("save") is consumed by the prompts overlay's readKey loop;
            // at the chat prompt it's a no-op. ctrlO (maximize) is consumed by
            // the onMaximizeToggle hook and ctrlR by onRawView — a fall-through
            // means nothing qualified, so they are no-ops too. backtab
            // (Shift+Tab) is consumed by the onBackTab hook; a fall-through
            // (no hook, or it declined) drops the key — backtab never types.
            break;
        }

      case ArrowKey ev:
        final direction = ev.direction;
        final arrowActive = _activePicker;
        if (arrowActive != null) {
          switch (direction) {
            case ArrowDirection.up:
              arrowActive.navigateUp();
              return KeyHandledBy.chatBox;
            case ArrowDirection.down:
              arrowActive.navigateDown();
              return KeyHandledBy.chatBox;
            case ArrowDirection.left:
            case ArrowDirection.right:
              arrowActive.closeState();
            case ArrowDirection.pageUp:
            case ArrowDirection.pageDown:
              break;
          }
        }
        final isWord = ev.hasCtrl || ev.hasAlt;
        switch (direction) {
          case ArrowDirection.up:
            _activePicker?.closeState();
            _edit = _edit.historyUp();
            _redraw();
          case ArrowDirection.down:
            _activePicker?.closeState();
            _edit = _edit.historyDown();
            _redraw();
          case ArrowDirection.left:
            _edit = isWord ? _edit.moveWordLeft() : _edit.moveLeft();
            _redraw();
          case ArrowDirection.right:
            _edit = isWord ? _edit.moveWordRight() : _edit.moveRight();
            _redraw();
          case ArrowDirection.pageUp:
          case ArrowDirection.pageDown:
            break;
        }

      case EditingKey(:final action):
        _activePicker?.closeState();
        switch (action) {
          case EditingAction.home:
            _edit = _edit.moveHome();
            _redraw();
          case EditingAction.end:
            _edit = _edit.moveEnd();
            _redraw();
          case EditingAction.delete:
            _edit = _edit.deleteForward();
            _redraw();
          case EditingAction.killToEnd:
            _edit = _edit.killToEnd();
            _redraw();
          case EditingAction.killToStart:
            _edit = _edit.killToStart();
            _redraw();
          case EditingAction.deleteWordBackward:
            _edit = _edit.killWordBackward();
            _redraw();
          case EditingAction.deleteWordForward:
            _edit = _edit.killWordForward();
            _redraw();
        }

      case EscapeKey():
        onEscape?.call();
      case AltKey(:final letter):
        if (onAltKey?.call(AltKey(letter)) ?? false) {
          return KeyHandledBy.appShortcut;
        }
        switch (letter) {
          case 0x62 /* b */ :
            _edit = _edit.moveWordLeft();
            _redraw();
          case 0x64 /* d */ :
            _edit = _edit.killWordForward();
            _redraw();
          case 0x66 /* f */ :
            _edit = _edit.moveWordRight();
            _redraw();
        }
      case UnknownEscape():
      case FunctionKey():
        break;
      case PasteInput(:final text):
        // A paste is an atomic token: dismiss any overlay, then record the
        // real text with a placeholder span. Submit still sends the real text.
        _dialog.dismiss();
        _activePicker?.closeState();
        _edit = _edit.addPaste(text);
        _redraw();
    }
    return KeyHandledBy.chatBox;
  }

  /// Whichever completion picker is currently open (at most one — `/` triggers
  /// at column 0, `@` mid-text), or null when neither is.
  CompletionPicker? get _activePicker {
    if (_picker.isActive) return _picker;
    if (_commandPicker.isActive) return _commandPicker;
    return null;
  }

  /// The picker that should open for [code] at the current buffer position, or
  /// null if none matches. Only consulted when no picker is already active.
  CompletionPicker? _pickerForTrigger(int code, String buffer, int cursor) {
    if (_picker.shouldTrigger(code, buffer, cursor)) return _picker;
    if (_commandPicker.shouldTrigger(code, buffer, cursor)) {
      return _commandPicker;
    }
    return null;
  }

  void _acceptPicker(CompletionPicker picker) {
    final result = picker.accept(_edit.buffer, _edit.cursor);
    if (result == null) {
      picker.closeState();
      _redraw();
      return;
    }
    _edit = _edit.replaceRange(result.start, result.end, result.text);
    picker.closeState();
    _redraw();
  }

  // -- Render -------------------------------------------------------------

  void _redraw() {
    InputLatency.stage(LatencyStage.bufferMutated);
    screen.input.render(
      prompt: _prompt,
      buffer: _edit.toDisplay(),
      cursor: _edit.displayCursor(_edit.cursor),
    );
    if (_dialog.isVisible) _dialog.render();
  }

  void _complete(String? result) {
    final c = _completer;
    _completer = null;
    c?.complete(result);
  }

  /// The confirmed quit: settle every pending read as cancelled, reset
  /// transient editor state, and complete a pending [readLine] with null so
  /// the controller's REPL loop unwinds into its exit path. An armed readKey
  /// (an approval/overlay prompt) resolves with the ctrlC event — its owner
  /// sees a cancelled prompt instead of hanging. Queue-mode scratch state is
  /// cleared too; a live turn underneath keeps running and is torn down by
  /// the controller's shutdown, not here.
  void _quitNow() {
    _lastEsc = null;
    _dialog.reset();
    _activePicker?.closeState();
    final key = _keyCompleter;
    _keyCompleter = null;
    _keyCompleterGlobal = false;
    key?.complete(ControlKey(ControlCode.ctrlC));
    _complete(null);
    _edit = _edit.clear().resetNavigation();
    _capturedDraft = null;
    _qBuf = '';
    _qCursor = 0;
    // Nothing pending may surface after the quit: held pastes and burst
    // overflow would otherwise dispatch into a dead readLine and repaint the
    // input row during teardown.
    _heldPastes.clear();
    _pending.clear();
    _burstTimer?.cancel();
    _burstTimer = null;
    _redraw();
  }

  // -- Queue mode ---------------------------------------------------------

  void _handleQueueEvent(InputEvent event) {
    // Any input dismisses an armed quit-confirm (the dialog must not linger
    // and turn a later keystroke into a surprise exit once readLine re-arms;
    // Ctrl+C itself never reaches here — the quit gate consumes it first).
    _dialog.dismiss();
    switch (event) {
      case ScrollEvent():
        return; // the wheel never drives queue/command history.
      case EscapeKey():
        if (_qBuf.isNotEmpty) {
          _qBuf = '';
          _qCursor = 0;
          _renderQueueDisplay();
        } else {
          _cancelHandler!();
        }
      case ControlKey(:final code):
        switch (code) {
          case ControlCode.enter:
            if (_qBuf.isNotEmpty) {
              _onQueueSubmit!(_qBuf);
              _qCount++;
            }
            _qBuf = '';
            _qCursor = 0;
            _renderQueueDisplay();
          case ControlCode.backspace:
            if (_qCursor > 0) {
              _qBuf =
                  _qBuf.substring(0, _qCursor - 1) + _qBuf.substring(_qCursor);
              _qCursor--;
            }
            _renderQueueDisplay();
          case ControlCode.tab:
          case ControlCode.ctrlL:
          case ControlCode.ctrlD:
          case ControlCode.ctrlW:
          case ControlCode.ctrlG:
          case ControlCode.ctrlS:
          case ControlCode.ctrlO:
          case ControlCode.ctrlR:
          case ControlCode.ctrlB:
            // The maximize toggle works in queue mode too — maximizing a
            // panel to watch a running agent is a primary use case. Same for
            // the raw-view overlay and the block cursor: reading output while
            // a turn runs is exactly when you want them.
            _handleMaximizeToggle(event);
            _handleRawView(event);
            _handleBlockCursor(event);
            break;
          case ControlCode.backtab:
            // Shift+Tab's mode cycling also works mid-turn: flipping the
            // permission mode while an agent runs changes how its NEXT tool
            // call is gated.
            _handleBackTab(event);
            break;
          case ControlCode.ctrlC:
            // Unreachable: the quit gate at the top of _onEventInner
            // consumes Ctrl+C before queue mode can see it.
            break;
        }
      case CharInput(:final text):
        _qBuf = _qBuf.substring(0, _qCursor) + text + _qBuf.substring(_qCursor);
        _qCursor += text.length;
        _renderQueueDisplay();
      case PasteInput(:final text):
        // Queue mode is linear ASCII entry: inject the real pasted text (no
        // placeholder) at the cursor.
        _qBuf = _qBuf.substring(0, _qCursor) + text + _qBuf.substring(_qCursor);
        _qCursor += text.length;
        _renderQueueDisplay();
      case ArrowKey():
      case EditingKey():
      case AltKey():
      case FunctionKey():
      case UnknownEscape():
        // Queue mode is linear ASCII entry only.
        break;
    }
  }

  void _renderQueueDisplay() {
    if (_qBuf.isNotEmpty) {
      screen.input.render(prompt: '> ', buffer: _qBuf, cursor: _qCursor);
    } else if (_qCount > 0) {
      final useColor = screen.ansi.useColor;
      final label = useColor
          ? screen.colorize(screen.theme.lineEditor.dim, '[$_qCount queued]')
          : '[$_qCount queued]';
      screen.input.render(prompt: label, buffer: '', cursor: 0);
    } else {
      screen.input.clear();
    }
  }
}
