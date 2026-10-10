/// Size-triggered compaction: when a request would carry too much
/// conversation, summarize the old half into the log's `Compacted` entry
/// and let the derive splice it back as one synthetic message.
///
/// The old engine summarized with a dedicated request and rewrote its
/// history in place. This port keeps the behaviour — a summary request,
/// a fixed prompt, recent turns kept intact — and moves the truth: the
/// log stays append-only and the [CompactedEntry] written by
/// `AgentLoop.compact` is what a resume derives from, so a compacted
/// session survives a store round trip by construction (slice 2).
///
/// No new hook: the loop's phases are sync, and compaction is a
/// between-turns operation — `onTurnEnd` runs after the turn is closed
/// in the log, which is exactly when `compact` accepts work. Like the
/// tools plugin, this plugin takes the loop at mount (`AgentPlugin.mountOn`,
/// the seam the host already honors) and uses it for nothing else.
library;

import 'package:tina_engine_2/tina_engine_2.dart';

/// What size the request must reach before compaction fires, in input
/// tokens — explicit configuration, never a magic number in the flow.
/// A second knob bounds the estimation error: after a compaction the
/// next trigger is recomputed from what remains, so a borderline request
/// does not thrash.
class CompactionConfig {
  const CompactionConfig({
    this.thresholdTokens = 100000,
    this.overThresholdMargin = 1.0,
    this.keepRecentTurns = 2,
    this.minMessagesToCompact = 4,
  });

  /// Estimated input tokens a request may carry before the older half is
  /// summarized. 0 disables compaction entirely.
  final int thresholdTokens;

  /// Compaction fires at `thresholdTokens * overThresholdMargin`, and the
  /// next trigger level is recomputed from what remains — slack for an
  /// estimator that can only guess. Must be >= 1.0.
  final double overThresholdMargin;

  /// How many of the most recent completed turns stay verbatim.
  final int keepRecentTurns;

  /// Fewer derived messages than this and there is nothing worth
  /// summarizing — compacting would spend a request to shrink almost
  /// nothing.
  final int minMessagesToCompact;
}

/// The request the summarizer sends: a fixed persona (terse markdown,
/// the facts a later session needs), then the messages being summarized
/// with one instruction to close. The core owns no prompt text; this is
/// the plugin's section, sent as the summary request's system prompt —
/// it never enters the session's own prompt.
String compactionSummarySystemPrompt() => '''
You are summarizing a coding-assistant conversation for context
preservation. Output ONLY the summary — no preamble, no closing.
Use terse markdown bullets, <= 400 words. Preserve:
- file paths the user or assistant referenced or edited
- decisions taken and the reason behind them
- unresolved questions or pending work
- errors encountered and how they were resolved
Omit pleasantries and reasoning that did not lead anywhere.
''';

/// The marker that opens a summary message, so a later split never
/// counts a synthetic summary as the start of a real turn.
const compactionSummaryMarker = '[earlier conversation summarized]\n\n';

/// Estimate a request's input size in tokens. Characters over 4 is the
/// old engine's rough and ready arithmetic; it is deliberately crude —
/// the threshold is configuration, the estimate only has to be honest
/// about order of magnitude. Lives in tina_core's token_estimators.dart
/// beside the context budget's byte-based gauge, so the two can neither
/// silently drift apart nor be unified by accident.
final estimateInputTokens = estimateTranscriptTokensChars;

/// One split candidate: replace derived-message positions `from..to`
/// with the summary, keep `to + 1..` verbatim.
class _Split {
  _Split(this.from, this.to);
  final int from;
  final int to;
}

/// The plugin. Takes the [AgentLoop] at mount, checks the derived
/// request size at each turn's end, and — over the threshold —
/// summarizes the older half with one extra provider request and writes
/// the `Compacted` entry through `loop.compact`. A failed summary is a
/// silent skip: the next turn re-checks, nothing is lost.
final class CompactionPlugin extends AgentPlugin {
  CompactionPlugin({
    this.config = const CompactionConfig(),
    this.terminal,
    this.id = 'tina/auto-compact',
    this.canCompact,
  })  : assert(config.overThresholdMargin >= 1.0),
        assert(config.keepRecentTurns >= 0);

  @override
  final String id;

  /// Run after most plugins, so a turn's outcome is settled before the
  /// size check reads the derived view.
  @override
  int get order => 900;

  final CompactionConfig config;
  final Terminal? terminal;

  /// Host coordination with another context policy. Defaults to enabled.
  /// Consult the loaded policy, not settings pending a restart.
  final bool Function()? canCompact;
  @override
  List<Command> get commands => [
        Command(
            name: 'compact',
            description: 'summarize conversation history now',
            handler: (_) async {
              if (!(canCompact?.call() ?? true)) {
                terminal?.writeln('Compaction is paused while agent-managed '
                    'context is active. Edit the context file instead.');
                return;
              }
              final loop = _loop;
              if (loop == null) return;
              await loop.betweenTurns(() async {
                final view = loop.derive();
                final split =
                    _splitAtTurnBoundary(view.messages, config.keepRecentTurns);
                if (split == null) {
                  terminal?.writeln('Not enough earlier history to compact.');
                  return;
                }
                final summary = await _summarize(
                    loop, view.messages.sublist(split.from, split.to + 1));
                if (_loop != loop) return;
                if (summary == null) {
                  terminal?.writeln('Compaction failed; history retained.');
                  return;
                }
                loop.compact(
                    split.from, split.to, '$compactionSummaryMarker$summary');
                terminal?.writeln('Conversation compacted.');
              });
            })
      ];

  AgentLoop? _loop;

  @override
  void closeSession() {
    _loop = null;
  }

  /// Where the next trigger sits. Recomputed after each compaction from
  /// what remains, so a borderline request does not thrash.
  double _nextTrigger = 0;

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    _nextTrigger = config.thresholdTokens * config.overThresholdMargin;
  }

  @override
  Future<void> onTurnEnd(TurnContext c) async {
    if (!(canCompact?.call() ?? true)) return;
    if (config.thresholdTokens <= 0) return;
    final loop = _loop;
    if (loop == null) return;
    final view = loop.derive();
    final estimate =
        estimateInputTokens(loop.settings.systemPrompt, view.messages);
    if (estimate < _nextTrigger) return;
    if (view.messages.length < config.minMessagesToCompact) return;

    final split = _splitAtTurnBoundary(view.messages, config.keepRecentTurns);
    if (split == null) return;

    _nextTrigger = estimate * config.overThresholdMargin;
    await _compact(loop, view.messages, split);
  }

  /// The split that keeps [keep] recent *turns* verbatim: the boundary is
  /// the keep-th turn's user message (the old engine's
  /// `_recentHumanTurnBoundary` — a text-bearing, non-synthetic user
  /// message is a turn's start in the derived view). Everything from that
  /// message on stays, so a turn's tool pairs can never be severed; the
  /// older half must hold at least two messages — there is no point
  /// summarizing one exchange. Returns null when nothing safely splits.
  _Split? _splitAtTurnBoundary(List<Message> messages, int keep) {
    var turns = 0;
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      final startsTurn = m.role == Role.user &&
          !m.isSynthetic &&
          m.content.any((b) => b is TextBlock);
      if (!startsTurn) continue;
      turns++;
      if (turns == keep) {
        if (i < 2) return null; // not enough older context to summarize
        return _Split(0, i - 1);
      }
    }
    return null;
  }

  Future<void> _compact(
      AgentLoop loop, List<Message> messages, _Split split) async {
    final summaryRequest = [
      ...messages.sublist(split.from, split.to + 1),
      Message(
        role: Role.user,
        content: const [
          TextBlock('Summarize the conversation above following the system '
              'instructions.'),
        ],
      ),
    ];
    final summary = await _summarize(loop, summaryRequest);
    if (_loop != loop || summary == null) return;
    loop.compact(split.from, split.to, '$compactionSummaryMarker$summary');
  }

  /// One streaming request on the session's provider; the summary is the
  /// reply's text — read the same way the loop reads a turn (transcript
  /// text comes from `MessageComplete`, deltas are the stream's live
  /// form). A stream error or an empty reply is null — the caller skips
  /// and the next turn retries.
  Future<String?> _summarize(AgentLoop loop, List<Message> messages) async {
    final buf = StringBuffer();
    var completed = false;
    try {
      await for (final event in loop.provider.send(
        system: compactionSummarySystemPrompt(),
        messages: messages,
        tools: const [],
      )) {
        switch (event) {
          case TextDelta(:final text):
            buf.write(text);
          case MessageComplete(content: final blocks):
            completed = true;
            buf.clear();
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
    final text = buf.toString().trim();
    return !completed || text.isEmpty ? null : text;
  }
}
