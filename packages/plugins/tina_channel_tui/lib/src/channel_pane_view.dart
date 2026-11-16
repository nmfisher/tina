import 'dart:async';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_console/tina_console.dart';

import 'channel_pane.dart';

/// The group-channel pane: a status-bar pill with the unread count and
/// a browser (F5 cycles to the pill, Enter opens) that lists the
/// channels with unread badges and renders the selected channel's
/// recent messages — sender labels, status lines, presence footer.
///
/// Where it renders follows the side column (owner layout directive):
/// classifier, plans and this pane stack in a fixed column on the
/// right of the conversation, with the channel pane taking the
/// majority of the column height. On terminals too narrow for the
/// column, the browser is today's full-screen modal — same
/// interaction, different geometry.
///
/// Interactive: with the pane open, typing composes a message on the
/// input line and Enter posts it as the human identity ([humanName],
/// decided at the composition seam) through the store interface — a
/// member row (`human`) joins the channel, `@mentions` parse as in the
/// tools. Esc leaves input mode (draft kept), Esc again closes the
/// pane, and a closed pane consumes nothing. When [humanName] is null
/// (no writable identity in this context) the input line renders
/// disabled with a hint instead.
///
/// The store is polled (the log has no push channel yet — a Phase 3
/// watcher will add the event seam). Polling happens on a timer, and
/// the pane reads and posts through [ChannelStoreApi] only.
final class ChannelPaneView implements ConsoleContribution {
  ChannelPaneView(this._store, {String? humanName})
      : _humanName = humanName;

  final ChannelStoreApi _store;

  /// The identity the input line posts under; null disables input.
  final String? _humanName;

  /// Channels this session already joined (announced) as the human.
  final Set<String> _joined = <String>{};

  final ChannelUnread _unread = ChannelUnread();
  bool _seeded = false;

  ConsoleContext? _console;
  StatusCycleController? _cycle;
  _ChannelBrowser? _browser;
  SideColumnPanel? _column;
  void Function()? _removeBrowserModal, _removeModal, _removeEngage,
      _unbindStatus;
  Timer? _ticker;

  List<ChannelSummary> _channels = const [];
  final Map<String, int> _unreadCounts = {};

  /// Whether the channel browser is open. Public for tests.
  bool get isOpen => _browser?.isOpen == true;

  /// Whether the input line has focus (composing). Public for tests.
  bool get inputActive => _browser?.composer.isActive == true;

  /// The browser's current visible lines. Public for tests.
  List<String> get visibleLines => _browser?.visibleLines ?? const [];

  /// Opens the pane. The status pill's Enter lands here too; public so
  /// tests (and future callers) open it without the status cycle.
  void openPane() => _browser?.open();

  /// The human joins [channel] if this session hasn't yet. A borrowed
  /// or flaky store must not take the pane down; a failed join surfaces
  /// on the next post instead.
  void _humanJoin(String channel) {
    final name = _humanName;
    if (name == null) return;
    try {
      humanJoin(_store, channel, name, _joined);
    } on Object {
      // Presence is best-effort; posting reports its own errors.
    }
  }

  List<RenderLine> _lines() {
    final console = _console;
    if (console == null) return const [];
    final total = _unreadCounts.values.fold<int>(0, (a, b) => a + b);
    if (total == 0) return const [];
    final highlighted = console.statusSelection.isHighlighted('tina/channel');
    final code = highlighted
        ? console.screen.theme.border.selection
        : console.screen.theme.chat.dim;
    return [
      RenderLine(runs: [RenderRun('ch ●$total', code)]),
    ];
  }

  void _poll() {
    try {
      _channels = _store.listChannels();
      if (!_seeded) {
        _unread.seed(_channels);
        _seeded = true;
      }
      _unreadCounts
        ..clear()
        ..addAll(_unread.refresh(_channels));
      if (_browser?.isActive == true && !_console!.isReadingKey) {
        _browser!.repaint();
      }
      _console?.refreshStatus();
    } on Object {
      // The store is a borrowed link; an unavailable poll must never
      // take the session down. The next tick retries.
    }
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _browser = _ChannelBrowser(this);

    _cycle = StatusCycleController(context);
    _removeModal = context.addModal(_cycle!);
    _column =
        context.bindSideColumnPanel(_browser!.repaint, rank: SideColumnRank.channel);
    _removeEngage = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f5) {
        _cycle!.toggle();
        return true;
      }
      return false;
    });
    _removeBrowserModal = context.addModal(_browser!);
    _unbindStatus = context.bindStatus(_lines, priority: 59);
    context.statusSelection.register('tina/channel', openPane);

    _poll();
    _ticker =
        Timer.periodic(const Duration(seconds: 2), (_) => _poll());
  }

  @override
  void repaintConsole() {
    _poll();
    _browser?.repaint();
    _console?.refreshStatus();
  }

  @override
  void detachConsole() {
    _ticker?.cancel();
    _ticker = null;
    _browser?.close();
    _browser = null;
    _column?.dispose();
    _column = null;
    _removeBrowserModal?.call();
    _removeBrowserModal = null;
    _removeEngage?.call();
    _removeEngage = null;
    _unbindStatus?.call();
    _unbindStatus = null;
    _console?.statusSelection.unregister('tina/channel');
    _removeModal?.call();
    _removeModal = null;
    _cycle = null;
    _console = null;
  }
}

/// The browser modal: channel list with unread badges; the selected
/// channel's recent messages below; the input line when composing.
final class _ChannelBrowser implements ModalSurface {
  _ChannelBrowser(this.view)
      : composer = ChannelComposer(canPost: view._humanName != null);

  final ChannelPaneView view;
  final ChannelComposer composer;

  OverlayRegion? _overlay;
  void Function()? _releaseCursor;

  bool _open = false;
  String _selected = '#lobby';
  int _scroll = 0;
  List<String> visibleLines = const [];

  bool get isOpen => _open;
  bool get isActive => _open;

  void open() {
    _open = true;
    final channels = view._channels;
    if (channels.isNotEmpty && channels.every((c) => c.name != _selected)) {
      _selected = channels.first.name;
    }
    _scroll = 0;
    // Opening the pane is joining the conversation: presence first,
    // then the input line ready for typing (chat-first).
    view._humanJoin(_selected);
    composer.activate();
    _syncColumnSlot();
    repaint();
  }

  /// Keeps the side-column slot in step: open on a terminal wide
  /// enough for the column claims the remainder of the column (the
  /// majority of its height); otherwise no footprint — a closed pane
  /// renders nowhere, and on narrow terminals the browser is the
  /// full-screen modal instead. The gate is [SideColumnLayout.fits],
  /// not the column's current active state: the column only becomes
  /// active once some panel claims, so an open pane must claim on
  /// wide terminals to make it true.
  void _syncColumnSlot() {
    final slot = view._column;
    final console = view._console;
    if (slot == null || console == null) return;
    final claim = _open &&
        console.isActive &&
        SideColumnLayout.fits(console.screen.layout.width);
    slot.requestSize(height: claim ? 10000 : 0);
  }

  void close() {
    if (!_open) return;
    _open = false;
    _overlay?.hide();
    _releaseCursor?.call();
    _releaseCursor = null;
    visibleLines = const [];
    _syncColumnSlot();
  }

  void repaint() {
    final console = view._console;
    if (!_open || console == null || !console.isActive) return;
    // A resize may have crossed the column threshold either way; the
    // claim follows the CURRENT width (open + fits), not the width at
    // open time.
    _syncColumnSlot();
    if (console.isReadingKey) {
      _overlay?.hide();
      _releaseCursor?.call();
      _releaseCursor = null;
      return;
    }
    // Geometry: the side column's slot when the column is active
    // (right of the conversation, majority of the column height);
    // today's full-screen dialog area otherwise.
    final column = view._column;
    final area = column != null && column.columnActive
        ? column.bounds
        : dialogArea(console.screen.layout);
    if (area.width < 1 || area.height < 1) {
      _overlay?.hide();
      return;
    }
    _releaseCursor ??= console.own(console.screen.claimCursor().release);

    final store = view._store;
    final channels = view._channels;
    if (channels.isNotEmpty &&
        channels.every((c) => c.name != _selected)) {
      _selected = channels.first.name;
    }
    // Viewing the channel is reading it: the badge clears.
    view._unread.markRead(_selected, store.lastMessageId(_selected));
    view._unreadCounts.remove(_selected);

    final messages = store.read(_selected, limit: 50);
    final members = store.members(_selected);
    final input = !composer.canPost
        ? const ChannelInputLine(
            disabledHint: 'input unavailable — use tina channel say')
        : composer.isActive
            ? ChannelInputLine(draft: composer.draft, error: composer.error)
            : null;
    final body = renderChannelPane(
      channels: channels,
      unread: view._unreadCounts,
      selected: _selected,
      messages: messages,
      members: members,
      width: area.width,
      height: (area.height - 1).clamp(3, 10000),
      self: view._humanName,
      input: input,
    );
    final room = (area.height - 2).clamp(1, 10000);
    _scroll = _scroll.clamp(0, (body.length - room).clamp(0, body.length));
    visibleLines = [
      ...body.skip(_scroll).take(room),
      if (body.length > room) '↑↓ channel · PgUp/PgDn scroll · Esc close',
    ].map((line) => clipDialogText(line, area.width)).toList();
    _overlay ??= OverlayRegion(console.screen,
        Rect(row: 0, col: 0, width: 0, height: 0));
    _overlay!.update(bounds: area, lines: visibleLines);
  }

  /// Posts one message as the human through the store interface.
  /// Returns an error message, or null on success.
  String? _post(String text) {
    final name = view._humanName;
    if (name == null) return 'input unavailable';
    final failure = humanPost(view._store,
        channel: _selected, name: name, text: text, joined: view._joined);
    if (failure == null) view._poll();
    return failure;
  }

  bool handleEvent(InputEvent event) {
    if (!isActive) return false;
    // The input line claims typing first: a composing pane is a chat
    // surface. Declined events (arrows, scrolling) fall through to the
    // browse handling below.
    if (composer.handle(event, post: _post)) {
      repaint();
      return true;
    }
    switch (event) {
      case EscapeKey():
      case FunctionKey(code: FunctionKeyCode.f5):
        close();
        return true;
      case ArrowKey(direction: ArrowDirection.up):
        _move(-1);
        return true;
      case ArrowKey(direction: ArrowDirection.down):
        _move(1);
        return true;
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll -= 10;
        repaint();
        return true;
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll += 10;
        repaint();
        return true;
      case ScrollEvent(:final up):
        _scroll += up ? -3 : 3;
        repaint();
        return true;
      default:
        return true; // modal while open: nothing leaks to the editor
    }
  }

  void _move(int delta) {
    final channels = view._channels;
    if (channels.isEmpty) return;
    var index = channels.indexWhere((c) => c.name == _selected);
    if (index < 0) index = 0;
    index = (index + delta).clamp(0, channels.length - 1);
    final next = channels[index].name;
    if (next != _selected) {
      _selected = next;
      view._humanJoin(_selected); // viewing a channel joins it
    }
    _scroll = 0;
    repaint();
  }
}
