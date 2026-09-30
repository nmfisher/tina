/// The session's goal: the user's stated objective for this conversation,
/// injected into every request as a prompt section and — when a judge is
/// wired — assessed after each completed turn by one extra provider
/// request whose VERDICT line is recorded in the log.
///
/// Ported from the old app's goal plugin, with the truth moved onto this
/// engine's one log: the old engine kept goals in a side map mirrored
/// into the session manifest and judged through a separate scheduler
/// agent; here every change appends a [GoalChangedEntry] through
/// `AgentLoop.recordState` (the entry is the state, a resume replays it),
/// and the judge is one streaming request on the session's own provider
/// — the same shape compaction's summary request takes. The judge fires
/// only after a **complete** turn: a cancelled or errored turn is not
/// evidence of progress or failure (the old engine's turn-quality guard).
///
/// The surfaces, split the brief's way:
/// - **model-read** — the `<current-goal>` section in `onPrompt`;
/// - **user-typed** — the `/goal` command, told through the [Terminal];
/// - **the judge** — the plugin's own post-turn check, read-only, no
///   tools, never entering the transcript.
library;

import 'state.dart';

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';

/// The goal text cap, so one runaway objective cannot dominate every
/// request's injected context.
const goalMaxTextLength = 500;

/// The evidence cap a recorded verdict is trimmed to.
const goalMaxEvidenceLength = 240;

/// How the judge reads the derived transcript for evidence. The digest
/// covers the last N messages and keeps assistant/tool text whole (it is
/// the turn's *content* the verdict must rest on) while capping the whole
/// digest so one turn cannot blow the judge call's size. Ported from the
/// old judge's digest, against the derive's message list instead of a
/// conversation object.
class GoalJudgeDigest {
  /// Messages of transcript reviewed (oldest first), capped.
  static const maxMessages = 24;

  /// Total characters across the digest, capped.
  static const maxChars = 12000;

  /// One assistant/tool text block, capped per block.
  static const maxBlockChars = 2400;

  /// Renders [messages] for the judge. User messages verbatim, assistant
  /// text verbatim (capped), tool activity as compact `tool: name`
  /// markers. Every emitted line — prefixes included — counts against
  /// the digest budget.
  static String build(List<Message> messages, {int maxMessages = maxMessages}) {
    final recent = messages.length <= maxMessages
        ? messages
        : messages.sublist(messages.length - maxMessages);
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
          if (message.isSynthetic) break; // a compaction summary, not a turn
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

/// The judge's fixed system prompt: one VERDICT line over a goal plus a
/// transcript digest, no tools. Ported verbatim from the old judge — both
/// generations of judgment rest on the same contract.
const String goalJudgeSystemPrompt =
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

/// The judge task for [goalText] against a prebuilt [digest].
String goalJudgeTask(String goalText, String digest) =>
    'GOAL: $goalText\n\nRECENT TRANSCRIPT:\n$digest';

/// Parses the judge's answer: the first `VERDICT: <yes|no|unclear>` line,
/// with the evidence after the dash. Null when the answer is not a
/// verdict line — an unparsable answer is nothing judged, never a guess.
({GoalVerdict verdict, String evidence})? parseGoalVerdict(String text) {
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

/// One judge assessment: streams one request on [provider], reads the
/// answer the way the loop reads a turn (transcript text comes from
/// `MessageComplete`, deltas are the live form), parses the verdict.
/// Null when nothing could be judged — a failed call or an unparsable
/// answer. Never throws.
Future<({GoalVerdict verdict, String evidence})?> judgeGoal({
  required LlmProvider provider,
  required String goalText,
  required String digest,
}) async {
  final buf = StringBuffer();
  try {
    await for (final event in provider.send(
      system: goalJudgeSystemPrompt,
      messages: [
        Message(
          role: Role.user,
          content: [TextBlock(goalJudgeTask(goalText, digest))],
        ),
      ],
      tools: const [],
    )) {
      switch (event) {
        case TextDelta(:final text):
          buf.write(text);
        case MessageComplete(content: final blocks):
          for (final b in blocks) {
            if (b is TextBlock) buf.write(b.text);
          }
        case StreamError():
          return null;
        default:
          break;
      }
    }
  } catch (_) {
    return null;
  }
  return parseGoalVerdict(buf.toString());
}

/// Renders the model-facing section. Returns '' for no goal — a section
/// that says "there is no goal" is noise, and the join drops empties.
String goalSection(SessionGoal? goal) {
  if (goal == null) return '';
  final buffer = StringBuffer(
    '<current-goal>\n'
    'This conversation has a session goal, set by the user via /goal.\n'
    'Keep it in mind for every request in this conversation: steer each '
    'turn toward it, and say so explicitly when you believe it is fully '
    'met.\n',
  );
  buffer.writeln('Goal: ${goal.text}');
  if (goal.hasVerdict) {
    buffer.writeln(switch (goal.verdict) {
      GoalVerdict.achieved =>
        'The goal judge last marked this goal ACHIEVED (${goal.evidence}). '
            'If the user keeps working, treat further turns as '
            'verification or a new related objective, not a re-open.',
      GoalVerdict.uncertain =>
        'The goal judge last could not tell whether this goal is met '
            '(${goal.evidence}). Address the ambiguity directly.',
      GoalVerdict.inProgress =>
        'The goal judge last assessed this goal as still in progress '
            '(${goal.evidence}).',
      GoalVerdict.none => '',
    });
  }
  buffer.writeln('</current-goal>');
  return buffer.toString();
}

/// The plugin: owns the section, the command and the judge; mounts
/// itself onto the loop; keeps [goal] current from the log.
final class GoalsPlugin extends AgentPlugin {
  GoalsPlugin({
    this.id = 'tina/goals',
    this.order = 25,
    this.judge = judgeGoal,
    this.terminal,
  });

  @override
  final String id;

  /// After the tools and plans plugins.
  @override
  final int order;

  /// The judge call itself, injectable for tests — the default streams
  /// the real request on the session's provider.
  final Future<({GoalVerdict verdict, String evidence})?> Function({
    required LlmProvider provider,
    required String goalText,
    required String digest,
  }) judge;

  final Terminal? terminal;

  /// The goal now, as the log's latest [GoalChangedEntry] carries it.
  /// Null when no goal is set.
  SessionGoal? goal;

  AgentLoop? _loop;
  void Function(PluginStateEntry)? _writer;
  int? _subscription;
  bool _closed = false;
  StreamSubscription<void>? _judgeSub;

  @override
  List<ToolSchema> get tools => const [];

  @override
  void onPrompt(TurnContext c) {
    final section = goalSection(goal);
    if (section.isNotEmpty) c.promptSections.add(section);
  }

  /// Mount: replay the log into [goal], register nothing (the judge is
  /// not a tool), and arm the post-turn judge. The judge work runs off
  /// the turn's own completion, so it subscribes to the log rather than
  /// hooking `onTurnEnd`: a judge request must never delay the turn's
  /// outcome reaching the user.
  @override
  void mountOn(AgentLoop loop) {
    if (_loop != null) return;
    _loop = loop;
    _writer = loop.stateWriter(id);
    for (final e in loop.log
        .whereType<PluginStateEntry>()
        .where(GoalChangedEntry.matches)
        .map(GoalChangedEntry.decode)) {
      goal = e.text.isEmpty
          ? null
          : SessionGoal(text: e.text, verdict: e.verdict, evidence: e.evidence);
    }
    _subscription = loop.subscribe((entry, event) {
      if (GoalChangedEntry.matches(entry)) {
        final decoded = GoalChangedEntry.decode(entry as PluginStateEntry);
        goal = decoded.text.isEmpty
            ? null
            : SessionGoal(
                text: decoded.text,
                verdict: decoded.verdict,
                evidence: decoded.evidence);
      }
      if (event == LogEvent.appended && entry is TurnEndedEntry) {
        // The turn-quality guard: only a completed turn is evidence. The
        // judge runs off-completion; its own failures are silent.
        if (entry.reason == TurnStopReason.complete && goal != null) {
          _judgeSub = _runJudge();
        }
      }
    });
  }

  /// One judge check against the log as it stands. Records the verdict
  /// only when it differs — a judge agreeing with itself must not spam
  /// the log with entries.
  StreamSubscription<void> _runJudge() {
    final loop = _loop!;
    final current = goal!;
    late final StreamSubscription<void> sub;
    sub = Stream<void>.fromFuture(_judgeOnce(loop, current)).listen((_) {},
        onError: (_) {
      // The judge never breaks the session: a failed check is a silent
      // skip, and the next completed turn tries again.
      sub.cancel();
    });
    return sub;
  }

  Future<void> _judgeOnce(AgentLoop loop, SessionGoal current) async {
    final view = loop.derive();
    final parsed = await judge(
      provider: loop.provider,
      goalText: current.text,
      digest: GoalJudgeDigest.build(view.messages),
    );
    if (_closed || parsed == null) return;
    if (goal == null || goal!.text != current.text)
      return; // replaced meanwhile
    if (goal!.verdict == parsed.verdict && goal!.evidence == parsed.evidence) {
      return; // no change, no entry
    }
    _record(loop, current.text, parsed.verdict, parsed.evidence);
  }

  void _record(
      AgentLoop loop, String text, GoalVerdict verdict, String evidence) {
    var trimmed = evidence.trim();
    if (trimmed.length > goalMaxEvidenceLength) {
      trimmed = trimmed.substring(0, goalMaxEvidenceLength);
    }
    _writer!(GoalChangedEntry(
      text: text,
      verdict: verdict,
      evidence: trimmed,
    ));
  }

  /// The user's surface: `/goal` — show, check, clear, or set by free
  /// text. `check` runs the judge once, on demand.
  @override
  List<Command> get commands => terminal == null
      ? const []
      : [
          Command(
            name: 'goal',
            complete: (prefix) => ['status', 'check', 'clear']
                .where((word) => word.startsWith(prefix))
                .toList(),
            description:
                'set, show or clear the session goal (judged after each '
                'completed turn)',
            handler: _goalCommand,
          )
        ];

  Future<void> _goalCommand(String argument) async {
    final loop = _loop;
    final terminal = this.terminal!;
    final args = argument.trim();
    if (args.isEmpty ||
        RegExp(r'^status$', caseSensitive: false).hasMatch(args)) {
      _showGoal(terminal);
      return;
    }
    if (RegExp(r'^clear$', caseSensitive: false).hasMatch(args)) {
      if (loop == null) return;
      final had = goal != null;
      _writer!(const GoalChangedEntry(text: ''));
      terminal.writeln(had ? 'Goal cleared.' : 'No goal set.');
      return;
    }
    if (RegExp(r'^check$', caseSensitive: false).hasMatch(args)) {
      if (loop == null || goal == null) {
        terminal.writeln('No goal to check. Set one with `/goal <text>`.');
        return;
      }
      terminal.writeln('Judging goal…');
      await _judgeOnce(loop, goal!);
      _showGoal(terminal);
      return;
    }
    // Free text is the new goal. Validation matches the entry: non-empty,
    // capped.
    if (loop == null) return;
    final trimmed = args;
    if (trimmed.length > goalMaxTextLength) {
      terminal.writeln('goal text exceeds $goalMaxTextLength chars');
      return;
    }
    _writer!(GoalChangedEntry(text: trimmed));
    _showGoal(terminal);
  }

  void _showGoal(Terminal terminal) {
    final current = goal;
    if (current == null) {
      terminal.writeln(
          'No goal. `/goal <text>` sets one; it is injected into every '
          'request and judged after each completed turn. `/goal clear` '
          'removes it.');
      return;
    }
    final buffer = StringBuffer('Goal: ${current.text}\n');
    if (current.hasVerdict) {
      final mark = switch (current.verdict) {
        GoalVerdict.achieved => 'ACHIEVED',
        GoalVerdict.uncertain => 'UNCERTAIN',
        GoalVerdict.inProgress => 'in progress',
        GoalVerdict.none => '',
      };
      buffer.writeln('  verdict: $mark');
      if (current.evidence.isNotEmpty) {
        buffer.writeln('  evidence: ${current.evidence}');
      }
    } else {
      buffer.writeln('  not judged yet');
    }
    terminal.writeln(buffer.toString());
  }

  /// Detach the judge's in-flight work. The plugin holds no other
  /// resources.
  void dispose() => closeSession();

  @override
  void closeSession() {
    _closed = true;
    final subscription = _subscription;
    if (subscription != null) _loop?.unsubscribe(subscription);
    _subscription = null;
    _judgeSub?.cancel();
  }
}
