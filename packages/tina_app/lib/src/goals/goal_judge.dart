import 'dart:async';

import 'package:logging/logging.dart';
import 'package:tina_engine/tina_engine.dart';

import '../session/conversation.dart';
import 'goal_store.dart';

final _log = Logger('tina.goal.judge');

/// How the judge reads a conversation's transcript for evidence. The digest
/// covers the last N messages and keeps assistant/tool text whole (it is the
/// turn's *content* the verdict must rest on) while capping the whole digest
/// so one turn cannot blow the judge call's size.
class GoalJudgeDigest {
  /// Messages of transcript reviewed (oldest first), capped.
  static const maxMessages = 24;

  /// Total characters across the digest, capped.
  static const maxChars = 12000;

  /// One assistant/tool text block, capped per block.
  static const maxBlockChars = 2400;

  /// Renders [history] for the judge. User messages verbatim, assistant text
  /// verbatim (capped), tool activity as compact `tool: name` markers. Every
  /// emitted line — prefixes included — counts against the digest budget.
  static String build(List<Message> history, {int maxMessages = maxMessages}) {
    final recent = history.length <= maxMessages
        ? history
        : history.sublist(history.length - maxMessages);
    final lines = <String>[];
    var budget = maxChars;

    void emit(String prefix, String text) {
      if (budget <= 0 || text.isEmpty) return;
      var line = '$prefix$text';
      final blockCap = maxBlockChars < budget ? maxBlockChars : budget;
      if (line.length > blockCap) {
        line = line.substring(0, blockCap - 1) + '…';
      }
      lines.add(line);
      budget -= line.length + 1; // +1: the join newline
    }

    for (final message in recent) {
      if (budget <= 0) break;
      switch (message.role) {
        case Role.user:
          emit('user: ', _textContent(message));
        case Role.assistant:
          for (final block in message.content) {
            if (budget <= 0) break;
            if (block is ToolUseBlock) {
              emit('tool: ', block.name);
            } else if (block is TextBlock) {
              emit('assistant: ', block.text.trim());
            }
          }
      }
    }
    return lines.isEmpty ? '(no transcript)' : lines.join('\n');
  }

  static String _textContent(Message message) => message.content
      .whereType<TextBlock>()
      .map((b) => b.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n');
}

/// The host-installed judge: resolves the conversation, digests its
/// transcript, runs a one-shot read-only agent call (same seam the region
/// queries use — any configured provider, no panel, no session, no tool
/// approvals), parses the verdict, records it, and announces a status
/// transition in the conversation's transcript. Never throws.
///
/// Returns the recorded verdict, or null when nothing ran (unwired, no goal,
/// conversation missing, judge call failed, or the turn had aborted — a
/// budget trip or provider error is not evidence of progress or failure).
Future<GoalVerdict?> judgeGoal({
  required GoalStore store,
  required Conversation? conversation,
  required Future<RunAgentResult> Function({
    required String systemPrompt,
    required String task,
    required AgentSink sink,
  })
  runCheck,
  bool force = false,
}) async {
  final id = conversation?.id ?? '';
  final goal = store.read(id);
  if (conversation == null || goal.isEmpty) return null;
  if (!force && (conversation.agent.abortedReason != null)) {
    _log.fine('goal judge skipped for $id: last turn aborted');
    return null;
  }
  try {
    final digest = GoalJudgeDigest.build(conversation.history);
    const systemPrompt =
        'You judge whether a conversation has achieved its stated session '
        'goal. You receive the goal and a digest of the recent transcript '
        '(user asks, assistant work, tool activity). You have no tools and '
        'you do not run anything — you only read the digest.\n'
        'Answer with EXACTLY one line in this format:\n'
        'VERDICT: <yes|no|unclear> — <one-sentence evidence from the '
        'transcript>\n'
        'yes = the transcript shows the goal was fully met. no = the '
        'transcript shows it was not yet met (or the work visibly continues). '
        'unclear = the digest does not contain enough evidence either way.';
    final task =
        'GOAL: ${goal.text}\n\n'
        'RECENT TRANSCRIPT:\n$digest';

    final result = await runCheck(
      systemPrompt: systemPrompt,
      task: task,
      sink: const _SilentSink(),
    );
    if (result.isError) {
      _log.warning('goal judge call failed: ${result.text}');
      return null;
    }
    final parsed = _parseVerdict(result.text);
    if (parsed == null) {
      _log.warning('goal judge answer did not parse as a verdict line');
      return null;
    }
    final previous = store.read(id).status?.verdict ?? GoalVerdict.none;
    try {
      store.recordVerdict(id, parsed.verdict, parsed.evidence);
    } on StateError {
      // The goal was cleared while the judge ran — the race the store's
      // contract calls out; nothing to record, nothing to announce.
      return null;
    }
    _announceTransition(conversation, previous, parsed);
    return parsed.verdict;
  } catch (error, stackTrace) {
    _log.warning('goal judge failed for $id', error, stackTrace);
    return null;
  }
}

/// Announce achieved/uncertain transitions in the transcript — a verdict that
/// merely re-states the previous one stays silent (the judge agreeing with
/// itself must not re-notify every turn). Never throws: a presentation
/// failure must not break the turn path.
void _announceTransition(
  Conversation conversation,
  GoalVerdict previous,
  ({GoalVerdict verdict, String evidence}) parsed,
) {
  try {
    if (parsed.verdict == previous) return;
    switch (parsed.verdict) {
      case GoalVerdict.achieved:
        conversation.host.notice(
          'goal achieved — ${parsed.evidence}',
          kind: NoticeKind.info,
        );
      case GoalVerdict.uncertain:
        conversation.host.notice(
          'goal unclear — ${parsed.evidence} (`/goal check` re-judges; '
          '`/goal clear` resets)',
          kind: NoticeKind.warning,
        );
      case GoalVerdict.inProgress:
      case GoalVerdict.none:
        // No announcement for the quiet verdicts: "still working" is the
        // default state and would spam every turn.
        break;
    }
  } catch (_) {
    // Cosmetic; nothing to do.
  }
}

({GoalVerdict verdict, String evidence})? _parseVerdict(String text) {
  for (final rawLine in text.split('\n')) {
    final line = rawLine.trim();
    final match = RegExp(
      r'^VERDICT:\s*(yes|no|unclear)\s*[—–-]?\s*(.*)$',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) continue;
    final word = match.group(1)!.toLowerCase();
    final evidence = match.group(2)?.trim() ?? '';
    return (
      verdict: switch (word) {
        'yes' => GoalVerdict.achieved,
        'no' => GoalVerdict.inProgress,
        _ => GoalVerdict.uncertain,
      },
      evidence: evidence.isEmpty ? '(no evidence given)' : evidence,
    );
  }
  return null;
}

/// The judge runs with its output swallowed: its prose is never the user's
/// transcript (the verdict notice is), and its tool-free turn has no lifecycle
/// worth showing.
class _SilentSink implements AgentSink {
  const _SilentSink();

  @override
  void text(String s) {}

  @override
  void newline() {}

  @override
  void toolStart(ToolStartEvent event) {}

  @override
  void toolOutput(ToolOutputEvent event) {}

  @override
  void toolComplete(ToolCompleteEvent event) {}

  @override
  void reasoning(String text, {bool startsBlock = false}) {}

  @override
  void reasoningEnd({required bool complete}) {}

  @override
  void notice(String message, {NoticeKind kind = NoticeKind.info}) {}

  @override
  void activityStart() {}

  @override
  void activityStop() {}
}
