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

import 'dart:async';
import 'package:tina_engine_2/tina_engine_2.dart';

import 'compaction_window.dart';

/// What size the request must reach before compaction fires, in input
/// tokens — explicit configuration, never a magic number in the flow.
/// A second knob bounds the estimation error: after a compaction the
/// next trigger is recomputed from what remains, so a borderline request
/// does not thrash.
///
/// Both size knobs default to null: unset means window-derived — the
/// trigger at [compactionWindowTriggerFraction] of the active model's
/// context window and the kept tail at [compactionWindowKeepRecentFraction]
/// (floored at [compactionMinKeptRecentTokens]), resolved live each turn
/// through the plugin's [CompactionPlugin.readContextWindow] seam. An
/// unknown window falls back to the historical fixed defaults
/// ([compactionFallbackThresholdTokens] / [compactionMinKeptRecentTokens]);
/// compaction is never silently disabled by an unresolvable window.
class CompactionConfig {
  const CompactionConfig({
    this.thresholdTokens,
    this.overThresholdMargin = 1.0,
    this.keepRecentTokens,
    this.minMessagesToCompact = 4,
  }) : assert(keepRecentTokens == null || keepRecentTokens >= 0);

  /// Estimated input tokens a request may carry before the older half is
  /// summarized. Null derives the trigger from the active model's
  /// context window each turn. An explicit 0 disables compaction
  /// entirely (negative values too, by the same `<= 0` rule).
  final int? thresholdTokens;

  /// Compaction fires at `thresholdTokens * overThresholdMargin`, and the
  /// next trigger level is recomputed from what remains — slack for an
  /// estimator that can only guess. Must be >= 1.0.
  final double overThresholdMargin;

  /// How many estimated transcript tokens of the most recent history
  /// stay verbatim. Null scales the budget with the active model's
  /// context window (floored at [compactionMinKeptRecentTokens]). The
  /// split walks back from the newest message until this budget is
  /// spent, then snaps to a turn boundary — a tool pair is never
  /// severed. When the whole transcript fits the budget, only the
  /// newest exchange stays; when there is a single exchange, it too
  /// is summarized.
  final int? keepRecentTokens;

  /// Fewer derived messages than this and there is nothing worth
  /// summarizing — compacting would spend a request to shrink almost
  /// nothing. The automatic trigger only; `/compact` bypasses it.
  final int minMessagesToCompact;

  /// Deprecated count-based tail: kept only so old callers compile.
  /// The split no longer counts turns.
  @Deprecated('Use keepRecentTokens — the split is token-budgeted now.')
  final int keepRecentTurns = 2;
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
    this.readContextWindow,
    this.readThresholdOverride,
  }) : assert(config.overThresholdMargin >= 1.0);

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

  /// The active model's context window in tokens, or null when the
  /// composition cannot resolve it (unknown model, no descriptor).
  /// Read LIVE each turn and at each `/compact`, so a `/model` switch
  /// is honored without a restart. Null keeps the safe fixed defaults.
  final int? Function()? readContextWindow;

  /// The user's absolute trigger override in tokens, or null when the
  /// setting has no written value (window-derived). A written 0
  /// disables automatic compaction, matching the explicit config's
  /// `thresholdTokens <= 0` semantics. Read live each turn.
  final int? Function()? readThresholdOverride;
  @override
  List<Command> get commands => [
        Command(
            name: 'compact',
            description: 'summarize conversation history now',
            cancel: () => _summaryCancel?.cancel('compaction cancelled'),
            handler: (_) async {
              if (!(canCompact?.call() ?? true)) {
                terminal?.writeln('Compaction is paused while agent-managed '
                    'context is active. Edit the context file instead.');
                return;
              }
              final loop = _loop;
              if (loop == null) return;
              final cancel = _summaryCancel = CancelToken();
              try {
                await loop.betweenTurns(() async {
                  if (cancel.cancelled) return;
                  final view = loop.derive();
                  final split =
                      _splitAtTokenBoundary(view.messages, _keepTokens());
                  if (split == null) {
                    terminal?.writeln(
                        'Nothing to compact: the transcript has no text to '
                        'summarize yet. Keep working — /compact can '
                        'summarize once exchanges exist.');
                    return;
                  }
                  final summary = await _summarize(loop,
                      view.messages.sublist(split.from, split.to + 1), cancel);
                  if (_loop != loop || cancel.cancelled) return;
                  if (summary == null) {
                    terminal?.writeln('Compaction failed; history retained.');
                    return;
                  }
                  loop.compact(
                      split.from, split.to, '$compactionSummaryMarker$summary');
                  terminal?.writeln('Conversation compacted.');
                });
              } finally {
                if (identical(_summaryCancel, cancel)) _summaryCancel = null;
              }
            })
      ];

  AgentLoop? _loop;
  CancelToken? _summaryCancel;

  @override
  void closeSession() {
    _summaryCancel?.cancel('session closed');
    _loop = null;
  }

  /// Where the next trigger sits. Recomputed after each compaction from
  /// what remains, so a borderline request does not thrash; reset when
  /// the resolved threshold changes (a `/model` switch, a settings
  /// write), so a smaller window's trigger applies immediately instead
  /// of waiting for the old, larger level.
  double _nextTrigger = 0;

  /// The threshold the current [_nextTrigger] was derived from —
  /// change detection for the live window/override reads.
  double? _triggerBase;

  @override
  void mountOn(AgentLoop loop) {
    _loop = loop;
    _triggerBase = _baseThreshold();
    _nextTrigger = _triggerBase! * config.overThresholdMargin;
  }

  /// The trigger before the anti-thrash margin: the explicit config
  /// value when set, else the setting override, else the live window
  /// fraction, else the safe fixed fallback. `<= 0` disables the
  /// automatic trigger (the config's explicit rule wins over everything).
  double _baseThreshold() {
    final explicit = config.thresholdTokens;
    if (explicit != null) return explicit.toDouble();
    final window = readContextWindow?.call();
    return effectiveCompactionThreshold(
      contextWindow: window,
      overrideTokens: readThresholdOverride?.call(),
    ).toDouble();
  }

  /// The kept-recent budget: the explicit config value when set, else
  /// scaled to the live window, floored at the historical minimum.
  int _keepTokens() {
    final explicit = config.keepRecentTokens;
    if (explicit != null) return explicit;
    return effectiveKeptRecentTokens(contextWindow: readContextWindow?.call());
  }

  @override
  Future<void> onTurnEnd(TurnContext c) async {
    if (c.cancelled || c.outcome?.stopReason == StopReason.cancelled) return;
    if (!(canCompact?.call() ?? true)) return;
    final loop = _loop;
    if (loop == null) return;
    // Resolve the trigger LIVE: the window follows a `/model` switch and
    // the override follows a settings write, both without a restart.
    final base = _baseThreshold();
    if (base <= 0) return;
    if (base != _triggerBase) {
      _triggerBase = base;
      _nextTrigger = base * config.overThresholdMargin;
    }
    final view = loop.derive();
    final estimate =
        estimateInputTokens(loop.settings.systemPrompt, view.messages);
    if (estimate < _nextTrigger) return;
    if (view.messages.length < config.minMessagesToCompact) return;

    final split = _splitAtTokenBoundary(view.messages, _keepTokens());
    if (split == null) return;

    _nextTrigger = estimate * config.overThresholdMargin;
    final cancel = _summaryCancel = CancelToken();
    unawaited(c.whenCancelled.then((_) => cancel.cancel('turn cancelled')));
    try {
      await _compact(loop, view.messages, split, cancel);
    } finally {
      if (identical(_summaryCancel, cancel)) _summaryCancel = null;
    }
  }

  /// The split that keeps roughly [keepTokens] estimated transcript
  /// tokens of recent history verbatim. Synthetic messages — summaries
  /// and splice notices — are history like any other: they never anchor
  /// the kept tail, but they do spend the budget, so a compacted session
  /// re-compacts instead of declining.
  ///
  /// Boundary selection, newest-first:
  /// 1. walk back until [keepTokens] are spent, dropping only whole
  ///    messages;
  /// 2. snap forward to the nearest turn start (real, text-bearing user
  ///    message) at or inside the cutoff, so a turn's tool pairs can
  ///    never be severed;
  /// 3. everything fits — keep only the newest exchange (from the
  ///    newest real user message), so a summary never duplicates the
  ///    whole conversation beside itself;
  /// 4. a single exchange, or a newest exchange over budget — summarize
  ///    everything, keep nothing.
  ///
  /// Returns null only when nothing has text to summarize.
  _Split? _splitAtTokenBoundary(List<Message> messages, int keepTokens) {
    final startsTurn = _turnStarts(messages);
    if (startsTurn.isEmpty) return null;

    var budget = keepTokens;
    var cutoff = 0; // messages[cutoff..] is the candidate kept tail.
    for (var i = messages.length - 1; i >= 0; i--) {
      budget -= estimateTranscriptMessageChars(messages[i]) ~/ 4;
      if (budget < 0) {
        cutoff = i + 1;
        break;
      }
      cutoff = i;
    }

    // Snap the cutoff up to a turn start so a tool pair stays whole.
    // Only when something is actually being dropped — a cutoff of 0
    // means the budget swallowed the whole transcript and the fallback
    // below chooses the kept tail.
    if (cutoff > 0) {
      for (var i = cutoff; i < messages.length; i++) {
        if (startsTurn.contains(i)) return _Split(0, i - 1);
      }
      return _Split(0, messages.length - 1);
    }

    // Everything fit the budget. Keeping the whole conversation beside
    // the summary would duplicate it — fall back to the newest exchange.
    for (var i = messages.length - 1; i >= 0; i--) {
      if (startsTurn.contains(i)) {
        if (i == 0) break; // a single exchange: fall through
        return _Split(0, i - 1);
      }
    }

    // One exchange, nothing older — there is still a summary to write.
    return _Split(0, messages.length - 1);
  }

  Future<void> _compact(AgentLoop loop, List<Message> messages, _Split split,
      CancelToken cancel) async {
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
    final summary = await _summarize(loop, summaryRequest, cancel);
    if (_loop != loop || cancel.cancelled || summary == null) return;
    loop.compact(split.from, split.to, '$compactionSummaryMarker$summary');
  }

  /// The derived-view indexes that start a turn: a real (non-synthetic)
  /// user message carrying at least one text block. The old engine's
  /// turn-start rule, index form.
  Set<int> _turnStarts(List<Message> messages) {
    final starts = <int>{};
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (m.role == Role.user &&
          !m.isSynthetic &&
          m.content.any((b) => b is TextBlock)) {
        starts.add(i);
      }
    }
    return starts;
  }

  /// One streaming request on the session's provider; the summary is the
  /// reply's text — read the same way the loop reads a turn (transcript
  /// text comes from `MessageComplete`, deltas are the stream's live
  /// form). A stream error or an empty reply is null — the caller skips
  /// and the next turn retries.
  Future<String?> _summarize(
      AgentLoop loop, List<Message> messages, CancelToken cancel) async {
    if (cancel.cancelled) return null;
    final buf = StringBuffer();
    var completed = false;
    StreamIterator<StreamEvent>? iterator;
    try {
      iterator = StreamIterator(loop.provider.send(
        system: compactionSummarySystemPrompt(),
        messages: messages,
        tools: const [],
      ));
      while (!cancel.cancelled &&
          await Future.any([
            iterator.moveNext(),
            cancel.whenCancelled.then((_) => false),
          ])) {
        switch (iterator.current) {
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
    } finally {
      // Stop delivery immediately; transport cleanup can itself be stalled.
      unawaited(iterator?.cancel().catchError((Object _) {}));
    }
    final text = buf.toString().trim();
    return cancel.cancelled || !completed || text.isEmpty ? null : text;
  }
}
