/// The approval dialog: a pending [ToolUse] plus a key source to a decision.
///
/// The [KeySource] abstraction is the point: the dialog's decision logic is
/// fully testable from scripted keys with no terminal, and a raw-mode host
/// supplies a `KeySource` over its input parser later. Rendering is pure
/// rows, with the answer selector on the last row (the console's input row).
///
/// The approval channel drives this view; the engine knows no dialog types.
library;

import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_approvals/tina_approvals.dart';
export 'package:tina_approvals/tina_approvals.dart' show ApprovalDecision;

/// One key press, already decoded. A raw-mode host maps its parsed input
/// events to these; tests feed a list literal.
enum ApprovalKey {
  up,
  down,
  pageUp,
  pageDown,
  scrollUp,
  scrollDown,
  confirm,
  cancel,
  details,
  allow,
  deny,
  always,
  toggleReadDirectory,
  toggleWriteDirectory,
  toggleDirectory
}

/// Where keys come from. The dialog [ApprovalDialog.awaitDecision]s until a
/// key resolves or cancels it.
abstract interface class KeySource {
  /// Resolves with the next key, or null if the source closed (host
  /// shutdown, stream end) — treated as a denial, never a silent allow.
  Future<ApprovalKey?> next();
}

/// A scripted [KeySource] for tests and scripted demos.
class ScriptedKeySource implements KeySource {
  final List<ApprovalKey?> _keys;
  int _i = 0;

  ScriptedKeySource(List<ApprovalKey?> keys) : _keys = List.of(keys);

  @override
  Future<ApprovalKey?> next() async => _i < _keys.length ? _keys[_i++] : null;
}

/// What the user decided.

/// The outcome of a dialog run. A cancelled dialog ([ApprovalDecision.deny]
/// via close/cancel) denies the call; the reason says which.
class ApprovalOutcome {
  final ApprovalDecision decision;

  /// `'cancelled'` when no key confirmed the choice (source closed, escape).
  final String? reason;

  const ApprovalOutcome(this.decision, {this.reason});

  bool get isCancellation => reason == 'cancelled';
}

/// The ask context a permission dialog renders: what operation on which
/// resolved path, and why the sandbox is asking. The adapter
/// channel builds it from the channel-independent approval request.
class ApprovalAskContext {
  final String op;
  final String path;
  final String reason;
  final bool confirmation;
  final Map<String, Object?> details;
  const ApprovalAskContext(this.op, this.path, this.reason,
      {this.confirmation = false, this.details = const {}});

  String get title => switch (op) {
        'write' => 'Write file',
        'read' => 'Read file',
        _ => op,
      };
}

/// Selection state and rendering for one pending tool call.
///
/// The dialog does not own an overlay region: it produces rows for the host
/// to paint (same contract as every view in this package) and exposes
/// [awaitDecision] driven by a [KeySource]. Defaults to `allow` highlighted;
/// ↓ moves to `deny`; `allowAlways` is offered last only when the tool's
/// arguments parse (a mistrusted call is a bad thing to blanket-allow).
class ApprovalDialog {
  int _selected = 0;
  bool _details = false;
  int _detailOffset = 0;
  int _maxDetailOffset = 0;
  int _previewOffset = 0;
  int _maxPreviewOffset = 0;
  int _pageSize = 1;
  bool _rememberReads = false;
  bool _rememberWrites = false;
  String? get _readDirectory => ask?.confirmation != true &&
          _hasAlways &&
          ask?.details['read_directory'] is String
      ? ask!.details['read_directory'] as String
      : null;
  String? get _writeDirectory => ask?.confirmation != true &&
          _hasAlways &&
          ask?.op == 'write' &&
          ask?.details['write_directory'] is String
      ? ask!.details['write_directory'] as String
      : null;
  bool get _onDirectoryCheckbox =>
      {'read directory', 'write directory'}.contains(_choices[_selected]);

  /// The pending tool call, when the question came from one. A permission
  /// ask straight from the sandbox has no call — only [ask].
  ToolUse? call;

  /// When the pending question is a permission ask: the operation, the
  /// resolved path and the reason, rendered under the header. Null for a
  /// plain tool-call dialog.
  ApprovalAskContext? ask;

  bool get _hasAlways => call?.argumentsParseError == null;

  ApprovalDialog(this.call, {this.ask});

  List<String> get _choices => ask?.confirmation == true
      ? ['Yes', 'No']
      : [
          'allow',
          'deny',
          if (_hasAlways) 'allow always',
          if (_readDirectory != null) 'read directory',
          if (_writeDirectory != null) 'write directory',
        ];

  ApprovalDecision _withDirectoryScope(ApprovalDecision decision) {
    if (_rememberWrites && _writeDirectory != null) {
      return switch (decision) {
        ApprovalDecision.allow => ApprovalDecision.allowWritesInDirectory,
        ApprovalDecision.allowAlways =>
          ApprovalDecision.allowAlwaysAndWritesInDirectory,
        _ => decision,
      };
    }
    if (!_rememberReads || _readDirectory == null) return decision;
    return switch (decision) {
      ApprovalDecision.allow => ApprovalDecision.allowReadsInDirectory,
      ApprovalDecision.allowAlways =>
        ApprovalDecision.allowAlwaysAndReadsInDirectory,
      _ => decision,
    };
  }

  ApprovalDecision decisionFor(int index) =>
      _withDirectoryScope(switch (_choices[index]) {
        'allow always' => ApprovalDecision.allowAlways,
        'allow' || 'Yes' => ApprovalDecision.allow,
        _ => ApprovalDecision.deny,
      });

  /// Input-anchored rows: context and navigation above the answer selector.
  /// The last row replaces the text input. On narrow screens the selected
  /// answer remains visible; Tab opens scrollable, unabridged details.
  List<RenderLine> rows(
      {int width = 80,
      int height = 1000,
      Theme theme = const Theme.defaults()}) {
    final chat = theme.chat;
    final ask = this.ask;
    if (call == null && ask == null) {
      throw StateError('an ApprovalDialog needs a call or an ask context');
    }
    final tool = ask?.details['tool'];
    final toolMap = tool is Map ? tool : const {};
    final name = call?.name ?? toolMap['name']?.toString() ?? ask?.op ?? '';
    final rawInput = call?.input ?? toolMap['input'];
    final input = rawInput is Map ? rawInput : const {};
    final description = ToolDescription.fromJson(ask?.details['description']);
    final scope = ask?.details['permission_scope'] ??
        ({'bash', 'exec'}.contains(name)
            ? 'command'
            : {'read', 'write', 'edit', 'ls', 'stat', 'glob'}.contains(name) ||
                    {'read', 'write'}.contains(ask?.op)
                ? 'file'
                : null);
    final scopeLabel = ask?.details['permission_scope_label'];
    final alwaysLabel = scopeLabel is String
        ? 'allow $scopeLabel for this session'
        : switch (scope) {
            'file' => 'allow this file for this session',
            'command' => 'allow this command for this session',
            _ => 'allow matching calls for this session',
          };
    final label = ask?.confirmation == true
        ? ask!.title
        : description?.title ??
            switch (name) {
              'bash' => 'Run shell command',
              'exec' => 'Run program',
              'edit' => 'Edit file',
              'write' => 'Write file',
              'read' => 'Read file',
              _ => ask?.title ?? name,
            };
    if (width <= 0 || height <= 0) return [];
    RenderLine row(String text, [String? style]) => RenderLine(runs: [
          RenderRun(clipDialogText(_safe(text), width), style),
        ]);
    final denialReason = ask?.details['auto_approval_denial_reason'];
    final hasDenialReason =
        denialReason is String && denialReason.trim().isNotEmpty;
    final details = <String>[
      if (_readDirectory != null) 'Read directory: $_readDirectory',
      if (_writeDirectory != null) 'Write directory: $_writeDirectory',
      if (ask?.confirmation == true) ...[
        ask!.reason,
        if (description != null) ...[
          if (description.target.isNotEmpty &&
              !description.fields.containsKey('Command'))
            description.target,
          for (final entry in description.fields.entries)
            '${entry.key}: ${entry.value}',
          if (ask.details['cwd'] != null) 'Directory: ${ask.details['cwd']}',
        ],
      ] else ...[
        // Keep the classifier's concrete concern in the first preview row,
        // even when a short terminal has room for only one context row.
        // Tab still shows the full permission request and classifier details.
        if (hasDenialReason && !_details) 'Why: $denialReason',
        if (name == 'bash' ||
            name == 'exec' ||
            description?.fields.containsKey('Command') == true) ...[
          'Directory: ${input['cwd'] ?? ask?.details['cwd'] ?? ask?.details['workspace'] ?? '.'}',
          if (input['env'] is Map && (input['env'] as Map).isNotEmpty)
            'Environment: ${(input['env'] as Map).length} override(s)',
          '',
          if (description?.fields['Command'] != null)
            description!.fields['Command']!
          else if (name == 'bash')
            '${input['command'] ?? ask?.path ?? ''}'
          else
            _argv(input, ask),
        ] else ...[
          if ((input['filePath'] ?? input['path']) != null || ask != null)
            description?.target ??
                '${(input['filePath'] ?? input['path']) ?? ask!.path}',
          if (description != null)
            for (final entry in description.fields.entries)
              '${entry.key}: ${entry.value}',
          if (name == 'write' && input['content'] is String)
            ..._diff(input['content'] as String, '+'),
          if (name == 'edit')
            ..._editDiff(
                (input['oldString'] ?? input['old_string'] ?? '').toString(),
                (input['newString'] ?? input['new_string'] ?? '').toString()),
        ],
        if (call?.argumentsParseError != null) call!.argumentsParseError!,
        if (ask != null && (_details || !hasDenialReason)) 'Why: ${ask.reason}',
        if (_hasAlways &&
            ask?.details['permission_scope_description'] is String)
          ask!.details['permission_scope_description'] as String
        else if (_hasAlways && scope == 'file')
          'Session approval covers only this file. Other files still ask.',
        if (_hasAlways &&
            ask?.details['permission_scope_description'] == null &&
            scope == 'command')
          'Session approval covers this exact command in this directory.',
      ],
      if (_details && ask?.details['mode'] != null)
        'Mode: ${ask!.details['mode']}',
      if (_details && ask?.details['auto_approval_classifier'] is Map) ...[
        ..._classifierDetails(ask!.details['auto_approval_classifier'] as Map),
      ],
      if (_details && input.isNotEmpty) ...[
        'Tool: $name',
        'Arguments',
        _pretty(input),
      ],
    ].map(_safe).toList();
    String? contentStyle(String detail) {
      if (name == 'edit' || name == 'write') {
        if (detail.startsWith('+ ')) return chat.green;
        if (detail.startsWith('- ')) return chat.red;
        if (detail.startsWith('  ') || detail == '⋯') return chat.dim;
      }
      if (detail.startsWith('Directory:') || detail.startsWith('Mode:')) {
        return chat.dim;
      }
      if (detail.startsWith('Why:') || detail.startsWith('Environment:')) {
        return chat.yellow;
      }
      return null;
    }

    if (_details) {
      final lines = [
        for (final detail in details)
          for (final part in detail.split('\n'))
            for (final line in wrapDialogText(part, width))
              row(line, contentStyle(detail))
      ];
      final count = (height - 2).clamp(1, height);
      _pageSize = count;
      _maxDetailOffset = (lines.length - count).clamp(0, lines.length);
      _detailOffset = _detailOffset.clamp(0, _maxDetailOffset);
      return [
        if (height > 1)
          row('Details ${_detailOffset + 1}/${lines.length}',
              theme.dialog.confirm),
        for (final line in lines.skip(_detailOffset).take(count)) line,
        if (height > 2) row('↑↓ scroll · tab back · esc deny', chat.dim),
      ].take(height).toList();
    }
    final choices = ask?.confirmation == true
        ? ['[y] Yes', '[n] No']
        : [
            '[y] allow once',
            '[n] deny',
            if (_hasAlways) '[a] $alwaysLabel',
            if (_readDirectory != null)
              '[${_rememberReads ? 'x' : ' '}] Allow all reads in this directory (r/Space)',
            if (_writeDirectory != null)
              '[${_rememberWrites ? 'x' : ' '}] Allow all writes in this directory (w/Space)',
          ];
    RenderLine choice(int i, {bool compact = false}) => row(
        '${i == _selected ? '❯' : ' '} ${choices[i]}${compact ? ' (${i + 1}/${choices.length})' : ''}',
        i == _selected ? theme.dialog.confirm : null);
    if (height <= 3) return [choice(_selected, compact: true)];
    // Every answer gets its own row. Only very short terminals show the
    // selected answer alone, keeping one row for the request's context.
    final choiceRows = height >= choices.length + 3
        ? [for (var i = 0; i < choices.length; i++) choice(i)]
        : [choice(_selected, compact: true)];
    final preview = [
      for (final detail in details)
        for (final part in detail.split('\n'))
          for (final line in ask?.confirmation == true
              ? wrapDialogWords(part, (width - 2).clamp(1, width))
              : wrapDialogText(part, (width - 2).clamp(1, width)))
            row('│ $line', contentStyle(detail)),
    ];
    final available = (height - choiceRows.length - 2).clamp(0, preview.length);
    final paged = preview.length > available && available >= 2;
    final budget = available - (paged ? 1 : 0);
    _pageSize = budget > 0 ? budget : 1;
    _maxPreviewOffset = (preview.length - budget).clamp(0, preview.length);
    _previewOffset = _previewOffset.clamp(0, _maxPreviewOffset);
    return [
      row('┌ $label · awaiting approval', theme.dialog.confirm),
      ...preview.skip(_previewOffset).take(budget),
      if (paged)
        row('│ Preview ${_previewOffset + 1}–${_previewOffset + budget}/${preview.length} · PgUp/PgDn or wheel',
            chat.dim),
      row(
          width >= 56
              ? '│ ↑↓ choose · Enter confirm · Tab details · Esc deny'
              : '│ ↑↓ · Enter · Tab details · Esc deny',
          chat.dim),
      ...choiceRows,
    ].take(height).toList();
  }

  /// Apply one navigation key; returns true when the selection changed.
  bool handleKey(ApprovalKey key) {
    final toggleFocused = key == ApprovalKey.toggleDirectory ||
        key == ApprovalKey.confirm && _onDirectoryCheckbox && !_details;
    if (_writeDirectory != null &&
        (key == ApprovalKey.toggleWriteDirectory ||
            toggleFocused &&
                (_choices[_selected] == 'write directory' ||
                    _readDirectory == null))) {
      _rememberWrites = !_rememberWrites;
      _rememberReads = false;
      return true;
    }
    if (_readDirectory != null &&
        (key == ApprovalKey.toggleReadDirectory || toggleFocused)) {
      _rememberReads = !_rememberReads;
      _rememberWrites = false;
      return true;
    }
    if ({
      ApprovalKey.pageUp,
      ApprovalKey.pageDown,
      ApprovalKey.scrollUp,
      ApprovalKey.scrollDown
    }.contains(key)) {
      final backwards =
          key == ApprovalKey.pageUp || key == ApprovalKey.scrollUp;
      final amount = key == ApprovalKey.pageUp || key == ApprovalKey.pageDown
          ? _pageSize
          : 3;
      final delta = backwards ? -amount : amount;
      if (_details) {
        _detailOffset = (_detailOffset + delta).clamp(0, _maxDetailOffset);
      } else {
        _previewOffset = (_previewOffset + delta).clamp(0, _maxPreviewOffset);
      }
      return true;
    }
    if (key == ApprovalKey.details ||
        (_details && key == ApprovalKey.confirm)) {
      _details = !_details;
      return true;
    }
    if (_details && (key == ApprovalKey.up || key == ApprovalKey.down)) {
      _detailOffset = (_detailOffset + (key == ApprovalKey.up ? -1 : 1))
          .clamp(0, _maxDetailOffset);
      return true;
    }
    switch (key) {
      case ApprovalKey.pageUp:
      case ApprovalKey.pageDown:
      case ApprovalKey.scrollUp:
      case ApprovalKey.scrollDown:
      case ApprovalKey.allow:
      case ApprovalKey.deny:
      case ApprovalKey.always:
      case ApprovalKey.details:
      case ApprovalKey.toggleReadDirectory:
      case ApprovalKey.toggleWriteDirectory:
      case ApprovalKey.toggleDirectory:
        return false;
      case ApprovalKey.up:
        if (_selected > 0) {
          _selected--;
          return true;
        }
        return false;
      case ApprovalKey.down:
        if (_selected < _choices.length - 1) {
          _selected++;
          return true;
        }
        return false;
      case ApprovalKey.confirm:
      case ApprovalKey.cancel:
        return false;
    }
  }

  /// The decision the current selection maps to.
  ApprovalOutcome get current => ApprovalOutcome(decisionFor(_selected));

  /// Drive the dialog from [keys]: arrows move, Enter confirms, Esc/source
  /// close cancels (a denial with reason `'cancelled'`). Resolves when a
  /// decision is reached; never throws on an empty source. [onKey] runs
  /// after each selection change, so a host can repaint the question.
  Future<ApprovalOutcome> awaitDecision(KeySource keys,
      {void Function()? onKey}) async {
    while (true) {
      final key = await keys.next();
      switch (key) {
        case ApprovalKey.allow:
          return ApprovalOutcome(_withDirectoryScope(ApprovalDecision.allow));
        case ApprovalKey.deny:
          return const ApprovalOutcome(ApprovalDecision.deny);
        case ApprovalKey.always:
          if (ask?.confirmation != true && _hasAlways) {
            return ApprovalOutcome(
                _withDirectoryScope(ApprovalDecision.allowAlways));
          }
        case ApprovalKey.pageUp:
        case ApprovalKey.pageDown:
        case ApprovalKey.scrollUp:
        case ApprovalKey.scrollDown:
        case ApprovalKey.up:
        case ApprovalKey.down:
        case ApprovalKey.details:
        case ApprovalKey.toggleReadDirectory:
        case ApprovalKey.toggleWriteDirectory:
        case ApprovalKey.toggleDirectory:
          handleKey(key!);
          onKey?.call();
        case ApprovalKey.confirm:
          if (_details || _onDirectoryCheckbox) {
            handleKey(key!);
            onKey?.call();
          } else {
            return current;
          }
        case ApprovalKey.cancel:
        case null:
          return const ApprovalOutcome(
            ApprovalDecision.deny,
            reason: 'cancelled',
          );
      }
    }
  }
}

String _inlineArgs(Map<String, dynamic> input) {
  if (input.isEmpty) return '';
  return input.entries
      .map((e) => '${e.key}: ${jsonEncode(e.value)}')
      .join(', ');
}

String _pretty(Object? value) {
  Object? redact(Object? v) => switch (v) {
        Map v => {
            for (final entry in v.entries)
              '${entry.key}': RegExp(
                          r'(password|secret|token|api[_-]?key|authorization)',
                          caseSensitive: false)
                      .hasMatch('${entry.key}')
                  ? '[redacted]'
                  : redact(entry.value)
          },
        List v => v.map(redact).toList(),
        _ => v,
      };
  return const JsonEncoder.withIndent('  ').convert(redact(value));
}

// Render controls literally; tool arguments must never execute terminal escapes.
String _safe(String value) => value.replaceAllMapped(
    RegExp(r'[\x00-\x09\x0b-\x1f\x7f]'),
    (m) => '\\x${m[0]!.codeUnitAt(0).toRadixString(16).padLeft(2, '0')}');

Iterable<String> _diff(String text, String prefix) =>
    text.split('\n').map((line) => '$prefix $line');

Iterable<String> _classifierDetails(Map details) sync* {
  if (details['model'] != null)
    yield 'Approval classifier: ${details['model']}';
  if (details['attempts'] != null)
    yield 'Classifier attempts: ${details['attempts']}';
  if (details['answer_characters'] != null)
    yield 'Classifier answer: ${details['answer_characters'] is int ? formatInteger(details['answer_characters'] as int) : details['answer_characters']} characters';
  if (details['reasoning_characters'] != null)
    yield 'Classifier reasoning: ${details['reasoning_characters'] is int ? formatInteger(details['reasoning_characters'] as int) : details['reasoning_characters']} characters';
  if (details['stop_reason'] != null)
    yield 'Classifier completion: ${details['stop_reason']}';
}

String _argv(Map input, ApprovalAskContext? ask) {
  final executable =
      input['program'] ?? input['executable'] ?? ask?.details['executable'];
  final args = input['args'] ?? input['arguments'] ?? ask?.details['arguments'];
  if (executable == null)
    return ask?.path ?? _inlineArgs(Map<String, dynamic>.from(input));
  String quote(Object? v) {
    final text = _safe(v.toString());
    return RegExp(r'^[a-zA-Z0-9_./:=+-]+$').hasMatch(text)
        ? text
        : "'${text.replaceAll("'", "'\\''")}'";
  }

  return [executable, if (args is List) ...args].map(quote).join(' ');
}

// Keep shared lines as context rather than presenting them as removed/added.
Iterable<String> _editDiff(String before, String after) sync* {
  final old = before.split('\n');
  final updated = after.split('\n');
  var prefix = 0;
  while (prefix < old.length &&
      prefix < updated.length &&
      old[prefix] == updated[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < old.length - prefix &&
      suffix < updated.length - prefix &&
      old[old.length - suffix - 1] == updated[updated.length - suffix - 1]) {
    suffix++;
  }
  if (prefix > 3) yield '⋯';
  for (final line in old.take(prefix).skip(prefix > 3 ? prefix - 3 : 0)) {
    yield '  $line';
  }
  for (final line in old.skip(prefix).take(old.length - prefix - suffix)) {
    yield '- $line';
  }
  for (final line
      in updated.skip(prefix).take(updated.length - prefix - suffix)) {
    yield '+ $line';
  }
  for (final line in updated.skip(updated.length - suffix).take(3)) {
    yield '  $line';
  }
  if (suffix > 3) yield '⋯';
}
