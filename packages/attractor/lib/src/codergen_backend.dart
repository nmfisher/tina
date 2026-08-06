import 'context.dart';
import 'graph.dart';
import 'outcome.dart';

/// The result of running a `codergen` (LLM) node's backend.
///
/// If [outcome] is non-null, the handler uses it verbatim (e.g. an autonomous
/// reviewer returns a verdict-derived outcome). Otherwise the handler treats
/// the node as [StageStatus.success] and records [text] under
/// `context.<nodeId>`.
class CodergenResult {
  /// The agent's response text (also written to `response.md`).
  final String text;

  /// An explicit outcome, overriding the default success. null = success.
  final Outcome? outcome;

  const CodergenResult(this.text, {this.outcome});

  /// A failed run — the handler records this outcome and edge selection sees
  /// `outcome=fail`.
  factory CodergenResult.error(String reason) =>
      CodergenResult('', outcome: Outcome.fail(reason));
}

/// The seam a host application implements to turn a `box`/LLM node into a
/// result. The engine has no LLM dependency; the host (tina) resolves the
/// node's `role`, builds an agent, runs it, and returns its text (and,
/// optionally, a verdict-derived outcome).
///
/// [preamble] carries prior-node context (rendered from `context.*`); [prompt]
/// is this node's task (already `$goal`-expanded). The host typically runs the
/// agent with `preamble + prompt` as the user input.
abstract class CodergenBackend {
  Future<CodergenResult> run({
    required PipelineNode node,
    required String role,
    required String prompt,
    required String preamble,
    required Context context,
    Future<void>? cancelSignal,
  });
}
