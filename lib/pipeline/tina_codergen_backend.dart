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

  /// The role used when a node omits `role`. Defaults to `orchestrator`.
  final String defaultRole;

  TinaCodergenBackend({
    required this.scheduler,
    required this.pipeline,
    required this.sink,
    this.defaultRole = 'orchestrator',
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
    final agentRole = pipeline.role(name);
    if (agentRole == null) {
      return CodergenResult.error(
          'unknown role "$name"; known: ${pipeline.roles.map((r) => r.name).join(', ')}');
    }

    final task = preamble.isEmpty ? prompt : '$preamble\n\n$prompt';
    final result = await scheduler.runStandalone(
      role: agentRole,
      task: task,
      sink: sink,
      cancelSignal: cancelSignal,
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
