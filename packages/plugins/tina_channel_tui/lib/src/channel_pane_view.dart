import 'dart:async';

import 'package:tina_channel/tina_channel.dart';
import 'package:tina_console/tina_console.dart';

import 'channel_pane.dart';

/// The group-channel pane: a status-bar pill with the unread count and
/// a modal browser (F5 cycles to the pill, Enter opens) that lists the
/// channels with unread badges and renders the selected channel's
/// recent messages — sender labels, status lines, presence footer.
/// Read-only: viewing is the only effect.
///
/// The store is polled (the log has no push channel yet — a Phase 3
/// watcher will add the event seam). Polling happens on a timer, and
/// the pane reads through [ChannelStoreApi] only.
final class ChannelPaneView implements ConsoleContribution {
  ChannelPaneView(this._store);

  final ChannelStoreApi _store;
  final ChannelUnread _unread = ChannelUnread();
  bool _seeded = false;

  ConsoleContext? _console;
  StatusCycleController? _cycle;
  _ChannelBrowser? _browser;
  void Function()? _removeBrowserModal, _removeModal, _removeEngage,
      _unbindStatus;
  Timer? _ticker;

  List<ChannelSummary> _channels = const [];
  final Map<String, int> _unreadCounts = {};

  /// Whether the channel browser is open. Public for tests.
  bool get isOpen => _browser?.isOpen == true;

  /// The browser's current visible lines. Public for tests.
  List<String> get visibleLines => _browser?.visibleLines ?? const [];

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
    _removeEngage = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f5) {
        _cycle!.toggle();
        return true;
      }
      return false;
    });
    _removeBrowserModal = context.addModal(_browser!);
    _unbindStatus = context.bindStatus(_lines, priority: 59);
    context.statusSelection.register('tina/channel', _browser!.open);

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
/// channel's recent messages below; read-only.
final class _ChannelBrowser implements ModalSurface {
  _ChannelBrowser(this.view);

  final ChannelPaneView view;

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
    repaint();
  }

  void close() {
    if (!_open) return;
    _open = false;
    _overlay?.hide();
    _releaseCursor?.call();
    _releaseCursor = null;
    visibleLines = const [];
  }

  void repaint() {
    final console = view._console;
    if (!_open || console == null || !console.isActive) return;
    if (console.isReadingKey) {
      _overlay?.hide();
      _releaseCursor?.call();
      _releaseCursor = null;
      return;
    }
    final area = dialogArea(console.screen.layout);
    if (area.width < 1 || area.height < 1) return;
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
    final body = renderChannelPane(
      channels: channels,
      unread: view._unreadCounts,
      selected: _selected,
      messages: messages,
      members: members,
      width: area.width,
      height: (area.height - 1).clamp(3, 10000),
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

  bool handleEvent(InputEvent event) {
    if (!isActive) return false;
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
        return true;
    }
  }

  void _move(int delta) {
    final channels = view._channels;
    if (channels.isEmpty) return;
    var index = channels.indexWhere((c) => c.name == _selected);
    if (index < 0) index = 0;
    index = (index + delta).clamp(0, channels.length - 1);
    _selected = channels[index].name;
    _scroll = 0;
    repaint();
  }
}
