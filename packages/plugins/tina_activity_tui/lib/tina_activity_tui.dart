library;

import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'src/activity_model.dart';
export 'src/activity_model.dart';

/// Optional console presentation over committed history and active-tool data.
/// The view owns its browser state and attachment, never the shared session.
final class ActivityView implements ConsoleContribution, ConsoleCommandHandler {
  ActivityView(this.connection, {bool? printTranscript})
      : _printTranscriptOverride = printTranscript;
  final SessionConnection connection;
  final bool? _printTranscriptOverride;
  bool _printTranscript = false;
  bool get printTranscript => _printTranscriptOverride ?? _printTranscript;
  final model = ActivityModel();
  ConsoleContext? _console;
  OverlayRegion? _overlay;
  void Function()? _releaseCursor;
  _ActivityModal? _modal;
  void Function()? _removeModal, _removeShortcut;
  SessionAttachment? _attachment;
  int _afterSeq = -1;
  bool _historyFailed = false, _detailsUnavailable = false;
  Timer? _ticker;
  bool _open = false;
  bool _liveLine = false;
  int _selected = 0;
  int _scroll = 0;
  bool _technical = false;
  bool get isOpen => _open;
  List<String> visibleLines = const [];
  @override
  Future<void>? handleConsoleCommand(String name, String arguments) {
    if (name != 'activity' || _console == null) return null;
    toggle();
    return Future.value();
  }

  /// Public event seam also used by embedders and deterministic view tests.
  void observe(ToolActivity event, {DateTime? at, bool replay = false}) {
    final previous = model.record(event.call);
    if (previous.finished && event is! ToolStarted) return;
    final outputStart = event is ToolStarted ? 0 : previous.output.length;
    final wasTruncated = previous.truncated;
    model.event(event, at: at);
    final row = model.record(event.call);
    if (printTranscript && !replay)
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
    _console?.chat.writeln(text);
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
    model.records.clear();
    _afterSeq = -1;
    _historyFailed = false;
    final attachment = _attachment = connection.attach();
    context.own(attachment.close);
    _apply(attachment, attachment.initial, replay: true);
    unawaited(_observe(attachment));
    _removeShortcut = context.bindShortcut((event) {
      if (event is FunctionKey && event.code == FunctionKeyCode.f4) {
        toggle();
        return true;
      }
      return false;
    });
  }

  Future<void> _observe(SessionAttachment attachment) async {
    try {
      while (identical(_attachment, attachment)) {
        final update = await attachment.next();
        if (update == null || !identical(_attachment, attachment)) return;
        _apply(attachment, update.snapshot);
        if (update.snapshot.status.closed) attachment.close();
      }
    } catch (_) {
      // A failed browser retires only its own subscription.
      attachment.close();
    }
  }

  void _apply(SessionAttachment attachment, SessionSnapshot snapshot,
      {bool replay = false}) {
    final feature = snapshot.features['tina/activity-tui'] as Map?;
    if (feature?['print_transcript'] case final bool enabled)
      _printTranscript = enabled;
    _detailsUnavailable =
        snapshot.unavailableFeatures.contains('tina/activity-tui');
    if (snapshot.historyPublicationFailed && !_historyFailed) {
      // A failed publication may have exposed transient work. Rebuild the
      // inspector from the last confirmed prefix, without reprinting history.
      model.records.clear();
      _afterSeq = -1;
      replay = true;
    }
    _historyFailed = snapshot.historyPublicationFailed;
    while (_afterSeq < snapshot.throughSeq) {
      final page = attachment.history(snapshot: snapshot, afterSeq: _afterSeq);
      if (page.nextAfterSeq <= _afterSeq)
        throw StateError('History cursor did not advance');
      for (final data in page.entries) {
        final metadata =
            (data['features'] as Map?)?['tina/activity-tui'] as Map? ??
                const {};
        final descriptions = metadata['tool_descriptions'] as Map? ?? const {};
        model.describe =
            (call) => ToolDescription.fromJson(descriptions[call.id]);
        final entry = SessionEntry.fromJson(Map<String, dynamic>.from(data));
        final completed = model.entry(
            entry, replay ? LogEvent.replay : LogEvent.appended,
            metadata: metadata);
        if (!replay) for (final row in completed) _completion(row);
        _afterSeq = entry.seq;
      }
    }
    // Descriptions are supplied with the committed call entry, never by asking
    // the runtime plugin from a renderer callback.
    model.describe = null;
    if (!_historyFailed) {
      for (final item in snapshot.activeTools.entries) {
        final state = item.value as Map;
        final call = ToolUse(
            id: item.key,
            name: state['name'] as String,
            input: Map<String, dynamic>.from(state['input'] as Map));
        final row = model.record(call);
        if (row.finished) continue;
        final starting = row.state != 'running';
        final oldOutput = row.output;
        final wasTruncated = row.truncated;
        final started = DateTime.tryParse(state['started_at'] as String? ?? '');
        if (starting) observe(ToolStarted(call), at: started, replay: replay);
        final progress = plainText(state['status'] as String? ?? '');
        if (progress != row.progress)
          observe(ToolProgress(call, progress), replay: replay);
        final output = plainText(state['output'] as String? ?? '');
        if (output.startsWith(oldOutput) && output.length > oldOutput.length)
          observe(ToolOutput(call, output.substring(oldOutput.length)),
              replay: replay);
        row.started = started;
        row.progress = progress;
        row.progressHistory
          ..clear()
          ..addAll((state['progress_history'] as List? ?? const [])
              .cast<String>()
              .map(plainText));
        row.output = output;
        row.truncated = state['output_truncated'] == true;
        if (printTranscript && !replay && row.truncated && !wasTruncated)
          _line('[further live output hidden]');
      }
    }
    repaintConsole();
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
    if (_historyFailed)
      body.add('Live activity unavailable; displaying confirmed history.');
    else if (_detailsUnavailable)
      body.add('Some activity details are unavailable.');
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
    _attachment?.close();
    _attachment = null;
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
}

final class _ActivityModal extends ModalSurface {
  _ActivityModal(this.owner);
  final ActivityView owner;
  @override
  bool get isActive => owner.isOpen && owner._console?.isReadingKey != true;
  @override
  bool handleEvent(InputEvent event) => owner._key(event);
}
