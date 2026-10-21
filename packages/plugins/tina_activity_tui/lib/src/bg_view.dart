import 'dart:async';

import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';

import 'activity_model.dart';

/// A status-bar contribution that reports how many background processes
/// (running shell/process tool calls) the session has in flight, and a
/// browsable list of them with live stdout.
///
/// Interaction:
/// - The status pill (e.g. `● 2 bg`) appears while any background process is
///   running. Press F5 to enter status cycling, move the highlight to the
///   pill, and press Enter to open the browser.
/// - Inside the browser, ↑/↓ cycle the running processes and Enter expands
///   the selected process to show its streaming output. Esc closes the
///   browser; Esc again (or F5) leaves status cycling.
final class BgView implements ConsoleContribution {
  BgView(this.connection);

  final SessionConnection connection;
  _BgBrowser? _browser;

  ConsoleContext? _console;
  StatusCycleController? _cycle;
  SessionAttachment? _attachment;
  void Function()? _removeBrowserModal, _removeModal, _removeEngage, _unbindStatus;
  Timer? _ticker;

  final _byId = <String, _BgProc>{};
  final _order = <String>[];
  bool _registered = false;

  List<_BgProc> get _procs => [for (final id in _order) _byId[id]!];

  /// Whether the background-process browser is open. Public for tests.
  bool get isOpen => _browser?.isOpen == true;

  /// The browser's current visible lines. Public for tests.
  List<String> get visibleLines => _browser?.visibleLines ?? const [];

  /// Public event seam also used by embedders and deterministic view tests:
  /// apply a snapshot of active tool state.
  void applyActiveTools(Map<String, Object?> tools) {
    _apply(tools);
    _console?.refreshStatus();
    _browser?.repaint();
  }

  /// Visible status lines: a count pill, styled with the selection color while
  /// cycling highlights this segment.
  List<RenderLine> _lines() {
    final console = _console;
    if (console == null) return const [];
    final n = _procs.length;
    if (n == 0) return const [];
    final highlighted = console.statusSelection.isHighlighted('tina/bg');
    final code = highlighted
        ? console.screen.theme.border.selection
        : console.screen.theme.chat.dim;
    return [
      RenderLine(runs: [RenderRun('● $n bg', code)]),
    ];
  }

  static bool _isBackground(Map<dynamic, dynamic> state) {
    final input = state['input'];
    if (input is! Map) return false;
    return input['command'] is String || input['program'] is String;
  }

  void _apply(Map<String, Object?> tools) {
    final nextIds = <String>{};
    for (final entry in tools.entries) {
      final state = entry.value;
      if (state is! Map) continue;
      if (!_isBackground(state)) continue;
      final id = entry.key;
      nextIds.add(id);
      final existing = _byId[id];
      if (existing != null) {
        existing.state = state;
      } else {
        _byId[id] = _BgProc(state);
        _order.add(id);
      }
    }
    for (final id in _byId.keys.toList()) {
      if (!nextIds.contains(id)) {
        _byId.remove(id);
        _order.remove(id);
      }
    }
    _syncRegistration();
  }

  void _syncRegistration() {
    final selection = _console?.statusSelection;
    if (selection == null) return;
    if (_procs.isNotEmpty && !_registered) {
      selection.register('tina/bg', _browser!.open);
      _registered = true;
    } else if (_procs.isEmpty && _registered) {
      selection.unregister('tina/bg');
      _registered = false;
    }
  }

  Future<void> _observe(SessionAttachment attachment) async {
    try {
      while (identical(_attachment, attachment)) {
        final update = await attachment.next();
        if (update == null || !identical(_attachment, attachment)) return;
        _apply(update.snapshot.activeTools);
        _console?.refreshStatus();
        _browser?.repaint();
      }
    } catch (_) {
      attachment.close();
    }
  }

  void _repaintTick() {
    if (_browser?.isActive == true) _browser!.repaint();
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _browser = _BgBrowser(this);

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
    _unbindStatus = context.bindStatus(_lines, priority: 60);

    final attachment = _attachment = connection.attach();
    context.own(attachment.close);
    _apply(attachment.initial.activeTools);
    unawaited(_observe(attachment));
    _ticker =
        Timer.periodic(const Duration(seconds: 1), (_) => _repaintTick());
    context.refreshStatus();
  }

  @override
  void repaintConsole() {
    _browser?.repaint();
    _console?.refreshStatus();
  }

  @override
  void detachConsole() {
    _attachment?.close();
    _attachment = null;
    _ticker?.cancel();
    _ticker = null;
    _browser?.close();
    _browser = null;
    _removeBrowserModal?.call();
    _removeBrowserModal = null;
    _removeModal?.call();
    _removeModal = null;
    _removeEngage?.call();
    _removeEngage = null;
    _unbindStatus?.call();
    _unbindStatus = null;
    if (_registered) _console?.statusSelection.unregister('tina/bg');
    _registered = false;
    _byId.clear();
    _order.clear();
    _cycle = null;
    _console = null;
  }
}

/// A single running background process, backed by its live tool state.
final class _BgProc {
  _BgProc(this.state);
  Map<dynamic, dynamic> state;
  bool expanded = false;

  String get id => state['id'] as String? ?? '';
  String get name => state['name'] as String? ?? '';
  String get output => state['output'] as String? ?? '';
  bool get truncated => state['output_truncated'] == true;
  String get progress => state['status'] as String? ?? '';

  String get target {
    final input = state['input'] as Map? ?? const {};
    for (final key in ['command', 'program']) {
      final value = input[key];
      if (value is String) {
        final flat = plainText(value).trim();
        if (flat.isNotEmpty) return flat.split('\n').first;
      }
    }
    return '';
  }

  DateTime? get startedAt {
    final raw = state['started_at'] as String?;
    return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
  }
}

/// The browser modal: a list of running background processes with an
/// expandable live-output viewer for the selected one.
final class _BgBrowser implements ModalSurface {
  _BgBrowser(this.view);
  final BgView view;

  OverlayRegion? _overlay;
  void Function()? _releaseCursor;

  bool _open = false;
  int _selected = 0;
  int _scroll = 0;
  List<String> visibleLines = const [];

  bool get isOpen => _open;
  bool get isActive => _open;

  void open() {
    _open = true;
    final procs = view._procs;
    _selected = procs.isEmpty ? 0 : procs.length - 1;
    _scroll = 0;
    repaint(followSelection: true);
  }

  void close() {
    if (!_open) return;
    _open = false;
    _overlay?.hide();
    _releaseCursor?.call();
    _releaseCursor = null;
    visibleLines = const [];
  }

  void repaint({bool followSelection = false}) {
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

    final procs = view._procs;
    if (_selected >= procs.length) _selected = procs.isEmpty ? 0 : procs.length - 1;
    final now = DateTime.now();
    final body = <String>[];
    var selectedLine = 0;
    for (var i = 0; i < procs.length; i++) {
      final p = procs[i];
      if (i == _selected) selectedLine = body.length;
      final marker = i == _selected
          ? '❯'
          : p.expanded
              ? '▾'
              : '▸';
      body.add(
          '$marker ${p.name} · ${_duration(p, now)} · ${bounded(p.target, 120)}');
      if (p.progress.isNotEmpty) {
        body.add('    ${bounded(plainText(p.progress), 100)}');
      }
      if (p.expanded) {
        final output = p.output.isEmpty ? '(no output yet)' : p.output;
        for (final line in wrapDialogText(output, (area.width - 4).clamp(1, 10000))) {
          body.addAll(wrapDialogText('  $line', (area.width - 4).clamp(1, 10000)));
        }
        if (p.truncated) body.add('  [output truncated]');
      }
    }
    if (body.isEmpty) body.add('No background processes running.');
    final room = (area.height - 2).clamp(1, 10000);
    if (followSelection) {
      if (selectedLine < _scroll) _scroll = selectedLine;
      if (selectedLine >= _scroll + room) _scroll = selectedLine - room + 1;
    }
    _scroll = _scroll.clamp(0, (body.length - room).clamp(0, body.length));
    visibleLines = [
      'Background processes · ${procs.length} running',
      ...body.skip(_scroll).take(room),
      '↑↓ select · Enter expand output · Esc close',
    ].take(area.height).map((s) => clipDialogText(s, area.width)).toList();
    _overlay ??= OverlayRegion(console.screen,
        Rect(row: 0, col: 0, width: 0, height: 0));
    _overlay!.update(bounds: area, lines: visibleLines);
  }

  static String _duration(_BgProc p, DateTime now) {
    final started = p.startedAt;
    if (started == null) return '';
    final d = now.difference(started);
    if (d.inSeconds < 0) return '';
    if (d.inSeconds < 60) return '${d.inSeconds}s';
    return '${d.inMinutes}m ${d.inSeconds % 60}s';
  }

  bool handleEvent(InputEvent event) {
    if (!isActive) return false;
    switch (event) {
      case EscapeKey():
      case FunctionKey(code: FunctionKeyCode.f5):
        close();
        return true;
      case ArrowKey(direction: ArrowDirection.up):
        if (view._procs.isNotEmpty) _selected = (_selected - 1).clamp(0, view._procs.length - 1);
        repaint(followSelection: true);
        return true;
      case ArrowKey(direction: ArrowDirection.down):
        if (view._procs.isNotEmpty) _selected = (_selected + 1).clamp(0, view._procs.length - 1);
        repaint(followSelection: true);
        return true;
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll -= 5;
        repaint();
        return true;
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll += 5;
        repaint();
        return true;
      case ScrollEvent(:final up):
        _scroll += up ? -3 : 3;
        repaint();
        return true;
      case ControlKey(code: ControlCode.enter):
      case ControlKey(code: ControlCode.tab):
        if (view._procs.isNotEmpty) {
          final p = view._procs[_selected];
          p.expanded = !p.expanded;
        }
        repaint(followSelection: true);
        return true;
      default:
        return true;
    }
  }
}
