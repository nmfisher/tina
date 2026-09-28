/// The sub-agents plugin: the session factory, store link, and current
/// session arrive at load, the same way the composition hands over a
/// `Terminal`.
///
/// The plugin owns **the limits**. The counters they read live on the
/// session ([SessionDetails]): this session's depth, its children in
/// flight, the tokens its children spent. Enforcement here is one
/// chokepoint — [SubagentsPlugin.spawn] — and each refusal names the
/// limit it hit, as a normal tool result the model reads:
///
/// - `sub-agent refused: depth N exceeds maximum M`
/// - `sub-agent refused: concurrency at maximum M`
/// - `sub-agent refused: token budget exhausted (spent X of limit Y)`
///
/// Defaults are **depth 3, concurrency 3** — the old engine's defaults,
/// which the survey confirmed against `runtime_config.dart` (the brief's
/// earlier "6" was an assumption the survey overrode). The old engine
/// queued excess spawns; we refuse, and the refusal names concurrency.
/// The result cap is explicit configuration ([SubagentsConfig.resultCap]),
/// not a constant buried in code.
///
/// The gates are shared: the budget is one [SubagentsBudget] value the
/// plugin holds, so every spawn books against the same number — the seam
/// a classifier reuses later instead of building its own budget.
///
/// The child inherits the working directory and the mode because the
/// factory the plugin was handed builds it that way — this package never
/// names a mode of its own, so escalation is not refused, it is
/// unrepresentable here.
library;

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

import 'spawn_tool.dart';

/// The plugin's limits. Pure configuration: the plugin decides with it,
/// the session only records outcomes.
final class SubagentsConfig {
  const SubagentsConfig({
    this.maxDepth = 3,
    this.maxConcurrency = 3,
    this.tokenBudget = 2000000,
    this.resultCap = 16000,
  });

  /// The deepest child chain allowed. A spawn whose child would sit at
  /// depth [maxDepth] + 1 or deeper is refused. Matches the old engine's
  /// `maxSubAgentDepth`.
  final int maxDepth;

  /// How many children one session may run at once. At the maximum a
  /// further spawn is refused — the old engine queued; we refuse.
  /// Matches the old engine's `maxSubAgentConcurrency`.
  final int maxConcurrency;

  /// The token budget this session's children share, in tokens, counted
  /// as reported usage (input + output) booked as turns end. 0 disables
  /// the budget — the old config's 0-means-unlimited.
  final int tokenBudget;

  /// A child's answer is truncated to this many characters before it
  /// becomes the tool result — explicit here, matching the old
  /// `resultCharCap` default, but configuration, not a buried constant.
  final int resultCap;
}

/// The shared token gate: what the session's children have spent, and
/// the ceiling they must stay under. One instance per session, held by
/// the plugin, so every spawn books against the same number — the seam
/// a classifier reuses later instead of building its own budget.
final class SubagentsBudget {
  SubagentsBudget({required this.limit}) : spent = 0;

  /// The ceiling in tokens; 0 means unlimited.
  final int limit;

  /// Reported spend so far. Additive; only real usage moves it.
  int spent;

  /// Whether the gate is tripped: any nonzero limit that spend has
  /// reached. A tripped gate refuses before a child starts.
  bool get exhausted => limit > 0 && spent >= limit;

  /// Book [tokens] of reported usage. Returns the new total.
  int add(int tokens) => spent += tokens;

  /// What a refusal says when the gate is tripped — the one wording,
  /// everywhere.
  String get refusal => 'sub-agent refused: token budget exhausted '
      '(spent $spent of limit $limit)';
}

/// Whether the spawning turn has been cancelled. The tool derives it
/// from the turn's cancel token (stashed in `beforeToolCall`); a direct
/// caller can derive it from anything. A probe, not a token: the child
/// is cancelled *through its own loop*, one direction only.
typedef CancelProbe = bool Function();

/// The spawn site. The plugin implements it; the tool calls it. Kept as
/// an interface so a test (or a later caller) can drive spawns without
/// building a whole loop.
abstract interface class SubagentSpawner {
  /// Spawn one child to answer [prompt]. Returns the child's final
  /// text (capped to the configured cap) — or a refusal naming the
  /// limit that stopped the spawn; check [ToolResult.isError].
  /// [cancelled] is polled while the child runs; when it turns true the
  /// child's loop is cancelled and the result says so.
  Future<ToolResult> spawn(String prompt, {CancelProbe? cancelled});
}

/// Builds a child host for [plugin]. The composition's closure: it
/// reads the child depth, the working directory, the mode, the provider
/// factory, and the store path **from the plugin and the parent
/// session** — this package names none of them, so a child cannot
/// receive values its parent did not have.
typedef ChildSessionFactory = Host Function(SubagentsPlugin plugin);

final class SubagentsPlugin extends AgentPlugin implements SubagentSpawner {
  SubagentsPlugin({
    this.id = 'tina/subagents',
    this.order = 40,
    required ChildSessionFactory sessionFactory,
    PluginSession? parent,
    this.config = const SubagentsConfig(),
  })  : _sessionFactory = sessionFactory,
        _parent = parent,
        budget = SubagentsBudget(limit: config.tokenBudget);

  @override
  final String id;

  /// After workflows (30); a spawn is the least pressing section.
  @override
  final int order;

  /// Builds a child host. The plugin supplies the facts; the factory
  /// supplies the inherited world.
  final ChildSessionFactory _sessionFactory;

  /// The parent session: where depth is read from and counters live.
  PluginSession? _parent;
  PluginSession get parent =>
      _parent ?? (throw StateError('subagents not opened'));

  @override
  SessionSeed? openSession(PluginSession session) {
    _parent = session;
    budget.spent = session.details.tokensSpent;
    return null;
  }

  /// The limits.
  final SubagentsConfig config;

  /// The shared token gate.
  final SubagentsBudget budget;

  SpawnTool? _tool;

  /// The parent's depth, as the session carries it.
  int get depth => parent.details.depth;

  /// The depth this plugin's children sit at.
  int get childDepth => depth + 1;

  /// Children in flight, as the session carries it.
  int get childrenInFlight => parent.details.childrenInFlight;

  var _childSeq = 0;

  /// The next child's session id — derived from the parent's, so a
  /// store listing shows the family together.
  String nextChildId() =>
      '${parent.id}-${DateTime.now().microsecondsSinceEpoch}-child${++_childSeq}';

  /// The turn context of the spawn call in flight, stashed by
  /// [beforeToolCall]. Copies of a context share one cancel token, so
  /// reading it here reads the live turn.
  TurnContext? _turn;

  /// Whether the spawn call's turn has been cancelled. The tool passes
  /// this as the spawn's cancel probe.
  bool get turnCancelled => _turn?.cancelled ?? false;

  @override
  void beforeToolCall(TurnContext c) {
    if (c.call?.name == SubagentsPlugin.schemaName) _turn = c;
  }

  /// Spawn one child and return its final text. The one chokepoint for
  /// every limit.
  @override
  Future<ToolResult> spawn(String prompt,
      {CancelProbe? cancelled, void Function(String)? progress}) async {
    // Depth: this plugin's children sit at childDepth. Deeper than the
    // maximum, refuse — naming both numbers.
    if (childDepth > config.maxDepth) {
      return ToolResult.error('sub-agent refused: depth $childDepth exceeds '
          'maximum ${config.maxDepth}');
    }
    // Concurrency: at the maximum, refuse — the old engine queued; we
    // refuse, and the refusal names concurrency.
    if (childrenInFlight >= config.maxConcurrency) {
      return ToolResult.error('sub-agent refused: concurrency at maximum '
          '${config.maxConcurrency}');
    }
    // Budget: a tripped gate refuses before a child starts.
    if (budget.exhausted) {
      return ToolResult.error(budget.refusal);
    }

    // Take the slot before the child runs; release when it settles, so
    // the counter reads true at every moment in between.
    parent.details.childrenInFlight++;
    final Host child;
    try {
      parent.notifyChanged();
      child = _sessionFactory(this);
    } on Object {
      parent.details.childrenInFlight--;
      parent.notifyChanged();
      rethrow;
    }
    final watch = Stopwatch()..start();
    void status(String text) =>
        progress?.call('depth $childDepth · $text · child ${child.session.id}');
    status('working');
    final activity = child.session.loop.toolActivity.listen((event) {
      if (event is ToolStarted) status('running ${event.call.name}');
      if (event is ToolFinished)
        status(
            '${event.call.name}: ${event.result.isError ? 'error' : 'done'}');
      if (event is ToolProgress) status(event.status);
    });
    // Cancellation passthrough: while the child runs, watch the spawn
    // call's turn; if it is cancelled, cancel the child's loop. The
    // poll is 5 ms — short against a model call, long enough to be
    // free; the child loop's cancel is idempotent.
    Timer? watchdog;
    if (cancelled != null) {
      watchdog = Timer.periodic(const Duration(milliseconds: 5), (_) {
        if (cancelled()) {
          child.session.loop.cancel('parent turn cancelled');
        }
      });
    }
    try {
      final outcome = await child.send(prompt, turnId: 't-${child.session.id}');
      // Book reported usage into the shared gate and the session's
      // counter — from the turn-end entry, which is where the loop
      // recorded it.
      var used = 0;
      for (final e in child.session.loop.log.whereType<TurnEndedEntry>()) {
        final u = e.usage;
        used += u.inputTokens +
            u.outputTokens +
            u.cacheReadInputTokens +
            u.cacheCreationInputTokens;
      }
      if (used > 0) {
        budget.add(used);
        parent.details.tokensSpent += used;
      }
      status(
          '${outcome.stopReason.name} · ${watch.elapsedMilliseconds} ms · $used reported tokens');
      final answer = [
        for (final m in outcome.modelResponses)
          for (final b in m.content.whereType<TextBlock>()) b.text,
      ].join();
      final capped = answer.length > config.resultCap
          ? '${answer.substring(0, config.resultCap)}… (truncated at '
              '${config.resultCap} characters)'
          : answer;
      if (outcome.stopReason == StopReason.cancelled) {
        return ToolResult(
            '[sub-agent ${child.session.id}] cancelled: parent turn '
            'cancelled before the sub-agent finished',
            isError: true);
      }
      return ToolResult(
          capped.isEmpty
              ? '[sub-agent ${child.session.id}] finished with no text '
                  '(stop reason: ${outcome.stopReason.name})'
              : '[sub-agent ${child.session.id}] $capped',
          isError: outcome.stopReason == StopReason.error);
    } on Object catch (e) {
      status('failed after ${watch.elapsedMilliseconds} ms');
      return ToolResult.error('sub-agent ${child.session.id} failed: $e');
    } finally {
      watchdog?.cancel();
      await activity.cancel();
      try {
        child.close();
      } finally {
        parent.details.childrenInFlight--;
        parent.notifyChanged();
      }
    }
  }

  /// The one tool this plugin contributes.
  @override
  List<ToolSchema> get tools => [if (_tool != null) _tool!.schema];

  @override
  void onPrompt(TurnContext c) {
    c.promptSections.add(
      '<sub-agents>You can spawn one sub-agent per call with the '
      '`spawn_subagent` tool: give it a self-contained prompt; its final '
      'text comes back as the tool result. Sub-agents share your working '
      'directory and permission mode.</sub-agents>',
    );
  }

  /// Mount: build the tool with this plugin as its spawner and register
  /// its executor. The host calls this through [AgentPlugin.mountOn] at start —
  /// the tool becomes reachable the same moment the plugin mounts.
  @override
  void mountOn(AgentLoop loop) {
    _tool ??= SpawnTool(this);
    loop.registerContextExecutor(SubagentsPlugin.schemaName,
        (input, context) => _tool!.execute(input, progress: context.progress));
  }

  /// The tool's schema name.
  static const schemaName = 'spawn_subagent';
}
