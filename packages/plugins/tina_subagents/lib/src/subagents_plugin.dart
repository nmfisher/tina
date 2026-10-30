/// The sub-agents plugin: the session factory, store link, and current
/// session arrive at load, the same way the composition hands over a
/// `Terminal`.
///
/// A sub-agent is launched **without blocking** the parent. [launch]
/// spins up a child session, hands it a self-contained prompt, and
/// returns immediately with the child's session id — the parent keeps
/// working. The child runs to completion on its own; the `subagent`
/// companion tool inspects it (`status`), joins it (`wait`), or stops it
/// (`cancel`). The child's final text is returned by `wait` (and by
/// `status` once it has settled).
///
/// The plugin owns **the limits**. The counters they read live on the
/// session ([SessionDetails]): this session's depth, its children in
/// flight, the tokens its children spent. Enforcement here is one
/// chokepoint — [SubagentsPlugin.launch] — and each refusal names the
/// limit it hit, as a normal tool result the model reads:
///
/// - `sub-agent refused: depth N exceeds maximum M`
/// - `sub-agent refused: concurrency at maximum M`
/// - `sub-agent refused: token budget exhausted (spent X of limit Y)`
///
/// Defaults are **depth 3, concurrency 3**. The old engine queued excess
/// spawns; we refuse, and the refusal names concurrency.
///
/// The gates are shared: the budget is one [SubagentsBudget] value the
/// plugin holds, so every launch books against the same number.
///
/// The child inherits the working directory, the permission mode, and
/// the approval plumbing because the factory the plugin was handed
/// builds it that way — this package never names a mode of its own, so
/// escalation is not refused, it is unrepresentable here.
library;

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

import 'spawn_tool.dart';

/// Builds a child host for [plugin]. The composition's closure: it
/// reads the child depth, the working directory, the mode, the provider
/// factory, and the store path **from the plugin and the parent
/// session** — this package names none of them, so a child cannot
/// receive values its parent did not have.
typedef ChildSessionFactory = Host Function(SubagentsPlugin plugin);

/// A read-only view of persisted sessions, supplied by the application's
/// persistence layer. Used only to **resurrect** previously-launched
/// children after a resume: their ids and last assistant text, so the
/// `subagent` tool can report on them even though they are gone. The
/// plugin selects the entries that belong to this parent, so the source
/// is just a dumb dump of what it knows. Null on the plugin means no
/// resurrection — children launched before a quit are simply not visible
/// after a resume.
abstract interface class SubagentHistorySource {
  /// Every stored session id mapped to its last assistant text (or null
  /// when the session never produced one).
  Map<String, String?> storedSessions();
}

/// The plugin's limits. Pure configuration: the plugin decides with it,
/// the session only records outcomes.
final class SubagentsConfig {
  const SubagentsConfig({
    this.maxDepth = 3,
    this.maxConcurrency = 3,
    this.tokenBudget = 2000000,
    this.resultCap = 16000,
  });

  /// The deepest child chain allowed. A launch whose child would sit at
  /// depth [maxDepth] + 1 or deeper is refused.
  final int maxDepth;

  /// How many children one session may run at once. At the maximum a
  /// further launch is refused — the old engine queued; we refuse.
  final int maxConcurrency;

  /// The token budget this session's children share, in tokens, counted
  /// as reported usage (input + output) booked as turns end. 0 disables
  /// the budget.
  final int tokenBudget;

  /// A child's answer is truncated to this many characters before it
  /// becomes the result `wait` returns.
  final int resultCap;
}

/// The shared token gate: what the session's children have spent, and
/// the ceiling they must stay under. One instance per session, held by
/// the plugin, so every launch books against the same number.
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

/// One launched child. Lives in the plugin's job map until the session
/// ends; a settled child keeps its [outcome] so `status`/`wait` can
/// return it after the fact. A **ghost** is a previously-launched child
/// resurrected from the store after a resume: it has no live host
/// ([child] is null) and is already settled.
final class _SubagentJob {
  _SubagentJob(this.id, this.child, this.depth);

  _SubagentJob.ghost(String id, int depth, ToolResult outcome)
      : id = id,
        child = null,
        depth = depth,
        outcome = outcome {
    done.complete(outcome);
  }

  final String id;

  /// The live child host, or null for a resurrected ghost.
  final Host? child;

  final int depth;

  /// Completes when the child settles, with its final result. Ghosts are
  /// completed at creation.
  final done = Completer<ToolResult>();

  /// The settled result, null while the child runs.
  ToolResult? outcome;

  /// A short human-readable status line, kept current as the child runs.
  String status = 'starting';

  /// Stop the child: cancel its loop. No-op for a ghost (it has no live
  /// host); idempotent for a live child.
  void stop() {
    final host = child;
    if (host != null) host.session.loop.cancel('parent cancelled the sub-agent');
  }
}

final class SubagentsPlugin extends AgentPlugin {
  SubagentsPlugin({
    this.id = 'tina/subagents',
    this.order = 40,
    required ChildSessionFactory sessionFactory,
    PluginSession? parent,
    SubagentsConfig config = const SubagentsConfig(),
    this.configFor,
    this.history,
  })  : _sessionFactory = sessionFactory,
        _config = config,
        _parent = parent,
        budget = SubagentsBudget(limit: config.tokenBudget);

  @override
  final String id;

  /// After workflows (30); a launch is the least pressing section.
  @override
  final int order;

  /// Builds a child host. The plugin supplies the facts; the factory
  /// supplies the inherited world (working directory, mode, approvals).
  final ChildSessionFactory _sessionFactory;

  /// The parent session: where depth is read from and counters live.
  PluginSession? _parent;
  PluginSession get parent => _parent ?? (throw StateError('subagents not opened'));

  @override
  SessionSeed? openSession(PluginSession session) {
    _parent = session;
    budget.spent = session.details.tokensSpent;
    // A fresh plugin has no live children: the persisted in-flight counter
    // describes children from a previous process/session that are gone
    // with it. Reset it so a resumed session is not locked out of
    // launching. The token spend is real accounting and is kept.
    session.details.childrenInFlight = 0;
    // Resurrect children launched before the previous session ended, so a
    // resumed session can still retrieve their answers. They are ghosts:
    // no live host, already settled. A damaged/absent history never blocks
    // opening.
    if (session.resuming && history != null) {
      try {
        final sessions = history!.storedSessions();
        for (final entry in sessions.entries) {
          if (_isChildOf(entry.key)) {
            _jobs[entry.key] = _SubagentJob.ghost(
              entry.key,
              childDepth,
              _ghostResult(entry.key, entry.value),
            );
          }
        }
      } catch (_) {
        // History read failure: open without resurrection.
      }
    }
    return null;
  }

  /// Whether [id] looks like a child of this parent — the id shape the
  /// plugin assigns ([nextChildId]) and nothing else.
  bool _isChildOf(String id) =>
      id.startsWith('${parent.id}-') && id.contains('-child');

  /// A result for a resurrected child: its persisted last assistant text,
  /// capped, or a note when it never produced one.
  ToolResult _ghostResult(String id, String? finalText) {
    final text = finalText ?? '';
    final capped = text.length > config.resultCap
        ? '${text.substring(0, config.resultCap)}… (truncated at '
            '${config.resultCap} characters)'
        : text;
    if (capped.isEmpty) {
      return ToolResult('[sub-agent $id] ended with no persisted text '
          '(interrupted)',
          isError: true);
    }
    return ToolResult('[sub-agent $id] $capped');
  }

  /// The limits.
  final SubagentsConfig _config;
  final SubagentsConfig Function()? configFor;
  SubagentsConfig get config => configFor?.call() ?? _config;

  /// The shared token gate.
  final SubagentsBudget budget;

  /// Persisted-session source, when the application provides one. Used on
  /// resume to resurrect previously-launched children.
  final SubagentHistorySource? history;

  /// Launched children, keyed by their session id. A settled child stays
  /// here so its answer remains retrievable.
  final _jobs = <String, _SubagentJob>{};

  /// True once [closeSession] has run; no launches or inspects proceed.
  bool _closed = false;

  LaunchSubagentTool? _launchTool;
  SubagentInspectTool? _inspectTool;

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

  /// Ids of every launched child, in launch order (running or settled).
  List<String> get launchedChildIds => [for (final j in _jobs.values) j.id];

  /// Launch a child to answer [prompt] and return immediately with its
  /// id. The child runs in the background; use [inspect] to follow it.
  /// Refused — naming the limit — when depth, concurrency or the token
  /// budget would be exceeded.
  ToolResult launch(String prompt) {
    if (_closed) return ToolResult.error('subagents plugin is closed');
    if (childDepth > config.maxDepth) {
      return ToolResult.error('sub-agent refused: depth $childDepth exceeds '
          'maximum ${config.maxDepth}');
    }
    if (childrenInFlight >= config.maxConcurrency) {
      return ToolResult.error('sub-agent refused: concurrency at maximum '
          '${config.maxConcurrency}');
    }
    if (budget.exhausted) {
      return ToolResult.error(budget.refusal);
    }

    // Take the slot before the child runs; release when it settles, so
    // the counter reads true at every moment in between.
    parent.details.childrenInFlight++;
    parent.notifyChanged();
    final Host child;
    try {
      child = _sessionFactory(this);
    } on Object {
      parent.details.childrenInFlight--;
      parent.notifyChanged();
      rethrow;
    }
    final job = _SubagentJob(child.session.id, child, childDepth);
    _jobs[job.id] = job;
    unawaited(_run(job, prompt));
    return ToolResult('launched sub-agent ${job.id}\n\n'
        'It runs in the background while you keep working. Its answer '
        'arrives as a message when it finishes — end your turn if that '
        'is all you are waiting on. `subagent` re-reads a settled '
        'result or cancels.');
  }

  /// Inspect a launched child. [action] is one of:
  ///
  /// - `status`: the current status; the final answer once the child has
  ///   settled.
  /// - `wait`: block until the child settles and return its final text.
  ///   [waitMs] caps the wait (milliseconds); a timeout returns the
  ///   running status instead. While waiting, the child's live tool
  ///   activity is streamed through [progress] so a console can show it
  ///   working.
  /// - `cancel`: stop the child and return its (cancelled) result.
  Future<ToolResult> inspect(String id,
      {String action = 'status', int? waitMs, void Function(String)? progress}) async {
    final job = _jobs[id];
    if (job == null) {
      return ToolResult.error('unknown sub-agent $id — nothing was launched '
          'with that id');
    }
    switch (action) {
      case 'cancel':
        job.stop();
        await job.done.future;
        return job.outcome!;
      case 'wait':
        if (waitMs != null && waitMs < 0) {
          return ToolResult.error('wait_ms must be nonnegative');
        }
        if (!job.done.isCompleted) {
          final sub = _forwardActivity(job, progress);
          try {
            if (waitMs == null) {
              await job.done.future;
            } else {
              final timeout = Future<void>.delayed(
                  Duration(milliseconds: waitMs), () {});
              await Future.any([job.done.future, timeout]);
              if (!job.done.isCompleted) {
                return ToolResult('sub-agent $id still running '
                    '(depth ${job.depth}): ${job.status}');
              }
            }
          } finally {
            await sub?.cancel();
          }
        }
        return job.outcome!;
      case 'status':
        if (job.done.isCompleted) return job.outcome!;
        return ToolResult('sub-agent $id running '
            '(depth ${job.depth}): ${job.status}');
      default:
        return ToolResult.error('action must be status, wait or cancel');
    }
  }

  /// Surface a live child's tool activity through [progress], or null when
  /// there is nothing to stream (no callback, or a ghost with no host).
  StreamSubscription<void>? _forwardActivity(
      _SubagentJob job, void Function(String)? progress) {
    final child = job.child;
    if (progress == null || child == null) return null;
    return child.session.loop.toolActivity.listen((event) {
      final String? text = switch (event) {
        ToolStarted(:final call) => 'running ${call.name}',
        ToolFinished(:final call, :final result) =>
          '${call.name}: ${result.isError ? 'error' : 'done'}',
        ToolProgress(:final status) => status,
        _ => null,
      };
      if (text != null && text.isNotEmpty) {
        progress('depth ${job.depth} · $text · child ${job.id}');
      }
    });
  }

  Future<void> _run(_SubagentJob job, String prompt) async {
    final child = job.child;
    // Ghosts never run — they are created already settled. Guard anyway
    // so this is never called on one.
    if (child == null) {
      final result = ToolResult.error('sub-agent ${job.id}: no live host');
      job.outcome = result;
      job.done.complete(result);
      return;
    }
    job.status = 'working';
    final watch = Stopwatch()..start();
    final activity = child.session.loop.toolActivity.listen((event) {
      if (event is ToolStarted) job.status = 'running ${event.call.name}';
      if (event is ToolFinished) {
        job.status = '${event.call.name}: '
            '${event.result.isError ? 'error' : 'done'}';
      }
      if (event is ToolProgress) job.status = event.status;
    });
    ToolResult result;
    try {
      final outcome =
          await child.send(prompt, turnId: 't-${child.session.id}');
      // Book reported usage into the shared gate and the session's
      // counter — from the turn-end entry, where the loop recorded it.
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
      job.status = '${outcome.stopReason.name} · '
          '${watch.elapsedMilliseconds} ms · $used reported tokens';
      final answer = [
        for (final m in outcome.modelResponses)
          for (final b in m.content.whereType<TextBlock>()) b.text,
      ].join();
      final capped = answer.length > config.resultCap
          ? '${answer.substring(0, config.resultCap)}… (truncated at '
              '${config.resultCap} characters)'
          : answer;
      if (outcome.stopReason == StopReason.cancelled) {
        result = ToolResult('[sub-agent ${job.id}] cancelled: the parent '
            'cancelled the sub-agent',
            isError: true);
      } else if (outcome.stopReason == StopReason.error) {
        result = ToolResult('[sub-agent ${job.id}] ended in error '
            '(${outcome.stopReason.name})',
            isError: true);
      } else {
        result = ToolResult(
            capped.isEmpty
                ? '[sub-agent ${job.id}] finished with no text '
                    '(stop reason: ${outcome.stopReason.name})'
                : '[sub-agent ${job.id}] $capped');
      }
    } on Object catch (e) {
      job.status = 'failed after ${watch.elapsedMilliseconds} ms';
      result = ToolResult.error('sub-agent ${job.id} failed: $e');
    }
    // Settle the slot and release the child BEFORE anyone observes
    // completion, so a `wait` returning means the sub-agent is truly
    // finished and its counter is already released.
    job.outcome = result;
    try {
      await activity.cancel();
      child.close();
    } finally {
      parent.details.childrenInFlight--;
      // If the parent's session is already closing ([closeSession]), its
      // plugins may be torn down (e.g. persistence closed) — don't
      // trigger a notification into that half-closed world.
      if (!_closed) parent.notifyChanged();
      job.done.complete(result);
    }
    // Hand the answer to the parent without being asked: the transcript
    // notice starts a parent turn when idle (or queues as steering input
    // mid-turn). The `subagent` tool stays as the retrieval path for
    // applications without notice delivery, and as an idempotent re-read.
    if (!_closed) {
      final delivery = parent.deliverNotice;
      if (delivery != null) delivery(_settlement(result));
    }
  }

  /// The transcript text a settled child contributes: its answer, or the
  /// failure that stands in for one. Mirrors what `status` returns.
  String _settlement(ToolResult result) => result.isError
      ? '[sub-agent settled with an error] ${result.content}'
      : '[sub-agent finished] ${result.content}';

  /// The two tools this plugin contributes: launch, and inspect.
  @override
  List<ToolSchema> get tools => [
        if (_launchTool != null) _launchTool!.schema,
        if (_inspectTool != null) _inspectTool!.schema,
      ];

  /// Stop the parent's session cleanly: cancel every running child so its
  /// turn settles and its concurrency slot releases (the child's own
  /// background finalize closes the child host). Called by the host
  /// during [Host.close]; children settle asynchronously after this.
  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    for (final job in _jobs.values) {
      if (!job.done.isCompleted) job.stop();
    }
  }

  @override
  void onPrompt(TurnContext c) {
    c.promptSections.add(_sectionText());
  }

  /// The model-facing delegation section. Delegation is presented as the
  /// default for scoped independent work, with the completion contract
  /// spelled out so the model ends its turn instead of polling. At the
  /// depth cap the section tells the model to work directly, mirroring
  /// the refusal it would otherwise meet.
  String _sectionText() {
    final depthLine = childDepth > config.maxDepth
        ? 'You are at the delegation depth cap (${config.maxDepth}): do '
            'not call `launch_subagent`; carry out the work directly.\n'
        : '';
    return '<sub-agents>You can launch a sub-agent per call with the '
        '`launch_subagent` tool: give it a self-contained prompt; it '
        'returns immediately with the sub-agent\'s id and runs in the '
        'background. Sub-agents inherit your working directory and '
        'permission mode.\n'
        '$depthLine'
        'Delegate proactively: research, surveying, breadth-first '
        'exploration, independent implementation chunks, and any '
        'self-contained check are sub-agent work — offloading them keeps '
        'this conversation\'s context for decisions and integration. '
        'Launch independent delegations together in one message and '
        'continue useful work while they run. Each finished sub-agent\'s '
        'answer arrives as its own message; when only waiting remains, '
        'end your turn instead of polling — never sleep or busy-check the '
        '`subagent` tool for a running child.</sub-agents>';
  }

  /// Mount: build the tools with this plugin as their backend and register
  /// their executors. The host calls this through [AgentPlugin.mountOn]
  /// at start — the tools become reachable the same moment the plugin mounts.
  @override
  void mountOn(AgentLoop loop) {
    _launchTool ??= LaunchSubagentTool(this);
    _inspectTool ??= SubagentInspectTool(this);
    loop.registerContextExecutor(SubagentsPlugin.launchSchemaName,
        (input, context) => _launchTool!.execute(input));
    loop.registerContextExecutor(SubagentsPlugin.inspectSchemaName,
        (input, context) => _inspectTool!.execute(input, progress: context.progress));
  }

  /// The launch tool's schema name.
  static const launchSchemaName = 'launch_subagent';

  /// The inspect tool's schema name.
  static const inspectSchemaName = 'subagent';
}
