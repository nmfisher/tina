import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

/// The tina implementation of attractor's [CodergenBackend]. Each `box`/LLM
/// node is run as a real agent turn via [SubAgentScheduler.runStandalone],
/// building the agent from the node's own attributes: its `system_prompt`
/// (identity), and its `llm_model`/`llm_provider` (model). A node no longer
/// resolves an [AgentRole] for its identity (tin-80ll); sub-agents it delegates
/// to still come from the pipeline's role catalog.
///
/// Autonomous gating — a reviewer node approving or rejecting — works via a
/// verdict-line convention: a node prompt may instruct the agent to end its
/// response with `VERDICT: <label>`. The label is parsed into the outcome's
/// [Outcome.preferredLabel], which the engine matches against an edge's label
/// (edge-selection step 2), so `reviewer -> execute [label="approve"]` and
/// `reviewer -> plan [label="revise"]` route on the agent's own decision.
class TinaCodergenBackend implements CodergenBackend {
  final SubAgentScheduler scheduler;

  /// Where the turn's streamed text goes — the active conversation's host, so
  /// pipeline output renders inline like a normal agent turn.
  final AgentSink sink;

  /// The conversation's resolved `"provider/model"`, inherited by a node that
  /// omits `llm_model`/`llm_provider`. Threaded from the runner.
  final String defaultModelReference;

  TinaCodergenBackend({
    required this.scheduler,
    required this.sink,
    required this.defaultModelReference,
  });

  @override
  Future<CodergenResult> run({
    required PipelineNode node,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  }) async {
    final identity =
        node.systemPrompt.isNotEmpty ? node.systemPrompt : _defaultNodeIdentity;
    final task = preamble.isEmpty ? prompt : '$preamble\n\n$prompt';
    final nodeModel = node.modelReference;
    final result = await scheduler.runStandalone(
      systemPrompt: identity,
      task: task,
      sink: sink,
      cancelSignal: cancelSignal,
      // The node's `llm_model`/`llm_provider` override the conversation model;
      // when absent, runStandalone falls back to [defaultModelReference].
      parentReference: defaultModelReference,
      modelReference: nodeModel.isEmpty ? null : nodeModel,
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

/// Identity used when a node omits `system_prompt`. Nodes normally carry their
/// own identity; this is a safe fallback so a minimal node still runs.
const String _defaultNodeIdentity = '''
You are a coding agent running as one node of a workflow. Do the task described in the prompt using your tools. Where the task calls for it, delegate to specialist sub-agents (research, implementer, verifier, tester) with the delegate tool and act on their results. Read files before editing them, keep changes minimal, and report what you did.''';
