import 'package:tina_plans/tina_plans.dart';
import 'package:tina_goals/tina_goals.dart';
import 'dart:async';
import 'dart:convert';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'chat_transcript.dart';
import 'markdown_renderer.dart';
import 'prompt.dart';
import 'timestamp_chat.dart';
import 'status_layout.dart';

/// Legacy transcript presentation driven by engine2's read-only observations.
/// This plugin owns chat rows, folds, timestamps and the live model prompt.
/// No UI state is written into the model's messages.
final class ChatTuiPlugin extends AgentPlugin
    implements ConsoleContribution, ConsoleTranscript, WatchObserver {
  ChatTuiPlugin(
      {required this.model,
      this.tokenCap = 0,
      this.sessionTokens,
      this.sessionEstimatedTokens,
      this.showSessionId = true,
      DateTime Function()? now})
      : _now = now ?? DateTime.now,
        renderer = TimestampChatRenderer(now: now ?? DateTime.now);
  final String model;
  final int tokenCap;
  final int Function()? sessionTokens;
  final int Function()? sessionEstimatedTokens;
  final bool showSessionId;
  String? _sessionId;
  int _tokens = 0;
  PlanChangedEntry? _plan;
  GoalChangedEntry? _goal;
  @override
  SessionSeed? openSession(PluginSession session) {
    _sessionId = session.id;
    return null;
  }

  final DateTime Function() _now;
  final TimestampChatRenderer renderer;
  @override
  String get id => 'tina/chat-tui';
  final List<ChatBlock> _blocks = [];
  List<ChatBlock> get blocks => List.unmodifiable(_blocks);
  final _calls = <String, ChatBlock>{};
  final _outputs = <String, String>{};
  final _finished = <String>{};
  final _rows = <int>[];
  final _responseBlocks = <ChatBlock>[];
  final _recordedInputs = <String>{};
  static const _speaker = ChatSpeaker(id: 'assistant', label: 'tina');
  AgentLoop? _loop;
  int? _handle;
  StreamSubscription<ToolActivity>? _activity;
  ConsoleContext? _console;
  void Function()? _unbindPrompt, _unbindKey, _unbindModal;
  void Function()? _unbindStatus;
  Timer? _ticker;
  int _frame = 0, _width = -1;
  bool _busy = false;
  int? _selected;
  String _streamed = '', _thinking = '';
  bool _sawThinking = false;
  MarkdownStreamSplitter? _markdown;
  ChatBlock? _preview;
  bool _previewDirty = false;
  final _sources = Expando<String>('markdown-source');
  MarkdownStyle get _style => MarkdownStyle.fromChatTheme(
      _console?.screen.theme.chat ?? const Theme.defaults().chat);

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    _handle = loop.subscribe(entry);
    _activity = loop.toolActivity.listen(observe);
  }

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    context.screen.setStatusLayout(const PriorityStatusLayout());
    _unbindStatus = context.bindStatus(_statusLines);
    for (final block in _blocks) {
      final source = _sources[block];
      if (source != null) block.body = renderMarkdown(_clean(source), _style);
    }
    _unbindPrompt = context.bindPrompt(() => renderConversationPrompt(
        ConversationPrompt(
            conversationId: '',
            model: _loop?.provider.model ?? model,
            busy: _busy,
            focused: true,
            newLines: context.chat.newWhileScrolled),
        context.screen,
        width: context.screen.input.bounds.width,
        animationFrame: _frame));
    _unbindKey = context.bindShortcut((event) {
      final lineRows = _lineScrollRows(event);
      if (lineRows != 0 && context.input.focusManager?.isCycling == true) {
        return false;
      }
      final focused = context.input.focusManager?.focused;
      final panelOwnsNavigation = focused is PanelInputTarget &&
          focused.inputMode == PanelInputMode.commands;
      if (!context.isCompleting && !panelOwnsNavigation) {
        final rows = switch (event) {
          ArrowKey(direction: ArrowDirection.pageUp) =>
            -context.chat.usableHeight,
          ArrowKey(direction: ArrowDirection.pageDown) =>
            context.chat.usableHeight,
          ScrollEvent(:final up) => up ? -3 : 3,
          _ => lineRows,
        };
        if (rows != 0) {
          context.chat.scrollBy(rows);
          context.refreshInput();
          return true;
        }
      }
      if (event is! ControlKey || event.code != ControlCode.ctrlB) return false;
      final indexes = _foldable;
      if (indexes.isEmpty) return true;
      _selected = indexes.last;
      _paintSelection();
      return true;
    });
    _unbindModal = context.addModal(_TranscriptModal(this));
    _ticker = Timer.periodic(const Duration(milliseconds: 160), (_) {
      if (!_busy) return;
      if (_previewDirty && _preview != null) {
        _previewDirty = false;
        _changed(_preview!);
      }
      _frame++;
      context.refreshInput();
    });
    _width = -1;
    repaintConsole();
  }

  @override
  void watch(WatchEvent event) {
    if (_console == null) return;
    switch (event) {
      case SawText(:final text):
        _flushThinking();
        _streamed += text;
        _pushMarkdown(text);
      case SawThinking(:final text, :final startsBlock):
        if (startsBlock) _flushThinking();
        _flushMarkdown();
        _thinking += text;
        _sawThinking = true;
      case SawThinkingEnd(:final complete):
        _flushThinking(complete: complete);
      case SawNotice(:final text):
        writeNotice(text);
      default:
        break;
    }
  }

  void _pushMarkdown(String text) {
    if (text.isEmpty) return;
    final splitter = _markdown ??= MarkdownStreamSplitter();
    for (final source in splitter.push(text)) {
      _completeProse(source);
    }
    if (splitter.hasPending) {
      if (_preview == null) {
        _preview = _prose(splitter.pending);
      } else {
        _sources[_preview!] = splitter.pending;
        _preview!.body = renderMarkdown(_clean(splitter.pending), _style);
        _previewDirty = true;
      }
    }
  }

  ChatBlock? _prose(String text, {DateTime? at}) {
    if (text.trim().isEmpty) return null;
    final block =
        ChatBlock.prose(_speaker, renderMarkdown(_clean(text), _style));
    _sources[block] = text;
    _responseBlocks.add(block);
    _add(block, at: at);
    return block;
  }

  void _completeProse(String text) {
    final preview = _preview;
    _preview = null;
    final changed =
        _previewDirty || preview != null && _sources[preview] != text;
    _previewDirty = false;
    if (preview == null) {
      _prose(text);
    } else {
      _sources[preview] = text;
      preview.body = renderMarkdown(_clean(text), _style);
      if (changed) _changed(preview);
    }
  }

  void _flushMarkdown() {
    final rest = _markdown?.flush();
    _markdown = null;
    if (rest != null) _completeProse(rest);
  }

  void _flushThinking({bool complete = true}) {
    if (_thinking.isEmpty) return;
    _add(ChatBlock.reasoning(_speaker, _clean(_thinking), complete: complete));
    _thinking = '';
  }

  /// Authoritative completion reconciles transient deltas; replay takes the
  /// same path, including imported tool calls and reasoning.
  void entry(SessionEntry entry, LogEvent event) {
    final at =
        DateTime.tryParse(entry.toJson()['at'] as String? ?? '')?.toLocal();
    if (entry is ContextClearedEntry) {
      _blocks.clear();
      _rows.clear();
      _calls.clear();
      _finished.clear();
      _recordedInputs.clear();
      _responseBlocks.clear();
      _thinking = '';
      _streamed = '';
      _preview = null;
      _console?.chat.resetAfterClear();
      _console?.chat.repaint();
    } else if (entry is TurnStartedEntry) {
      _busy = event == LogEvent.appended;
    } else if (entry is InputRecordedEntry) {
      _recordedInputs.add(entry.turnId);
      _add(ChatBlock.user(_clean(entry.text)), at: at);
    } else if (entry is MessageAppendedEntry) {
      final message = entry.message;
      if (message.role == Role.assistant) {
        _flushThinking(
            complete:
                message.reasoning.isEmpty || message.reasoning.last.complete);
        if (!_sawThinking) {
          for (final thought in message.reasoning) {
            _add(
                ChatBlock.reasoning(_speaker, _clean(thought.text),
                    complete: thought.complete),
                at: at);
          }
        }
        final text =
            message.content.whereType<TextBlock>().map((b) => b.text).join();
        if (_streamed.isEmpty) {
          _prose(text, at: at);
        } else if (text.startsWith(_streamed)) {
          _pushMarkdown(text.substring(_streamed.length));
          _flushMarkdown();
        } else {
          // A completion can correct its streamed draft. Replace only that
          // draft, preserving notices and tool rows inserted alongside it.
          _blocks.removeWhere(_responseBlocks.contains);
          _markdown = null;
          _preview = null;
          _previewDirty = false;
          _rebuild();
          _prose(text, at: at);
        }
        _streamed = '';
        _sawThinking = false;
        _responseBlocks.clear();
      } else if (!_recordedInputs.contains(entry.turnId) &&
          !message.isSynthetic) {
        final text =
            message.content.whereType<TextBlock>().map((b) => b.text).join();
        if (text.isNotEmpty) _add(ChatBlock.user(_clean(text)), at: at);
      }
      for (final block in message.content) {
        if (block is ToolUseBlock) {
          // Provider IDs need only identify a call within its exchange.
          if (_finished.remove(block.id)) _calls.remove(block.id);
          _call(ToolUse.fromBlock(block), at: at);
        }
        if (block is ToolResultBlock) {
          _finish(block.toolUseId,
              ToolResult(block.content, isError: block.isError));
        }
      }
    } else if (PlanChangedEntry.matches(entry)) {
      try {
        _plan = PlanChangedEntry.decode(entry as PluginStateEntry);
      } catch (_) {
        _plan = null;
      } // The owner reports incompatible state when enabled.
      _paintUsage();
    } else if (GoalChangedEntry.matches(entry)) {
      try {
        _goal = GoalChangedEntry.decode(entry as PluginStateEntry);
      } catch (_) {
        _goal = null;
      }
      _paintUsage();
    } else if (entry is UsageRecordedEntry) {
      _paintUsage();
    } else if (entry is TurnEndedEntry) {
      _tokens += entry.usage.inputTokens +
          entry.usage.outputTokens +
          entry.usage.cacheCreationInputTokens +
          entry.usage.cacheReadInputTokens;
      _flushThinking(complete: entry.reason == TurnStopReason.complete);
      _flushMarkdown();
      _streamed = '';
      _responseBlocks.clear();
      _sawThinking = false;
      _busy = false;
      _paintUsage();
    }
    _console?.refreshInput();
  }

  void observe(ToolActivity event) {
    final call = event.call;
    if (_finished.contains(call.id)) return;
    final block = _call(call);
    switch (event) {
      case ToolStarted():
        block.status = 'running';
        _changed(block);
      case ToolProgress(:final status):
        block.status = _clean(status);
        _changed(block);
      case ToolOutput(:final text):
        final old = _outputs[call.id] ?? '';
        if (old.length < 65536) {
          _outputs[call.id] = _bound(old + _clean(text));
        }
      case ToolFinished(:final result):
        _finish(call.id, result);
    }
  }

  ChatBlock _call(ToolUse call, {DateTime? at}) =>
      _calls.putIfAbsent(call.id, () {
        _flushThinking();
        _flushMarkdown();
        final block = ChatBlock.toolCall(_speaker,
            subject: _clean(_describe(call)), status: 'waiting');
        _add(block, at: at);
        return block;
      });

  String _describe(ToolUse call) {
    try {
      return _loop?.toolSchema(call.name)?.describe?.call(call.input).summary ??
          _subject(call);
    } catch (_) {
      // A broken description must never hide the actual call or stop a turn.
      return _subject(call);
    }
  }

  void _finish(String id, ToolResult result) {
    if (!_finished.add(id)) return;
    final block = _calls[id];
    if (block == null) return;
    final output = _outputs.remove(id) ?? '';
    final text = _clean(
        result.content.length >= output.length ? result.content : output);
    final timing = _timing(result.elapsed);
    var display = text;
    if (result.isError) {
      try {
        final object = jsonDecode(text);
        if (object is Map && object['message'] is String) {
          display = [
            object['message'],
            if (object['recovery'] is String) 'Recovery: ${object['recovery']}',
          ].join('\n');
        }
      } catch (_) {}
    }
    final why = display
        .split('\n')
        .map((s) => s.trim())
        .firstWhere((s) => s.isNotEmpty, orElse: () => '');
    block.status = [
      result.isError ? 'failed' : 'ok',
      if (timing.isNotEmpty) timing,
      if (result.isError && why.isNotEmpty)
        why.length > 60 ? '${why.substring(0, 59)}…' : why,
    ].join(' · ');
    block.body =
        display.trim().isEmpty ? const [] : plainLines(_bound(display));
    _changed(block);
  }

  @override
  void writeNotice(String text) {
    _flushThinking();
    _flushMarkdown();
    _add(ChatBlock.notice(_speaker, _clean(text)));
  }

  void _add(ChatBlock block, {DateTime? at}) {
    renderer.stamp(block, at ?? _now());
    renderer.follow(block, _blocks.lastOrNull);
    _blocks.add(block);
    final console = _console;
    if (console != null) {
      console.screen.frame(() {
        final chat = console.chat;
        if (_blocks.length > 1) chat.writeln();
        _rows.add(chat.contentRows);
        for (final line in _render(block)) {
          chat.writeStyledLine(line.text, line.bar ?? _style.base);
        }
      });
    }
  }

  List<RegionLine> _render(ChatBlock block) => [
        for (final line in renderer.render(
            block,
            RenderContext(
                width: _console!.chat.bounds.width,
                theme: _console!.screen.theme)))
          if (line.isBlank)
            const RegionLine('')
          else
            _serialize(
                line,
                identical(
                    block, _selected == null ? null : _blocks[_selected!])),
      ];
  RegionLine _serialize(RenderLine line, bool selected) {
    final serialized =
        serializeLine(line, _style, styled: _console!.screen.ansi.useColor);
    return RegionLine(serialized.text,
        bar: selected
            ? _console!.screen.theme.border.selection
            : serialized.bar);
  }

  void _changed(ChatBlock block) {
    if (_console == null) return;
    if (_blocks.isNotEmpty &&
        identical(_blocks.last, block) &&
        _rows.length == _blocks.length) {
      _console!.chat.rewriteFrom(_rows.last, _render(block));
    } else {
      _rebuild();
    }
  }

  void _rebuild() {
    if (_console == null) return;
    final lines = <RegionLine>[];
    renderer.group(_blocks);
    _rows.clear();
    for (final block in _blocks) {
      if (lines.isNotEmpty) lines.add(const RegionLine(''));
      _rows.add(lines.length);
      lines.addAll(_render(block));
    }
    _console!.chat.rewriteFrom(0, lines);
  }

  @override
  void repaintConsole() {
    final console = _console;
    if (console == null) return;
    if (console.isActive)
      console.screen.setStatusLayout(const PriorityStatusLayout());
    if (console.chat.isDetached) {
      _width = -1;
      return;
    }
    if (_width != console.chat.bounds.width) {
      _width = console.chat.bounds.width;
      _rebuild();
    }
    _paintUsage();
    console.refreshInput();
  }

  void _paintUsage() {
    _console?.refreshStatus();
  }

  List<RenderLine> _statusLines() {
    final console = _console;
    if (console == null) return const [];
    final tokens = sessionTokens?.call() ?? _tokens;
    final estimated = sessionEstimatedTokens?.call() ?? 0;
    final theme = console.screen.theme.chat;
    final fraction = tokenCap > 0 ? (tokens + estimated) / tokenCap : 0.0;
    final plan = _plan;
    final items = plan?.items ?? const <PlanEntryItem>[];
    final active =
        items.where((i) => i.state == 'in_progress').firstOrNull?.text;
    final goal = _goal;
    return [
      if (items.isNotEmpty)
        RenderLine(runs: [
          RenderRun('plan: ', theme.dim),
          RenderRun(
              [
                if (active != null) active,
                '${items.where((i) => i.state == 'done').length}/${items.length} done',
                if (plan!.approval == PlanApproval.requested) 'needs approval',
              ].join(' · '),
              null)
        ]),
      if (goal != null && goal.text.isNotEmpty)
        RenderLine(runs: [
          RenderRun('goal: ', theme.dim),
          RenderRun(
              [
                if (goal.verdict == GoalVerdict.achieved) '✓',
                if (goal.verdict == GoalVerdict.uncertain) '?',
                goal.text,
                if (goal.verdict == GoalVerdict.uncertain &&
                    goal.evidence.isNotEmpty)
                  '· ${goal.evidence}',
              ].join(' '),
              null)
        ]),
      if (showSessionId && _sessionId != null)
        RenderLine(runs: [
          RenderRun('session ', theme.dim),
          RenderRun(_sessionId!, null)
        ]),
      RenderLine(align: StatusAlign.right, runs: [
        if (fraction >= 1)
          RenderRun('SPEND LIMIT TRIPPED', theme.red)
        else ...[
          RenderRun('Σ ${formatInteger(tokens)}', theme.dim),
          if (estimated > 0)
            RenderRun(' +~${formatInteger(estimated)} est', theme.yellow),
          if (tokenCap > 0)
            RenderRun(
                ' / ${formatInteger(tokenCap)} · ${(fraction * 100).round()}%',
                fraction >= .9
                    ? theme.red
                    : fraction >= .75
                        ? theme.yellow
                        : theme.dim),
        ],
      ]),
    ];
  }

  List<int> get _foldable => [
        for (var i = 0; i < _blocks.length; i++)
          if (_blocks[i].canFold) i
      ];
  void _paintSelection() {
    _rebuild();
    if (_selected != null && _selected! < _rows.length) {
      _console?.chat.scrollRowIntoView(_rows[_selected!]);
    }
  }

  bool _key(InputEvent event) {
    if (_selected == null || _console?.isReadingKey == true) return false;
    if (event is EscapeKey ||
        event == ControlKey(ControlCode.ctrlB) ||
        event == ControlKey(ControlCode.ctrlC)) {
      _selected = null;
      _rebuild();
      return true;
    }
    final lineRows = _lineScrollRows(event);
    if (lineRows != 0) {
      _console!.chat.scrollBy(lineRows);
      _console!.refreshInput();
      return true;
    }
    final indexes = _foldable;
    var at = indexes.indexOf(_selected!);
    if (event is ArrowKey) {
      if (event.direction == ArrowDirection.up) at--;
      if (event.direction == ArrowDirection.down) at++;
      if (event.direction == ArrowDirection.pageUp ||
          event.direction == ArrowDirection.pageDown) {
        _console!.chat
            .scrollBy(event.direction == ArrowDirection.pageUp ? -5 : 5);
        return true;
      }
      if (indexes.isNotEmpty)
        _selected = indexes[at.clamp(0, indexes.length - 1)];
    } else if (event == ControlKey(ControlCode.enter) ||
        event is CharInput && event.text == ' ') {
      _blocks[_selected!].folded = !_blocks[_selected!].folded;
    }
    _paintSelection();
    return true;
  }

  @override
  void detachConsole() {
    _ticker?.cancel();
    _ticker = null;
    _unbindPrompt?.call();
    _unbindKey?.call();
    _unbindModal?.call();
    _unbindPrompt = null;
    _unbindKey = null;
    _unbindModal = null;
    _selected = null;
    _unbindStatus?.call();
    _unbindStatus = null;
    if (_console?.isActive == true) _console?.screen.setStatusLayout(null);
    _console = null;
    _width = -1;
  }

  @override
  void closeSession() {
    detachConsole();
    unawaited(_activity?.cancel());
    _activity = null;
    if (_handle != null) _loop?.unsubscribe(_handle!);
    _handle = null;
    _loop = null;
  }
}

// Shortcut policy belongs to this UI plugin. Up/Down without Option/Alt
// remains editor history, and Ctrl combinations retain their own meaning.
int _lineScrollRows(InputEvent event) => switch (event) {
      ArrowKey(direction: ArrowDirection.up, hasAlt: true, hasCtrl: false) =>
        -1,
      ArrowKey(direction: ArrowDirection.down, hasAlt: true, hasCtrl: false) =>
        1,
      _ => 0,
    };

final class _TranscriptModal extends ModalSurface {
  _TranscriptModal(this.owner);
  final ChatTuiPlugin owner;
  @override
  bool get isActive =>
      owner._selected != null && owner._console?.isReadingKey != true;
  @override
  bool handleEvent(InputEvent event) => owner._key(event);
}

String _clean(String text) => text
    .replaceAll(RegExp(r'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)'), '')
    .replaceAll(RegExp(r'\x1b\[[0-?]*[ -/]*[@-~]'), '')
    .replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');
String _bound(String text) {
  final capped = text.length > 65536
      ? '${text.substring(0, 65536)}\n… (truncated at 65536 chars)'
      : text;
  final lines = capped.split('\n');
  return lines.length > 200
      ? '${lines.take(200).join('\n')}\n… (${lines.length - 200} more lines)'
      : capped;
}

String _timing(Duration? elapsed) {
  if (elapsed == null || elapsed <= Duration.zero) return '';
  final ms = elapsed.inMilliseconds;
  if (ms < 1000) return '${ms}ms';
  if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
  return '${elapsed.inMinutes}m ${elapsed.inSeconds % 60}s';
}

String _subject(ToolUse call) {
  final name = call.name, input = call.input;
  final detail = switch (name) {
    'bash' => input['command'],
    'exec' =>
      '${input['program'] ?? input['executable'] ?? "(unknown program)"} ${input['args'] ?? []}',
    'read' || 'write' || 'edit' => input['filePath'],
    'glob' || 'grep' => input['pattern'] == null
        ? null
        : '${input['pattern']}${input['path'] == null ? '' : ' in ${input['path']}'}',
    'search' => input['symbol'],
    _ => input.entries
        .where((e) => e.value != null)
        .map((e) => '${e.key}=${e.value}')
        .join(' '),
  };
  return detail == null || detail == '' ? name : '$name · $detail';
}
