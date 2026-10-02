library;

import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'src/activity_model.dart';
export 'src/activity_model.dart';

/// Optional console presentation. It consumes ordinary log/tool observations;
/// neither the host nor the application needs to recognize an activity panel.
final class ActivityTuiPlugin extends AgentPlugin
    implements ConsoleContribution {
  ActivityTuiPlugin({required this.terminal, this.printTranscript = true});
  final bool printTranscript;
  final Terminal terminal;
  final model = ActivityModel();
  @override
  String get id => 'tina/activity-tui';
  ConsoleContext? _console;
  OverlayRegion? _overlay;
  void Function()? _releaseCursor;
  _ActivityModal? _modal;
  void Function()? _removeModal, _removeShortcut;
  StreamSubscription<ToolActivity>? _subscription;
  AgentLoop? _loop;
  int? _logHandle;
  Timer? _ticker;
  bool _open = false;
  bool _liveLine = false;
  int _selected = 0;
  int _scroll = 0;
  bool _technical = false;
  bool get isOpen => _open;
  List<String> visibleLines = const [];
  @override
  List<Command> get commands => [
        Command(
            name: 'activity',
            description: 'browse tool results, diffs and child progress (F4)',
            handler: (_) => toggle())
      ];

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    model.describe =
        (call) => loop.toolSchema(call.name)?.describe?.call(call.input);
    _logHandle = loop.subscribe((entry, event) {
      final completed = model.entry(entry, event);
      if (event == LogEvent.appended) {
        for (final row in completed) {
          _completion(row);
        }
      }
      repaintConsole();
    });
    _subscription = loop.toolActivity.listen(observe);
  }

  /// Public event seam also used by embedders and deterministic view tests.
  void observe(ToolActivity event) {
    final previous = model.record(event.call);
    if (previous.finished && event is! ToolStarted) return;
    final outputStart = event is ToolStarted ? 0 : previous.output.length;
    final wasTruncated = previous.truncated;
    model.event(event);
    final row = model.record(event.call);
    if (printTranscript)
      switch (event) {
        case ToolStarted():
          _line(
              '${row.label} — running${row.target.isEmpty ? '' : ' · ${bounded(row.target, 100)}'}');
        case ToolProgress():
          _line(row.progress);
        case ToolOutput():
          final clean = row.output.substring(outputStart);
          final console = _console;
          if (console != null) {
            console.screen.frame(() => console.chat.write(clean));
            if (clean.isNotEmpty) _liveLine = !clean.endsWith('\n');
          }
          if (row.truncated && !wasTruncated)
            _line('[further live output hidden]');
        case ToolFinished():
          _completion(row);
      }
    repaintConsole();
  }

  void _line(String text) {
    if (_liveLine) {
      _console?.screen.frame(() => _console!.chat.writeln());
      _liveLine = false;
    }
    terminal.writeln(text);
  }

  void _completion(ActivityRecord row) {
    if (!printTranscript) return;
    _line(
        '${row.label} — ${row.state}${row.duration.isEmpty ? '' : ' · ${row.duration}'}');
    final preview = bounded(row.summary, 400);
    if (preview.isNotEmpty) _line(preview);
    final old = row.call.input['oldString'],
        fresh = row.call.input['newString'];
    if (row.result?.isError == false && old is String && fresh is String) {
      final diff = replacementDiff(old, fresh);
      for (final line in diff.take(8)) {
        _line(line);
      }
      if (diff.length > 8) _line('… more in /activity (F4)');
    } else if (row.result?.isError == true) {
      _line('Details and recovery: /activity (F4)');
    }
  }

  void toggle() {
    if (_console == null) {
      terminal.writeln('Activity requires the interactive console.');
      return;
    }
    if (_open) {
      _hide();
      return;
    }
    _open = true;
    _selected = model.records.isEmpty ? 0 : model.records.length - 1;
    _scroll = 0;
    _technical = false;
    _ticker = Timer.periodic(
        const Duration(milliseconds: 250), (_) => repaintConsole());
    repaintConsole(followSelection: true);
  }

  void _hide() {
    _open = false;
    _ticker?.cancel();
    _ticker = null;
    _overlay?.hide();
    _releaseCursor?.call();
    _releaseCursor = null;
    visibleLines = const [];
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    _overlay = OverlayRegion(
        context.screen, const Rect(row: 0, col: 0, width: 0, height: 0));
    _modal = _ActivityModal(this);
    _removeModal = context.addModal(_modal!);
    _removeShortcut = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f4) {
        toggle();
        return true;
      }
      return false;
    });
  }

  @override
  void repaintConsole({bool followSelection = false}) {
    final console = _console;
    if (!_open || console == null) return;
    // A settings/approval key reader takes priority over this passive browser.
    // It never inherits a key intended to expand or scroll a tool result.
    if (console.isReadingKey || !console.isActive) {
      _overlay?.hide();
      _releaseCursor?.call();
      _releaseCursor = null;
      return;
    }
    final area = dialogArea(console.screen.layout);
    if (area.width < 1 || area.height < 1) return;
    _releaseCursor ??= console.own(console.screen.claimCursor().release);
    _selected = _selected.clamp(
        0, model.records.isEmpty ? 0 : model.records.length - 1);
    final body = <String>[];
    var selectedLine = 0;
    for (var i = 0; i < model.records.length; i++) {
      final row = model.records[i];
      if (i == _selected) selectedLine = body.length;
      final marker = i == _selected
          ? '❯'
          : row.expanded
              ? '▾'
              : '▸';
      body.add(
          '$marker ${row.label} · ${row.state} ${row.duration} · ${row.target}');
      if (row.expanded) {
        for (final text in row.details(technical: _technical)) {
          for (final line in text.split('\n')) {
            body.addAll(wrapDialogText(line, (area.width - 2).clamp(1, 10000))
                .map((s) => '  $s'));
          }
        }
      } else if (row.progress.isNotEmpty && !row.finished) {
        body.add('    ${row.progress}');
      }
    }
    final room = (area.height - 2).clamp(1, 10000);
    if (body.isEmpty) body.add('No tool calls yet.');
    if (followSelection) {
      if (model.records.isNotEmpty && model.records[_selected].expanded) {
        _scroll = selectedLine;
      }
      if (selectedLine < _scroll) _scroll = selectedLine;
      if (selectedLine >= _scroll + room) _scroll = selectedLine - room + 1;
    }
    _scroll = _scroll.clamp(0, (body.length - room).clamp(0, body.length));
    final running = model.records.where((r) => r.state == 'running').length;
    visibleLines = [
      'Activity · ${model.records.length} recent calls · $running running',
      ...body.skip(_scroll).take(room),
      '↑↓ select · Enter expand · T details · PgUp/PgDn · Esc close',
    ].take(area.height).map((s) => clipDialogText(s, area.width)).toList();
    final painted = visibleLines.map((line) {
      final clean = line.trimLeft();
      final color = clean.startsWith('- ')
          ? '31'
          : clean.startsWith('+ ')
              ? '32'
              : null;
      return color == null ? line : console.screen.colorize(color, line);
    }).toList();
    _overlay!.update(bounds: area, lines: painted);
  }

  bool _key(InputEvent event) {
    if (!_open || _console?.isReadingKey == true) return false;
    switch (event) {
      case EscapeKey():
        _hide();
        return true;
      case FunctionKey(code: FunctionKeyCode.f4):
        _hide();
        return true;
      case ArrowKey(direction: ArrowDirection.up):
        _selected--;
        repaintConsole(followSelection: true);
      case ArrowKey(direction: ArrowDirection.down):
        _selected++;
        repaintConsole(followSelection: true);
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll -= 5;
        repaintConsole();
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll += 5;
        repaintConsole();
      case ScrollEvent(:final up):
        _scroll += up ? -3 : 3;
        repaintConsole();
      case ControlKey(code: ControlCode.enter):
      case ControlKey(code: ControlCode.tab):
        if (model.records.isNotEmpty)
          model.records[_selected].expanded =
              !model.records[_selected].expanded;
        repaintConsole(followSelection: true);
      case CharInput(text: 't' || 'T'):
        _technical = !_technical;
        repaintConsole(followSelection: true);
      default:
        break;
    }
    return true;
  }

  @override
  void detachConsole() {
    _hide();
    _removeShortcut?.call();
    _removeModal?.call();
    _removeShortcut = null;
    _removeModal = null;
    _overlay?.dispose();
    _overlay = null;
    _console = null;
    _modal = null;
  }

  @override
  void closeSession() {
    detachConsole();
    unawaited(_subscription?.cancel());
    _subscription = null;
    final handle = _logHandle;
    if (handle != null) _loop?.unsubscribe(handle);
    _logHandle = null;
    _loop = null;
  }
}

final class _ActivityModal extends ModalSurface {
  _ActivityModal(this.owner);
  final ActivityTuiPlugin owner;
  @override
  bool get isActive => owner.isOpen && owner._console?.isReadingKey != true;
  @override
  bool handleEvent(InputEvent event) => owner._key(event);
}
