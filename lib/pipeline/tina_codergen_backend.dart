import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

/// The tina implementation of attractor's [CodergenBackend]. Each `box`/LLM
/// node is run as a real agent turn via [SubAgentScheduler.runStandalone],
/// using the node's `role` attribute to resolve a tina [AgentRole] (its tools,
/// model tier, and system prompt come with it).
///
/// Autonomous gating — a reviewer node approving or rejecting — works via a
/// verdict-line convention: a node prompt may instruct the agent to end its
/// response with `VERDICT: <label>`. The label is parsed into the outcome's
/// [Outcome.preferredLabel], which the engine matches against an edge's label
/// (edge-selection step 2), so `reviewer -> execute [label="approve"]` and
/// `reviewer -> plan [label="revise"]` route on the agent's own decision.
class TinaCodergenBackend implements CodergenBackend {
  final SubAgentScheduler scheduler;
  final AgentPipeline pipeline;

  /// Where the turn's streamed text goes — the active conversation's host, so
  /// pipeline output renders inline like a normal agent turn.
  final AgentSink sink;

  /// The role used when a node omits `role`. Defaults to `main` — the default
  /// chat experience is one main agent that delegates to research/sub-agents,
  /// never the repo-overview `orchestrator` flow by surprise.
  final String defaultRole;

  /// Model reference inherited by a node whose role carries no model tier
  /// (notably `main`, which has none): the live conversation model, threaded in
  /// from the runner so the default chat agent runs on the model you are
  /// chatting with rather than a fixed tier. Roles with a tier still resolve
  /// their own model — this is the fallback, not an override.
  final String defaultParentReference;

  TinaCodergenBackend({
    required this.scheduler,
    required this.pipeline,
    required this.sink,
    this.defaultRole = 'main',
    this.defaultParentReference = '',
  });

  @override
  Future<CodergenResult> run({
    required PipelineNode node,
    required String role,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  }) async {
    final name = role.isNotEmpty ? role : defaultRole;
    // resolveRole includes `main` (a valid node role, the default) even though
    // it is never a delegation target — the catalog is the single source of
    // truth for the identity/tools/model a node runs with.
    final agentRole = pipeline.resolveRole(name);
    if (agentRole == null) {
      return CodergenResult.error(
          'unknown role "$name"; known: ${pipeline.resolvableRoleNames.join(', ')}');
    }

    final task = preamble.isEmpty ? prompt : '$preamble\n\n$prompt';
    final result = await scheduler.runStandalone(
      role: agentRole,
      task: task,
      sink: sink,
      cancelSignal: cancelSignal,
      parentReference: defaultParentReference,
      // A node-level `model="provider/model"` attr overrides the role's tier.
      modelReference: node.model.isEmpty ? null : node.model,
    );
    if (result.isError) return CodergenResult.error(result.text);

    final verdict = parseVerdict(result.text);
    if (verdict != null) {
      return CodergenResult(
        result.text,
        outcome: Outcome.success(preferredLabel: verdict),
      );
    }
    return CodergenResult(result.text);
  }

  /// Extract a trailing `VERDICT: <label>` line (case-insensitive). Returns the
  /// label, or null if none. Exposed for testing.
  static String? parseVerdict(String text) {
    final lines = text.trimRight().split('\n');
    while (lines.isNotEmpty && lines.last.trim().isEmpty) {
      lines.removeLast();
    }
    if (lines.isEmpty) return null;
    final m = RegExp(r'VERDICT:\s*([A-Za-z0-9_\-]+)', caseSensitive: false)
        .firstMatch(lines.last);
    return m?.group(1)?.toLowerCase();
  }
}
