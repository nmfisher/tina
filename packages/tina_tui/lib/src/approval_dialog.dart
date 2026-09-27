/// The approval dialog: a pending [ToolUse] plus a key source to a decision.
///
/// The [KeySource] abstraction is the point: the dialog's decision logic is
/// fully testable from scripted keys with no terminal, and a raw-mode host
/// supplies a `KeySource` over its input parser later. Rendering is pure
/// rows, mirroring `tina_console`'s dialog vocabulary (`theme.dialog.confirm`
/// highlight, the `┌─┐│└─┘` box).
///
/// Wiring, per the README: the loop side will await this dialog from a
/// `beforeTool` guard — no new engine hook.
library;

import 'dart:convert';

import 'package:tina_console/tina_console.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart' show FileOp;

/// One key press, already decoded. A raw-mode host maps its parsed input
/// events to these; tests feed a list literal.
enum ApprovalKey { up, down, confirm, cancel }

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
  Future<ApprovalKey?> next() async =>
      _i < _keys.length ? _keys[_i++] : null;
}

/// What the user decided.
enum ApprovalDecision { allow, allowAlways, deny }

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
/// (`approval_approver.dart`) builds it from the sandbox's vocabulary.
class ApprovalAskContext {
  final FileOp op;
  final String path;
  final String reason;
  const ApprovalAskContext(this.op, this.path, this.reason);

  String get title => switch (op) {
        FileOp.write => 'Write outside the project',
        FileOp.read => 'Read outside the project',
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
  List<RenderLine> rows({int width = 80, Theme theme = const Theme.defaults()}) {
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
    return [
      RenderLine(runs: [RenderRun('┌─ $label', theme.dialog.confirm)]),
      if (args != null && args.isNotEmpty)
        RenderLine(runs: [
          RenderRun('│ ${_clip(args, width - 3)}', chat.dim),
        ]),
      if (ask != null) ...[
        RenderLine(runs: [
          RenderRun('│ path: ${_clip(ask.path, width - 3)}', chat.dim),
        ]),
        RenderLine(runs: [
          RenderRun('│ why: ${_clip(ask.reason, width - 3)}', chat.dim),
        ]),
      ],
      for (var i = 0; i < _choices.length; i++)
        RenderLine(runs: [
          RenderRun(
            '│ ${i == _selected ? '[x]' : '[ ]'} ${_choices[i]}',
            i == _selected ? theme.dialog.confirm : null,
          ),
        ]),
      RenderLine(runs: [RenderRun('└─ ↑↓ move · enter confirm · esc deny', chat.dim)]),
    ];
  }

  /// Apply one navigation key; returns true when the selection changed.
  bool handleKey(ApprovalKey key) {
    switch (key) {
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
  ApprovalOutcome get current =>
      ApprovalOutcome(decisionFor(_selected));

  /// Drive the dialog from [keys]: arrows move, Enter confirms, Esc/source
  /// close cancels (a denial with reason `'cancelled'`). Resolves when a
  /// decision is reached; never throws on an empty source.
  Future<ApprovalOutcome> awaitDecision(KeySource keys) async {
    while (true) {
      final key = await keys.next();
      switch (key) {
        case ApprovalKey.up:
        case ApprovalKey.down:
          handleKey(key!);
        case ApprovalKey.confirm:
          return current;
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

String _clip(String text, int width) {
  if (width <= 0) return '';
  if (visibleWidth(text) <= width) return text;
  var w = 0;
  var i = 0;
  while (i < text.length) {
    final size = runeSizeAt(text, i);
    final cw = runeWidth(codePointAt(text, i));
    if (w + cw > width - 1) break;
    w += cw;
    i += size;
  }
  return '${text.substring(0, i)}…';
}
