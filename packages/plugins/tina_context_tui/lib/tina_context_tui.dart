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
  bool _changes = false;
  int _scroll = 0;
  bool get isOpen => _open;
  List<String> visibleLines = const [];

  @override
  List<Command> get commands => [
        Command(
            name: 'context',
            description: 'inspect accepted working context and edits',
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
    _changes = false;
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
    final body = <String>[];
    var heading = 'Working context';
    try {
      final current = context.workingContext;
      // A transparent text/JSON size heuristic, not provider billing or a
      // tokenizer count. Includes tool payloads; excludes the system prompt.
      final bytes = utf8
          .encode(jsonEncode([for (final m in current.messages) m.toJson()]))
          .length;
      heading =
          'Working context · revision ${current.revision} · ${current.messages.length} messages';
      body.addAll([
        'Accepted conversation · ~${(bytes / 4).ceil()} tokens (JSON bytes / 4; excludes system prompt)',
        'Log through ${current.throughSeq} · file: ${context.fileStatus}',
        if (context.mirrorFile != null) 'Mirror: ${context.mirrorFile!.path}',
        if (context.lastEditReceipt != null)
          'Last file edit: ${context.lastEditReceipt!.message}',
        _changes
            ? 'Latest accepted edit (- removed / + added)'
            : 'Accepted messages (T switches to latest edit)',
      ]);
      if (_changes) {
        final change = context.latestChange;
        if (change == null) {
          body.add('No accepted context replacements yet.');
        } else {
          body.add(
              'Revision ${change.after.revision} · source log through ${change.after.throughSeq}');
          body.addAll(contextMessageDiff(
              change.before.messages, change.after.messages));
        }
      } else {
        var turn = 0;
        for (var i = 0; i < current.messages.length; i++) {
          final m = current.messages[i];
          if (m.role == Role.user &&
              !m.isSynthetic &&
              !m.content.any((b) => b is ToolResultBlock)) {
            body.add('── Turn ${++turn} (working-context order) ──');
          }
          body.addAll(describeContextMessage(m, label: '${i + 1}.'));
        }
        if (current.messages.isEmpty) body.add('No accepted messages yet.');
      }
    } catch (_) {
      body.add(
          'Accepted context is unavailable. No file edits were applied by this viewer.');
    }
    final wrapped = [
      for (final line in body) ...wrapDialogWords(line, area.width),
    ];
    final room = (area.height - 2).clamp(1, 10000);
    _scroll =
        _scroll.clamp(0, (wrapped.length - room).clamp(0, wrapped.length));
    visibleLines = [
      heading,
      ...wrapped.skip(_scroll).take(room),
      '↑↓ scroll · PgUp/PgDn · T messages/changes · Esc close',
    ].take(area.height).map((s) => clipDialogText(s, area.width)).toList();
    final painted = visibleLines.map((line) {
      final color = _changes && line.startsWith('- ')
          ? '31'
          : _changes && line.startsWith('+ ')
              ? '32'
              : null;
      return color == null ? line : console.screen.colorize(color, line);
    }).toList();
    _overlay!.update(bounds: area, lines: painted);
  }

  bool _key(InputEvent event) {
    if (!_open || _console?.isReadingKey == true) return false;
    final page =
        ((_console?.screen.layout.chat.height ?? 8) - 3).clamp(1, 10000);
    switch (event) {
      case EscapeKey():
        _hide();
      case ArrowKey(direction: ArrowDirection.up):
        _scroll--;
      case ArrowKey(direction: ArrowDirection.down):
        _scroll++;
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll -= page;
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll += page;
      case ScrollEvent(:final up):
        _scroll += up ? -3 : 3;
      case CharInput(text: 't' || 'T'):
        _changes = !_changes;
        _scroll = 0;
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
