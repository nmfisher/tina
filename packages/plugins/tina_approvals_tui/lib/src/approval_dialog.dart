/// The approval dialog: a pending [ToolUse] plus a key source to a decision.
///
/// The [KeySource] abstraction is the point: the dialog's decision logic is
/// fully testable from scripted keys with no terminal, and a raw-mode host
/// supplies a `KeySource` over its input parser later. Rendering is pure
/// rows, mirroring `tina_console`'s dialog vocabulary (`theme.dialog.confirm`
/// highlight, the `┌─┐│└─┘` box).
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
enum ApprovalKey { up, down, confirm, cancel, details }

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
  const ApprovalAskContext(this.op, this.path, this.reason);

  String get title => switch (op) {
        'write' => 'Write outside the project',
        'read' => 'Read outside the project',
        _ => op,
      };
}

/// Selection state and rendering for one pending tool call.
///
/// The dialog does not own an overlay region: it produces rows for the host
/// to paint (same contract as every view in this package) and exposes
/// [awaitDecision] driven by a [KeySource]. Defaults to `allow` highlighted;
/// ↓ moves to `deny`; `allowAlways` is offered first only when the tool's
/// arguments parse (a mistrusted call is a bad thing to blanket-allow).
class ApprovalDialog {
  int _selected = 0;
  bool _details = false;
  int _detailOffset = 0;
  int _maxDetailOffset = 0;

  /// The pending tool call, when the question came from one. A permission
  /// ask straight from the sandbox has no call — only [ask].
  ToolUse? call;

  /// When the pending question is a permission ask: the operation, the
  /// resolved path and the reason, rendered under the header. Null for a
  /// plain tool-call dialog.
  ApprovalAskContext? ask;

  bool get _hasAlways => call?.argumentsParseError == null;

  ApprovalDialog(this.call, {this.ask});

  List<String> get _choices => [
        if (_hasAlways) 'allow always',
        'allow',
        'deny',
      ];

  ApprovalDecision decisionFor(int index) => switch (_choices[index]) {
        'allow always' => ApprovalDecision.allowAlways,
        'allow' => ApprovalDecision.allow,
        _ => ApprovalDecision.deny,
      };

  /// Rows for the current selection: the call (or the ask's operation,
  /// resolved path and reason), and the choice list with the highlighted
  /// option marked `[ ]`/`[x]`.
  List<RenderLine> rows(
      {int width = 80,
      int height = 1000,
      Theme theme = const Theme.defaults()}) {
    final chat = theme.chat;
    final ask = this.ask;
    if (call == null && ask == null) {
      throw StateError('an ApprovalDialog needs a call or an ask context');
    }
    final label = ask?.title ??
        switch (call!.name) {
          'bash' || 'exec' => 'Run command',
          'edit' => 'Edit file',
          'write' => 'Write file',
          _ => call!.name,
        };
    final args = ask == null
        ? (call!.argumentsParseError ?? _inlineArgs(call!.input))
        : null;
    if (width <= 0 || height <= 0) return [];
    RenderLine row(String text, [String? style]) => RenderLine(runs: [
          RenderRun(clipDialogText(text, width), style),
        ]);
    final details = [
      if (args != null && args.isNotEmpty) args,
      if (ask != null) 'path: ${ask.path}',
      if (ask != null) 'why: ${ask.reason}',
    ];
    if (_details) {
      final lines = [
        for (final detail in details) ...wrapDialogText(detail, width)
      ];
      final count = (height - 2).clamp(1, height);
      _maxDetailOffset = (lines.length - count).clamp(0, lines.length);
      _detailOffset = _detailOffset.clamp(0, _maxDetailOffset);
      return [
        if (height > 1)
          row('Details ${_detailOffset + 1}/${lines.length}',
              theme.dialog.confirm),
        for (final line in lines.skip(_detailOffset).take(count))
          row(line, chat.dim),
        if (height > 2) row('↑↓ scroll · tab back · esc deny', chat.dim),
      ].take(height).toList();
    }
    final choices = [
      for (var i = 0; i < _choices.length; i++)
        row('│ ${i == _selected ? '[x]' : '[ ]'} ${_choices[i]}',
            i == _selected ? theme.dialog.confirm : null)
    ];
    if (height == 1) return [choices[_selected]];
    final room = (height - 2).clamp(1, height);
    final choiceCount = choices.length.clamp(1, room);
    final start =
        (_selected - choiceCount + 1).clamp(0, choices.length - choiceCount);
    final detailCount = (room - choiceCount).clamp(0, details.length);
    return [
      row('┌─ $label', theme.dialog.confirm),
      for (final detail in details.take(detailCount))
        row('│ $detail', chat.dim),
      ...choices.skip(start).take(choiceCount),
      if (height > 2)
        row(
            width >= 56
                ? '└─ ↑↓ move · enter confirm · tab details · esc deny'
                : '↑↓ · enter · tab details · esc deny',
            chat.dim),
    ];
  }

  /// Apply one navigation key; returns true when the selection changed.
  bool handleKey(ApprovalKey key) {
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
      case ApprovalKey.details:
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
        case ApprovalKey.up:
        case ApprovalKey.down:
        case ApprovalKey.details:
          handleKey(key!);
          onKey?.call();
        case ApprovalKey.confirm:
          if (_details) {
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
