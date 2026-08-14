import 'package:attractor/attractor.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../tui/attention_queue.dart';
import '../tui/spawn_overlay.dart';

/// The tina implementation of attractor's [Interviewer]. At a `hexagon`/human
/// gate, it presents the question using the TUI's existing overlay/key-capture
/// primitives — the same exclusive-capture pattern the spend-pause dialog uses
/// to block the REPL while a background turn is mid-flight. When [screen] or
/// [editor] is null (headless mode), it auto-approves.
///
/// Interactive asks go through the shared [AttentionQueue] so two concurrent
/// runs' gates can't race on `editor.readKey()`; while another modal is open,
/// the queued ask posts a "waiting" notice to [sink] (when given) so the run
/// panel shows why it is stalled.
class TinaInterviewer implements Interviewer {
  final Screen? screen;
  final LineEditor? editor;
  final AttentionQueue? attentionQueue;

  /// Where "waiting for your input" notices go while queued behind another
  /// modal — normally the run's own sink (its run panel).
  final AgentSink? sink;

  TinaInterviewer({
    this.screen,
    this.editor,
    this.attentionQueue,
    this.sink,
  });

  bool get _interactive => screen != null && editor != null;

  @override
  Future<Answer> ask(Question question) async {
    if (!_interactive) return _autoApprove(question);
    final queue = attentionQueue;
    if (queue == null) return _ask(question);
    return queue.run(() => _ask(question), onQueued: _notifyQueued);
  }

  Future<Answer> _ask(Question question) async {
    switch (question.type) {
      case QuestionType.multipleChoice:
        return _multipleChoice(question);
      case QuestionType.yesNo:
      case QuestionType.confirmation:
        return _yesNo(question);
      case QuestionType.freeform:
        return _freeform(question);
    }
  }

  void _notifyQueued() {
    sink?.notice('waiting for your input — another dialog is open…',
        kind: NoticeKind.info);
  }

  Future<Answer> _multipleChoice(Question q) async {
    final options = q.options ?? const <Option>[];
    if (options.isEmpty) return const Answer.cancelled();
    final entries = options
        .map((o) => (display: '[${o.key}] ${o.label}', value: o))
        .toList();
    final selected = await runListOverlay<Option>(
      screen: screen!,
      editor: editor!,
      entries: entries,
      title: q.text,
      footer: '↑↓ move · enter select · esc cancel',
      accent: 'cyan',
    );
    if (selected == null) return const Answer.cancelled();
    return Answer(value: selected.key, selectedOption: selected);
  }

  Future<Answer> _yesNo(Question q) async {
    final ev = await editor!.readKey();
    final yes = ev is CharInput && (ev.text == 'y' || ev.text == 'Y');
    return Answer(
        kind: yes ? AnswerValue.yes : AnswerValue.no,
        value: yes ? 'yes' : 'no');
  }

  Future<Answer> _freeform(Question q) async {
    final text = await editor!.readLine('? ');
    if (text == null) return const Answer.cancelled();
    return Answer(text: text, value: text);
  }

  /// Headless / non-interactive fallback: always confirm, pick the first
  /// option, or empty freeform — so a `--workflow` run isn't blocked.
  Answer _autoApprove(Question q) {
    switch (q.type) {
      case QuestionType.yesNo:
      case QuestionType.confirmation:
        return const Answer(kind: AnswerValue.yes, value: 'yes');
      case QuestionType.multipleChoice:
        final first = (q.options ?? const <Option>[]);
        return first.isEmpty
            ? const Answer.cancelled()
            : Answer(value: first.first.key, selectedOption: first.first);
      case QuestionType.freeform:
        return const Answer(text: '', value: '');
    }
  }

  @override
  Future<void> inform(String message, {String? stage}) async {}
}
