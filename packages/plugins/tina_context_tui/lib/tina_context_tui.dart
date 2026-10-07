library;

import 'dart:async';
import 'dart:convert';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_context/tina_context.dart';

/// Read-only presentation: never synchronizes the mirror or writes session state.
final class ContextTuiPlugin extends AgentPlugin
    implements ConsoleContribution {
  ContextTuiPlugin({required this.context, required this.terminal});
  final ContextPlugin context;
  final Terminal terminal;
  @override
  String get id => 'tina/context-tui';
  ConsoleContext? _console;
  OverlayRegion? _overlay;
  void Function()? _removeModal, _releaseCursor;
  Timer? _ticker;
  bool _open = false;
  int _view = 0, _selected = 0;
  bool _followSelection = true;
  final _expanded = <String>{};
  List<_ContextRow> _rows = [];
  int _scroll = 0;
  bool get isOpen => _open;
  List<String> visibleLines = const [];

  @override
  List<Command> get commands => [
        Command(
            name: 'context',
            description: 'inspect accepted working context and edits',
            allowWhileRunning: true,
            handler: (_) => toggle()),
      ];

  void toggle() {
    if (_console == null) {
      terminal.writeln('The context viewer requires the interactive console.');
      return;
    }
    if (_open) {
      _hide();
      return;
    }
    _open = true;
    _scroll = 0;
    _view = 0;
    _selected = 0;
    _expanded.clear();
    _followSelection = true;
    _ticker = Timer.periodic(
        const Duration(milliseconds: 500), (_) => repaintConsole());
    repaintConsole();
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
  void attachConsole(ConsoleContext console) {
    detachConsole();
    _console = console;
    _overlay = OverlayRegion(
        console.screen, const Rect(row: 0, col: 0, width: 0, height: 0));
    _removeModal = console.addModal(_ContextModal(this));
  }

  @override
  void repaintConsole() {
    final console = _console;
    if (!_open || console == null) return;
    if (console.isReadingKey || !console.isActive) {
      _overlay?.hide();
      _releaseCursor?.call();
      _releaseCursor = null;
      return;
    }
    final area = dialogArea(console.screen.layout);
    if (area.width < 1 || area.height < 1) return;
    _releaseCursor ??= console.own(console.screen.claimCursor().release);
    final summary = <String>[];
    final body = <String>[];
    try {
      final current = context.workingContext;
      final usage = context.budgetUsage;
      if (usage == null) {
        summary.add('Request size: awaiting first model call');
      } else {
        final limit = usage.budgetTokens - usage.responseReserveTokens;
        final fraction = usage.inputTokens / limit;
        final filled = (fraction * 20).round().clamp(0, 20);
        summary.addAll([
          'Estimated request: ${_tokens(usage.inputTokens)} / ${_tokens(limit)} input budget',
          '[${'█' * filled}${'░' * (20 - filled)}] ${(fraction * 100).toStringAsFixed(0)}% used · last prepared request',
        ]);
      }
      summary.add(_fileState(context));
      if (context.latestEditTokensSaved case final int saved) {
        summary.add(
            'Last edit: ~${_tokens(saved.abs())} ${saved >= 0 ? 'fewer' : 'more'} message tokens');
      }
      if (_view == 2) {
        _rows = [];
        final bytes = utf8
            .encode(jsonEncode(
                [for (final message in current.messages) message.toJson()]))
            .length;
        body.addAll([
          'Accepted working messages: ${current.messages.length}',
          'Message size: ~${_tokens((bytes / 4).ceil())} tokens',
          'Request estimate includes system instructions and tool definitions.',
          'Message estimate excludes those; both use JSON bytes / 4, not provider billing.',
          'Total budget: ${context.budgetTokens} tokens',
          if (usage != null) ...[
            'Response reserve: ${usage.responseReserveTokens} tokens',
            'Remaining input room: ~${usage.remainingInputTokens} tokens',
            if (usage.reminder != null) usage.reminder!,
          ],
          'Revision: ${current.revision}',
          'Session log position: ${current.throughSeq}',
          'File status: ${context.fileStatus}',
          if (context.mirrorFile != null)
            'Context file: ${context.mirrorFile!.path}',
          if (context.lastEditReceipt != null)
            'Last file edit: ${context.lastEditReceipt!.message}',
          'Accepted messages are shown in working-context order, not original turn numbers.',
        ]);
      } else if (_view == 1) {
        final change = context.latestChange;
        if (change == null) {
          _rows = [];
          body.add('No saved context edits yet.');
        } else {
          final before = change.before.messages, after = change.after.messages;
          var start = 0, endBefore = before.length, endAfter = after.length;
          while (start < endBefore &&
              start < endAfter &&
              sameMessages([before[start]], [after[start]])) {
            start++;
          }
          while (endBefore > start &&
              endAfter > start &&
              sameMessages([before[endBefore - 1]], [after[endAfter - 1]])) {
            endBefore--;
            endAfter--;
          }
          body.add(
              'Latest saved edit: ${endBefore - start} removed · ${endAfter - start} added messages');
          body.add('Rewrites appear as removals and additions.');
          _rows = [
            ..._contextRows(before.sublist(start, endBefore), prefix: '- '),
            ..._contextRows(after.sublist(start, endAfter), prefix: '+ '),
          ];
          if (_rows.isEmpty) body.add('Message content unchanged.');
          if (start + before.length - endBefore > 0)
            body.add(
                '${start + before.length - endBefore} unchanged messages hidden');
        }
      } else {
        body.add(
            'Accepted messages · system instructions and tool definitions are separate');
        _rows = _contextRows(current.messages);
        if (_rows.isEmpty) body.add('No accepted messages yet.');
      }
    } catch (_) {
      _rows = [];
      body.add('Accepted context is unavailable.');
    }
    _expanded.retainWhere((key) => _rows.any((row) => row.key == key));
    _selected = _selected.clamp(0, (_rows.length - 1).clamp(0, _rows.length));
    final wrapped = <String>[
      for (final line in body) ...wrapDialogWords(_safe(line), area.width),
    ];
    var selectedLine = 0;
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i], open = _expanded.contains(row.key);
      if (i == _selected) selectedLine = wrapped.length;
      wrapped.add(clipDialogText(
          _safe(
              '${i == _selected ? '›' : ' '} ${row.prefix}${open ? '▾' : '▸'} ${row.title}'),
          area.width));
      if (open) {
        for (final line in row.details) {
          wrapped.addAll(
              wrapDialogWords(_safe('    ${row.prefix}$line'), area.width));
        }
      }
    }
    final header = [
      '${[
        '[Context]  Changes  Details',
        'Context  [Changes]  Details',
        'Context  Changes  [Details]'
      ][_view]} · Working context',
      // Reserve at least one content line and the keyboard footer on small screens.
      ...summary.take((area.height - 3).clamp(0, summary.length)),
    ];
    final room = (area.height - header.length - 1).clamp(1, 10000);
    if (_followSelection && _rows.isNotEmpty) {
      if (selectedLine < _scroll) _scroll = selectedLine;
      if (selectedLine >= _scroll + room) _scroll = selectedLine - room + 1;
    }
    _followSelection = false;
    _scroll =
        _scroll.clamp(0, (wrapped.length - room).clamp(0, wrapped.length));
    visibleLines = [
      ...header,
      ...wrapped.skip(_scroll).take(room),
      _view == 2
          ? '↑↓ scroll · PgUp/PgDn · Tab view · Esc close'
          : '↑↓ select · Space expand · PgUp/PgDn scroll · Tab view · Esc close',
    ]
        .take(area.height)
        .map((line) => clipDialogText(_safe(line), area.width))
        .toList();
    final colors = console.screen.theme.chat;
    final painted = visibleLines.map((line) {
      final plain = line.trimLeft().replaceFirst(RegExp(r'^›\s*'), '');
      final code = plain.startsWith('- ')
          ? colors.red
          : plain.startsWith('+ ')
              ? colors.green
              : line.contains('Working context') ||
                      plain.startsWith('›') ||
                      line.startsWith('›')
                  ? '1;${colors.cyan}'
                  : line.startsWith('Edits awaiting') ||
                          line.startsWith('Context file unavailable')
                      ? colors.yellow
                      : line.startsWith('Edit rejected')
                          ? colors.red
                          : line.startsWith('[') &&
                                  context.budgetUsage != null &&
                                  context.budgetUsage!.remainingInputTokens <=
                                      context.budgetUsage!.budgetTokens ~/ 4
                              ? colors.yellow
                              : line.startsWith('    ') ||
                                      line.contains('last prepared request')
                                  ? colors.dim
                                  : null;
      return code == null ? line : console.screen.colorize(code, line);
    }).toList();
    _overlay!.update(bounds: area, lines: painted);
  }

  bool _key(InputEvent event) {
    if (!_open || _console?.isReadingKey == true) return false;
    final page =
        ((_console?.screen.layout.chat.height ?? 8) - 6).clamp(1, 10000);
    switch (event) {
      case EscapeKey():
        _hide();
      case ArrowKey(direction: ArrowDirection.up):
        if (_rows.isEmpty) {
          _scroll--;
        } else {
          _selected--;
          _followSelection = true;
        }
      case ArrowKey(direction: ArrowDirection.down):
        if (_rows.isEmpty) {
          _scroll++;
        } else {
          _selected++;
          _followSelection = true;
        }
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll -= page;
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll += page;
      case ScrollEvent(:final up):
        _scroll += up ? -3 : 3;
      case CharInput(text: ' ') || ControlKey(code: ControlCode.enter):
        if (_rows.isNotEmpty) {
          final key = _rows[_selected].key;
          if (!_expanded.remove(key)) _expanded.add(key);
          _followSelection = true;
        }
      case ArrowKey(direction: ArrowDirection.right):
        if (_rows.isNotEmpty) _expanded.add(_rows[_selected].key);
      case ArrowKey(direction: ArrowDirection.left):
        if (_rows.isNotEmpty) _expanded.remove(_rows[_selected].key);
      case ControlKey(code: ControlCode.tab) || CharInput(text: 't' || 'T'):
        _view = (_view + 1) % 3;
        _scroll = _selected = 0;
        _followSelection = true;
      default:
        break;
    }
    repaintConsole();
    return true;
  }

  @override
  void detachConsole() {
    _hide();
    _removeModal?.call();
    _removeModal = null;
    _overlay?.dispose();
    _overlay = null;
    _console = null;
  }

  @override
  void closeSession() => detachConsole();
}

String _tokens(int value) =>
    value.abs() < 1000 ? '$value' : '${(value / 1000).toStringAsFixed(1)}k';

String _safe(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x08\x0b-\x1f\x7f-\x9f]'), '');
String _preview(String text) =>
    clipDialogText(_safe(text).replaceAll(RegExp(r'\s+'), ' ').trim(), 100);

String _fileState(ContextPlugin context) {
  if (context.fileStatus.startsWith('Pending'))
    return 'Edits awaiting validation · showing saved context';
  if (context.fileStatus.startsWith('Missing'))
    return 'Context file unavailable · showing saved context';
  if (context.lastEditReceipt?.status == ContextEditStatus.rejected)
    return 'Edit rejected: ${context.lastEditReceipt!.message.replaceFirst('Context edit rejected: ', '')}';
  return context.mirrorFile == null
      ? 'Context saved · file editing unavailable'
      : 'Context saved · no pending edits';
}

final class _ContextRow {
  const _ContextRow(this.key, this.title, this.details, {this.prefix = ''});
  final String key, title, prefix;
  final List<String> details;
}

String _toolTitle(ToolUseBlock tool) {
  final input = tool.input;
  final name =
      tool.name == 'exec' ? '${input['program'] ?? tool.name}' : tool.name;
  return switch (name.split('/').last) {
    'grep' || 'rg' => 'Search file contents',
    'ls' => 'List files',
    'read' || 'cat' => 'Read file',
    'glob' || 'find' => 'Find files',
    'write' => 'Write file',
    'edit' => 'Edit file',
    _ => 'Tool: $name',
  };
}

List<_ContextRow> _contextRows(List<Message> messages, {String prefix = ''}) {
  final results = <String, ToolResultBlock>{};
  final toolIds = <String>{};
  for (final message in messages) {
    for (final block in message.content) {
      if (block is ToolResultBlock) results[block.toolUseId] = block;
      if (block is ToolUseBlock) toolIds.add(block.id);
    }
  }
  final rows = <_ContextRow>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    final role = message.role == Role.user
        ? 'You'
        : message.role == Role.assistant
            ? 'Assistant'
            : message.role.name;
    final fingerprint = jsonEncode(message.toJson()).hashCode;
    for (var j = 0; j < message.content.length; j++) {
      final block = message.content[j];
      final key = '$prefix$i/$j/$fingerprint';
      if (block is ToolResultBlock && toolIds.contains(block.toolUseId))
        continue;
      final (title, details) = switch (block) {
        TextBlock() => (
            '$role${message.isSynthetic ? ' (context note)' : ''}: ${_preview(block.text)}',
            [block.text]
          ),
        ToolUseBlock() => (
            '${_toolTitle(block)} · ${results[block.id] == null ? 'result not retained' : results[block.id]!.isError ? 'failed' : 'completed'}',
            [
              'Tool: ${block.name}',
              'Arguments: ${jsonEncode(block.input)}',
              if (results[block.id] case final ToolResultBlock result)
                'Output: ${result.content}'
            ],
          ),
        ToolResultBlock() => (
            'Tool output${block.isError ? ' · failed' : ''}: ${_preview(block.content)}',
            [block.content]
          ),
        _ => (
            '$role: ${block.runtimeType.toString().replaceAll('Block', '')} retained',
            ['Content retained; preview unavailable.']
          ),
      };
      rows.add(_ContextRow(
          key,
          title,
          [
            for (final line in details)
              ...(line.length > 16000
                      ? '${line.substring(0, 16000)}\n[Preview truncated; full content in context file]'
                      : line)
                  .split('\n')
          ],
          prefix: prefix));
    }
    if (message.reasoning.isNotEmpty) {
      rows.add(_ContextRow(
          '$prefix$i/reasoning',
          '$role: ${message.reasoning.length} reasoning blocks retained',
          ['Reasoning retained; content is not expanded.'],
          prefix: prefix));
    }
  }
  return rows;
}

final class _ContextModal extends ModalSurface {
  _ContextModal(this.owner);
  final ContextTuiPlugin owner;
  @override
  bool get isActive => owner.isOpen && owner._console?.isReadingKey != true;
  @override
  bool handleEvent(InputEvent event) => owner._key(event);
}

/// Bound individual payloads for terminal rendering; the full mirror remains
/// available to file tools. Reasoning and images are indicated, not expanded.
List<String> describeContextMessage(Message message, {String label = ''}) {
  String bounded(String text) => text.length > 16000
      ? '${text.substring(0, 16000)}\n[preview truncated; full content in mirror]'
      : text;
  return [
    '$label ${message.role.name}${message.isSynthetic ? ' · synthetic' : ''}',
    for (final block in message.content)
      switch (block) {
        TextBlock() => bounded(block.text),
        ToolUseBlock() =>
          'Tool ${block.name} (${block.id}): ${bounded(jsonEncode(block.input))}',
        ToolResultBlock() =>
          'Result ${block.toolUseId}${block.isError ? ' · error' : ''}: ${bounded(block.content)}',
        _ => '[${block.runtimeType}]',
      },
    if (message.reasoning.isNotEmpty)
      '[${message.reasoning.length} reasoning blocks retained]',
  ];
}

/// Preserve ordered shared prefix/suffix. Rewrites and reordering are shown
/// as removed/added messages rather than guessed semantic modifications.
List<String> contextMessageDiff(List<Message> before, List<Message> after) {
  var prefix = 0;
  while (prefix < before.length &&
      prefix < after.length &&
      sameMessages([before[prefix]], [after[prefix]])) {
    prefix++;
  }
  var endBefore = before.length, endAfter = after.length;
  while (endBefore > prefix &&
      endAfter > prefix &&
      sameMessages([before[endBefore - 1]], [after[endAfter - 1]])) {
    endBefore--;
    endAfter--;
  }
  return [
    if (prefix > 0) '$prefix leading messages unchanged',
    for (final m in before.sublist(prefix, endBefore))
      ...describeContextMessage(m, label: '-')
          .map((s) => s.startsWith('-') ? s : '- $s'),
    for (final m in after.sublist(prefix, endAfter))
      ...describeContextMessage(m, label: '+')
          .map((s) => s.startsWith('+') ? s : '+ $s'),
    if (before.length - endBefore > 0)
      '${before.length - endBefore} trailing messages unchanged',
    if (prefix == before.length && prefix == after.length)
      'Message content unchanged.',
  ];
}
